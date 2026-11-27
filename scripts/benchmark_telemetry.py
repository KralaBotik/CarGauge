#!/usr/bin/env python3
"""Measure a proposed CarGauge SQLite schema with deterministic fictional drives."""

import argparse
import csv
import gzip
import json
from pathlib import Path
import platform
import shutil
import sqlite3
import tempfile
from time import perf_counter


MIB = 1024 * 1024
DAY_MS = 86_400_000
BASE_UTC_MS = 1_767_225_600_000
CHECKPOINT_DAYS = (30, 90, 365)
GPS_INTERVAL = 5
TRANSACTION_SECONDS = 60
PROFILES = {
    "conservative": (5, 5, 10, 10, 10),
    "detailed": (1, 1, 5, 5, 2),
}
CHANNELS = (
    (1, "engine_rpm", "rpm", 1),
    (2, "vehicle_speed", "km/h", 1),
    (3, "coolant_temperature", "°C", 1),
    (4, "ecu_voltage", "V", 1000),
    (5, "fuel_rate", "L/h", 1000),
)

# Proposed schema, intentionally separate from the release app's storage.
SCHEMA = """
PRAGMA user_version=1;
CREATE TABLE vehicle(id INTEGER PRIMARY KEY, profile_key TEXT NOT NULL);
CREATE TABLE trip(
    id INTEGER PRIMARY KEY, vehicle_id INTEGER NOT NULL REFERENCES vehicle,
    observed_from_ms INTEGER NOT NULL, observed_to_ms INTEGER NOT NULL,
    engine_start_ms INTEGER, start_origin TEXT NOT NULL,
    CHECK (observed_from_ms < observed_to_ms)
);
CREATE INDEX trip_by_vehicle_start ON trip(vehicle_id, observed_from_ms);
CREATE TABLE coverage_gap(
    trip_id INTEGER NOT NULL REFERENCES trip,
    from_ms INTEGER NOT NULL, to_ms INTEGER NOT NULL, reason TEXT NOT NULL,
    PRIMARY KEY (trip_id, from_ms), CHECK (from_ms < to_ms)
) WITHOUT ROWID;
CREATE TABLE channel(
    id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, unit TEXT NOT NULL,
    integer_scale INTEGER NOT NULL CHECK (integer_scale > 0)
);
CREATE TABLE sample(
    trip_id INTEGER NOT NULL REFERENCES trip, channel_id INTEGER NOT NULL REFERENCES channel,
    at_ms INTEGER NOT NULL, value INTEGER NOT NULL, quality INTEGER NOT NULL,
    PRIMARY KEY (trip_id, channel_id, at_ms)
) WITHOUT ROWID;
CREATE INDEX sample_by_channel_time ON sample(channel_id, at_ms);
CREATE TABLE route_point(
    trip_id INTEGER NOT NULL REFERENCES trip, at_ms INTEGER NOT NULL,
    latitude_e7 INTEGER NOT NULL, longitude_e7 INTEGER NOT NULL, accuracy_cm INTEGER NOT NULL,
    PRIMARY KEY (trip_id, at_ms)
) WITHOUT ROWID;
CREATE TABLE diagnostic_scan(
    id INTEGER PRIMARY KEY, vehicle_id INTEGER NOT NULL REFERENCES vehicle,
    trip_id INTEGER REFERENCES trip, started_ms INTEGER NOT NULL,
    protocol TEXT, status TEXT NOT NULL
);
CREATE INDEX diagnostic_scan_by_vehicle_time ON diagnostic_scan(vehicle_id, started_ms);
CREATE TABLE diagnostic_exchange(
    scan_id INTEGER NOT NULL REFERENCES diagnostic_scan, ordinal INTEGER NOT NULL,
    sent_ms INTEGER NOT NULL, elapsed_ms INTEGER NOT NULL, command TEXT NOT NULL,
    outcome TEXT NOT NULL, responder TEXT, raw BLOB,
    PRIMARY KEY (scan_id, ordinal)
) WITHOUT ROWID;
CREATE TABLE diagnostic_dtc(
    scan_id INTEGER NOT NULL REFERENCES diagnostic_scan, responder TEXT NOT NULL,
    code TEXT NOT NULL, status TEXT NOT NULL,
    PRIMARY KEY (scan_id, responder, code, status)
) WITHOUT ROWID;
CREATE TABLE event(
    id INTEGER PRIMARY KEY, vehicle_id INTEGER NOT NULL REFERENCES vehicle,
    trip_id INTEGER REFERENCES trip, at_ms INTEGER NOT NULL, kind TEXT NOT NULL,
    source_ref TEXT NOT NULL, payload_json TEXT NOT NULL
);
CREATE INDEX event_by_vehicle_time ON event(vehicle_id, at_ms);
CREATE TABLE service_entry(
    id INTEGER PRIMARY KEY, vehicle_id INTEGER NOT NULL REFERENCES vehicle,
    at_ms INTEGER NOT NULL, odometer_m INTEGER, kind TEXT NOT NULL, payload_json TEXT NOT NULL
);
CREATE INDEX service_by_vehicle_time ON service_entry(vehicle_id, at_ms);
"""


class CountingFile:
    def __init__(self):
        self.bytes_written = 0

    def write(self, data):
        self.bytes_written += len(data)
        return len(data)

    def flush(self):
        pass


class CSVSizeMeter:
    def __init__(self, compressor):
        self.compressor = compressor
        self.bytes_written = 0

    def write(self, row):
        data = row.encode("utf-8")
        self.bytes_written += len(data)
        self.compressor.write(data)


def file_size(path):
    return path.stat().st_size if path.exists() else 0


def synthetic_values(second):
    # Deterministic physical-looking values for sizing only, not engine models.
    traffic = (second * 31) % 240
    speed = 0 if traffic < 31 else min(84, (traffic - 29) // 2)
    rpm = 750 + 4 * (second % 37) if speed == 0 else 1050 + 21 * speed + 3 * (second % 71)
    temperature = min(95, 38 + second // 18) - (second // 107) % 3
    voltage = 13_860 + (second * 39) % 360
    fuel_rate = 680 + speed * 71 + (second * 47) % 510
    return rpm, speed, temperature, voltage, fuel_rate


def write_trip(connection, path, day, number, intervals):
    trip_id = 2 * day + number + 1
    duration = (23 + day % 5 if number == 0 else 25 + day * 3 % 7) * 60
    began = BASE_UTC_MS + day * DAY_MS + ((7 if number == 0 else 18) * 3600 + day % 25 * 60) * 1000
    lost_at = duration // 2
    returned_at = lost_at + 30
    max_wal = 0
    with connection:
        connection.execute("INSERT INTO trip VALUES (?, 1, ?, ?, NULL, 'left_censored')",
                           (trip_id, began, began + duration * 1000))
        connection.execute("INSERT INTO coverage_gap VALUES (?, ?, ?, 'ble_disconnected')",
                           (trip_id, began + lost_at * 1000, began + returned_at * 1000))
    for start in range(0, duration, TRANSACTION_SECONDS):
        samples = []
        points = []
        for second in range(start, min(duration, start + TRANSACTION_SECONDS)):
            if lost_at <= second < returned_at:
                continue
            at_ms = began + second * 1000
            for channel, (interval, value) in enumerate(zip(intervals, synthetic_values(second)), start=1):
                if second % interval == 0:
                    quality = 2 if channel == 5 else 1  # calculated or measured fixture
                    samples.append((trip_id, channel, at_ms + 42 * channel, value, quality))
            if second % GPS_INTERVAL == 0:
                points.append((trip_id, at_ms + 310, 10_000_000 + second * 21,
                               10_000_000 + second * 9, 350 + second % 60))
        with connection:
            connection.executemany("INSERT INTO sample VALUES (?, ?, ?, ?, ?)", samples)
            connection.executemany("INSERT INTO route_point VALUES (?, ?, ?, ?, ?)", points)
        max_wal = max(max_wal, file_size(path.with_suffix(".sqlite-wal")))
    return duration, max_wal


def write_maintenance_and_diagnostics(connection, day):
    at_ms = BASE_UTC_MS + day * DAY_MS + 19 * 3_600_000
    if day % 7 == 0:
        with connection:
            scan_id = connection.execute(
                "INSERT INTO diagnostic_scan VALUES (NULL,1,NULL,?,'fixture','complete') RETURNING id",
                (at_ms,),
            ).fetchone()[0]
            # Fictional payloads are never sent anywhere. Keep exchange size variable.
            connection.executemany("INSERT INTO diagnostic_exchange VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (
                (scan_id, index, at_ms + index * 400, 20 + index * 11, "fixture", "ok", "fixture",
                 (f"FIXTURE {day:03d} {index:02d}\r" * (4 + index)).encode("ascii"))
                for index in range(16)
            ))
            if day % 35 == 0:
                connection.execute("INSERT INTO diagnostic_dtc VALUES (?, 'fixture', 'P0000', 'fixture')",
                                   (scan_id,))
                connection.execute("INSERT INTO event VALUES (NULL,1,NULL,?,'diagnostic',?,?)",
                                   (at_ms, str(scan_id), '{"fixture":true}'))
    if day % 10 == 0:
        with connection:
            connection.execute("INSERT INTO service_entry VALUES (NULL,1,?,?,'refuel',?)",
                               (at_ms, 123_400_000 + 32_000 * day, '{"fuel_mL":41000}'))


def csv_size(connection):
    stored = CountingFile()
    with gzip.GzipFile(fileobj=stored, mode="wb", compresslevel=6, mtime=0) as compressed:
        measured = CSVSizeMeter(compressed)
        csv_output = csv.writer(measured, lineterminator="\n")
        csv_output.writerow(("trip_id", "channel_id", "utc_ms", "scaled_value", "quality"))
        csv_output.writerows(connection.execute(
            "SELECT trip_id, channel_id, at_ms, value, quality FROM sample ORDER BY trip_id, channel_id, at_ms"
        ))
    return {"telemetry_csv_bytes": measured.bytes_written, "telemetry_csv_gzip_bytes": stored.bytes_written}


def size_at(connection, path, day, duration, peak_wal):
    began = perf_counter()
    wal_path = path.with_suffix(".sqlite-wal")
    shm_path = path.with_suffix(".sqlite-shm")
    before = file_size(wal_path)
    peak_wal = max(peak_wal, before)
    if connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone() != (0, 0, 0):
        raise RuntimeError("SQLite checkpoint did not complete")
    report = {"days": day, "nominal_observation_seconds": duration,
              "database_bytes": file_size(path), "wal_before_checkpoint_bytes": before,
              "peak_sampled_wal_bytes": peak_wal, "wal_after_checkpoint_bytes": file_size(wal_path),
              "shm_bytes": file_size(shm_path),
              "freelist_pages": connection.execute("PRAGMA freelist_count").fetchone()[0]}
    for table in ("trip", "sample", "route_point", "coverage_gap", "diagnostic_exchange", "service_entry"):
        report[f"{table}_rows"] = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    report["bytes_by_object"] = dict(connection.execute("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name"))
    report.update(csv_size(connection))
    report["measure_seconds"] = round(perf_counter() - began, 3)
    return report


def benchmark(workspace):
    if shutil.disk_usage(workspace).free < 1024 * MIB:
        raise RuntimeError("SQLite sizing needs at least 1 GiB of free space in the scratch directory")
    result = {"platform": platform.platform(), "python": platform.python_version(),
              "sqlite": sqlite3.sqlite_version, "page_bytes": 4096, "journal_mode": "wal",
              "synchronous": "normal", "wal_autocheckpoint_pages": 1000,
              "sample_transaction_seconds": TRANSACTION_SECONDS, "gps_interval_seconds": GPS_INTERVAL,
              "profiles": {}}
    for name, intervals in PROFILES.items():
        path = workspace / f"{name}.sqlite"
        started = perf_counter()
        duration = peak_wal = 0
        measurements = []
        with sqlite3.connect(path) as connection:
            connection.execute("PRAGMA page_size=4096")
            if connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
                raise RuntimeError("SQLite did not enable WAL")
            connection.execute("PRAGMA synchronous=NORMAL")
            connection.execute("PRAGMA wal_autocheckpoint=1000")
            connection.execute("PRAGMA foreign_keys=ON")
            connection.executescript(SCHEMA)
            with connection:
                connection.execute("INSERT INTO vehicle VALUES (1, 'synthetic')")
                connection.executemany("INSERT INTO channel VALUES (?, ?, ?, ?)", CHANNELS)
            for day in range(CHECKPOINT_DAYS[-1]):
                for number in (0, 1):
                    seconds, trip_peak = write_trip(connection, path, day, number, intervals)
                    duration += seconds
                    peak_wal = max(peak_wal, trip_peak)
                write_maintenance_and_diagnostics(connection, day)
                if day + 1 in CHECKPOINT_DAYS:
                    measurements.append(size_at(connection, path, day + 1, duration, peak_wal))
            if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise RuntimeError("SQLite integrity check failed")
            if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise RuntimeError("SQLite foreign key check failed")
        connection.close()
        result["profiles"][name] = {"interval_seconds": {c[1]: i for c, i in zip(CHANNELS, intervals)},
                                     "elapsed_seconds": round(perf_counter() - started, 3),
                                     "measurements": measurements}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-parent", type=Path, required=True,
                        help="Existing directory for new temporary database files")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="cargauge-sqlite-", dir=options.scratch_parent) as directory:
        print(json.dumps(benchmark(Path(directory)), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

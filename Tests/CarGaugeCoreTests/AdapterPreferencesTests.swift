import CarGaugeCore
import Foundation
import Testing

@Test func upgradesAStoredSelectionOnlyAfterFreshTemperature() throws {
    let suite = "CarGauge.AdapterPreferencesTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let oldID = UUID()
    let newID = UUID()
    defaults.set(oldID.uuidString, forKey: "selectedBLEPeripheral")
    let preferences = AdapterPreferences(defaults: defaults)
    #expect(preferences.preferredID == oldID)
    #expect(preferences.verifiedID == nil)

    let now = Date(timeIntervalSince1970: 100)
    #expect(!preferences.confirm(id: newID, name: "Other", coolant: Reading(.nan, at: now), at: now))
    #expect(!preferences.confirm(id: newID, name: "Other", coolant: Reading(85, at: now - 5), at: now))
    #expect(preferences.preferredID == oldID && preferences.verifiedID == nil)

    #expect(preferences.confirm(id: oldID, name: "Vgate", coolant: Reading(85, at: now), at: now))
    #expect(AdapterPreferences(defaults: defaults).verifiedID == oldID)
    #expect(preferences.name == "Vgate")
    #expect(defaults.string(forKey: "selectedBLEPeripheral") == nil)
    #expect(!preferences.confirm(id: newID, name: "Other", coolant: Reading(88, at: now - 60), at: now))
    #expect(preferences.verifiedID == oldID)
}

@Test func forgettingAnAdapterPreservesTripPreferences() throws {
    let suite = "CarGauge.AdapterPreferencesTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let prefs = AdapterPreferences(defaults: defaults)
    let now = Date(timeIntervalSince1970: 100)
    #expect(prefs.confirm(id: UUID(), name: nil, coolant: Reading(85, at: now), at: now))
    defaults.set(UUID().uuidString, forKey: "selectedBLEPeripheral")
    defaults.set("light", forKey: "appearance")
    defaults.set(true, forKey: "autoLiveActivity")
    defaults.set(false, forKey: "autoConnect")
    let thresholds = try JSONEncoder().encode(ThermalThresholds.standard)
    defaults.set(thresholds, forKey: "thermalThresholds")
    prefs.clear()

    #expect(prefs.preferredID == nil && prefs.verifiedID == nil)
    #expect(defaults.string(forKey: "appearance") == "light")
    #expect(defaults.bool(forKey: "autoLiveActivity"))
    #expect(defaults.object(forKey: "autoConnect") != nil && !defaults.bool(forKey: "autoConnect"))
    #expect(defaults.data(forKey: "thermalThresholds") == thresholds)
}

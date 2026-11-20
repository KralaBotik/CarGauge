import CarGaugeCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    var previewDate: Date?
    let showHistory: () -> Void
    let showDiagnostics: () -> Void

    var body: some View {
        GaugePage {
            HStack(alignment: .center, spacing: GaugeSpacing.small) {
                GaugeHeading(title: "CarGauge", subtitle: "Hyundai Elantra HD · G4FC")
                sessionButton
            }
            sourceSwitch
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = previewDate ?? context.date
                VStack(spacing: GaugeSpacing.medium) {
                    TemperatureInstrument(value: model.coolant?.gaugeValue(at: now), thresholds: model.thresholds,
                                          alert: model.level, phase: model.phase, source: model.source)
                    metricStrip(at: now)
                }
            }
            GaugePanel {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("График прогрева").font(.headline).accessibilityAddTraits(.isHeader)
                            Text("Последние 5 мин").font(.caption).foregroundStyle(palette.muted)
                        }
                        .accessibilityIdentifier("chart-preview")
                        Spacer(minLength: GaugeSpacing.small)
                        Button(action: showHistory) {
                            Image(systemName: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(GaugeActionStyle())
                        .accessibilityLabel("Открыть историю")
                    }
                    WarmupChart(points: model.history, thresholds: model.thresholds, compact: true)
                        .accessibilityIdentifier("warmup-plot")
                }
            }
        }
        .accessibilityIdentifier("instruments-screen")
    }

    private var needsAdapter: Bool { model.source == .vehicle && model.ble.selectedID == nil }

    private var sessionButton: some View {
        Button {
            if model.isRunning { model.stop() }
            else if needsAdapter { showDiagnostics() }
            else { model.start() }
        } label: {
            Image(systemName: model.isRunning ? "pause.fill" : (needsAdapter ? "link" : "play.fill"))
                .frame(width: 20)
        }
        .buttonStyle(GaugeActionStyle())
        .accessibilityLabel(model.isRunning ? "Остановить измерение" : (needsAdapter ? "Выбрать адаптер" : "Начать измерение"))
        .accessibilityIdentifier(model.isRunning ? "stop-measurement" : (needsAdapter ? "open-diagnostics" : "start-measurement"))
    }

    private var sourceSwitch: some View {
        let layout = typeSize.isAccessibilityCategory ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            sourceButton(.simulator, label: "Симулятор", symbol: "flask")
            sourceButton(.vehicle, label: "Автомобиль", symbol: "car.side")
        }
        .padding(GaugeSpacing.xsmall)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(palette.line).allowsHitTesting(false) }
    }

    private func sourceButton(_ source: DataSource, label: String, symbol: String) -> some View {
        let active = model.source == source
        return Button {
            model.switchSource(to: source)
        } label: {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? palette.accent : palette.muted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(active ? palette.accentWash : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("source-\(source.rawValue)")
    }

    private func metricStrip(at now: Date) -> some View {
        let rpm = model.supplementary?.rpm?.gaugeValue(at: now)
        let voltage = model.supplementary?.voltage?.gaugeValue(at: now)
        let rpmLabel = rpm.map { String(Int($0.rounded())) } ?? "—"
        let voltageLabel = voltage.map { "\($0.formatted(.number.precision(.fractionLength(1)))) В" } ?? "—"
        let voltageDetail = voltage == nil ? "Нет данных" : (model.supplementary?.voltageSource == .adapter ? "По адаптеру" : "Блок управления")
        let layout = typeSize.isAccessibilityCategory
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: GaugeSpacing.large))

        return GaugePanel {
            layout {
                GaugeMetric(title: "ОБОРОТЫ", symbol: "gauge.with.dots.needle.33percent",
                            value: rpmLabel, detail: "об/мин", id: "rpm-value")
                Rectangle().fill(palette.line)
                    .frame(width: typeSize.isAccessibilityCategory ? nil : 1,
                           height: typeSize.isAccessibilityCategory ? 1 : 69)
                    .accessibilityHidden(true)
                GaugeMetric(title: "НАПРЯЖЕНИЕ", symbol: "bolt",
                            value: voltageLabel, detail: voltageDetail, id: "voltage-value")
            }
        }
    }
}

private struct GaugeMetric: View {
    @Environment(\.gaugePalette) private var palette
    @ScaledMetric(relativeTo: .title) private var numberSize: CGFloat = 34
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GaugeCaption(title: title, symbol: symbol)
            Text(value)
                .font(.system(size: numberSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(id)
            Text(detail).font(.caption).foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

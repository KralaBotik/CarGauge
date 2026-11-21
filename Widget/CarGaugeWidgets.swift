import ActivityKit
import CarGaugeCore
import SwiftUI
import WidgetKit

@main struct CarGaugeWidgets: WidgetBundle {
    var body: some Widget {
        CoolantWidget()
        CoolantLiveActivity()
    }
}

private struct CoolantEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    var current: WidgetSnapshot? {
        snapshot.flatMap { date < $0.expiration && date >= $0.sampleDate.addingTimeInterval(-1) ? $0 : nil }
    }
}

private struct CoolantProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoolantEntry { CoolantEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (CoolantEntry) -> Void) {
        completion(CoolantEntry(date: .now, snapshot: WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoolantEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.read()
        var entries = [CoolantEntry(date: now, snapshot: snapshot)]
        if let snapshot, snapshot.expiration > now {
            entries.append(CoolantEntry(date: snapshot.expiration, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private struct CoolantWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoolantSnapshot", provider: CoolantProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Label("ОЖ", systemImage: "thermometer.medium")
                    .font(.headline)
                if let snapshot = entry.current {
                    Text("\(snapshot.temperature) °C")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                        .foregroundStyle(temperatureColor(snapshot.level))
                    if snapshot.level != .normal {
                        Text(snapshot.level == .critical ? "Перегрев" : "Высокая температура")
                            .font(.caption2.bold())
                            .foregroundStyle(temperatureColor(snapshot.level))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if snapshot.source == .simulator { Text("Симулятор").font(.caption2) }
                    Text("Замер в \(snapshot.sampleDate, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Нет свежих данных")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Температура ОЖ")
        .description("Последний замер CarGauge с отметкой времени.")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(true)
    }
}

private struct CoolantLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CarGaugeAttributes.self) { context in
            ActivityTemperature(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityTemperature(context: context)
                }
            } compactLeading: {
                if context.attributes.source == .simulator {
                    Text("Демо").font(.caption2).accessibilityLabel("Симулятор")
                } else {
                    Image(systemName: "thermometer.medium").accessibilityLabel("Температура ОЖ")
                }
            } compactTrailing: {
                Text(context.isStale ? "—" : "\(context.state.coolant)°")
                    .monospacedDigit()
                    .foregroundStyle(context.isStale ? Color.secondary : temperatureColor(context.state.level))
            } minimal: {
                if context.attributes.source == .simulator {
                    Image(systemName: "testtube.2").accessibilityLabel("Симулятор")
                } else {
                    Text(context.isStale ? "—" : "\(context.state.coolant)°").monospacedDigit()
                }
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct ActivityTemperature: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<CarGaugeAttributes>

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: context.isStale ? "thermometer.medium" : (context.state.level == .normal ? "thermometer.medium" : "exclamationmark.triangle.fill"))
                .foregroundStyle(context.isStale ? Color.secondary : temperatureColor(context.state.level))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.source == .simulator ? "ОЖ · Симулятор" : "Температура ОЖ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(context.isStale ? "Нет свежих данных" : "\(context.state.coolant) °C")
                    .font(context.isStale ? .caption.bold() : .title2.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(context.isStale ? Color.secondary : temperatureColor(context.state.level))
                if !context.isStale && context.state.level != .normal {
                    Text(context.state.level == .critical ? "Перегрев" : "Высокая температура")
                        .font(.caption2.bold())
                        .foregroundStyle(temperatureColor(context.state.level))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if !context.isStale {
                    Text("Замер в \(context.state.sampleDate, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(family == .small ? 8 : 16)
    }
}

private func temperatureColor(_ level: ThermalLevel) -> Color {
    switch level {
    case .normal: .primary
    case .warning: .orange
    case .critical: .red
    }
}

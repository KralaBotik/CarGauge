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
    let containerIsAvailable: Bool

    var current: WidgetSnapshot? {
        snapshot.flatMap { $0.isCurrent(at: date) ? $0 : nil }
    }
}

private struct CoolantProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoolantEntry {
        CoolantEntry(date: .now, snapshot: nil, containerIsAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (CoolantEntry) -> Void) {
        let available = WidgetSnapshotStore.containerIsAvailable
        completion(CoolantEntry(date: .now, snapshot: available ? WidgetSnapshotStore.read() : nil,
                                containerIsAvailable: available))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoolantEntry>) -> Void) {
        let now = Date()
        let available = WidgetSnapshotStore.containerIsAvailable
        let snapshot = available ? WidgetSnapshotStore.read() : nil
        let entry = CoolantEntry(date: now, snapshot: snapshot, containerIsAvailable: available)
        var entries = [entry]
        if let current = entry.current {
            entries.append(CoolantEntry(date: current.expiration, snapshot: nil, containerIsAvailable: available))
        }
        let nextRequest = now.addingTimeInterval(entry.current == nil ? 15 * 60 : 60)
        completion(Timeline(entries: entries, policy: .after(nextRequest)))
    }
}

private struct CoolantWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoolantSnapshot", provider: CoolantProvider()) { entry in
            CoolantWidgetFace(entry: entry)
        }
        .configurationDisplayName("Температура ОЖ")
        .description("Снимок температуры с временем замера.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .containerBackgroundRemovable(true)
    }
}

private struct CoolantWidgetFace: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: CoolantEntry

    var body: some View {
        GlanceWidgetInstrument(sample: entry.current, containerIsAvailable: entry.containerIsAvailable,
                               isAccessory: family == .accessoryRectangular,
                               useAppColors: renderingMode == .fullColor && showsBackground)
            .containerBackground(for: .widget) {
                InstrumentPalette(scheme: scheme).surface
            }
    }
}

private struct CoolantLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CarGaugeAttributes.self) { context in
            LiveInstrument(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    LiveInstrument(context: context, isIsland: true)
                }
            } compactLeading: {
                if context.attributes.source == .simulator {
                    Text("Тест").font(.caption2).accessibilityLabel("Тестовые данные")
                } else {
                    Image(systemName: context.isStale ? "clock" : context.state.level.glanceSymbol)
                        .accessibilityLabel(context.isStale ? "Нет свежих данных" : context.state.level.glanceTitle ?? "Температура ОЖ")
                }
            } compactTrailing: {
                Text(context.isStale ? "—" : "\(context.state.coolant)°")
                    .monospacedDigit()
                    .accessibilityLabel(context.isStale ? "Нет свежих данных" : "\(context.state.coolant) °C")
            } minimal: {
                if context.attributes.source == .simulator {
                    Image(systemName: "testtube.2").accessibilityLabel("Тестовые данные")
                } else if context.isStale {
                    Image(systemName: "clock").accessibilityLabel("Нет свежих данных")
                } else {
                    Text("\(context.state.coolant)°")
                        .monospacedDigit()
                        .accessibilityLabel("\(context.state.coolant) °C")
                }
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LiveInstrument: View {
    @Environment(\.activityFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let context: ActivityViewContext<CarGaugeAttributes>
    var isIsland = false

    var body: some View {
        let palette = InstrumentPalette(scheme: scheme)
        let instrument = GlanceActivityInstrument(state: context.state, source: context.attributes.source,
                                                  isStale: context.isStale, isSmall: family == .small,
                                                  isIsland: isIsland)
        if isIsland {
            instrument
        } else {
            instrument
                .activityBackgroundTint(family == .small ? nil : palette.surface)
                .activitySystemActionForegroundColor(family == .small ? nil : palette.reading)
        }
    }
}

import CarGaugeCore
import Foundation
import SwiftUI

struct GlanceWidgetInstrument: View {
    @Environment(\.colorScheme) private var scheme
    let sample: WidgetSnapshot?
    let containerIsAvailable: Bool
    var isAccessory = false
    var useAppColors = true

    var body: some View {
        Group {
            if isAccessory {
                accessoryFace
            } else {
                instrumentFace
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var instrumentFace: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Температура ОЖ", systemImage: "thermometer.medium")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            if let sample {
                number(sample.temperature, size: 42)
                if let alert = sample.level.glanceTitle {
                    Text(alert)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(alertTone(sample.level))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                SampleClock(label: "Замер", date: sample.sampleDate)
                if sample.source == .simulator { testBadge }
            } else {
                Text(unavailableTitle)
                    .font(.subheadline.weight(.semibold))
                if containerIsAvailable {
                    Text("Откройте CarGauge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Подробнее в CarGauge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var accessoryFace: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Температура ОЖ", systemImage: "thermometer.medium")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            if let sample {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    number(sample.temperature, size: 21)
                    if sample.source == .simulator {
                        testBadge
                    } else if let alert = sample.level.glanceTitle {
                        Text(alert)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                SampleClock(label: "Замер", date: sample.sampleDate)
            } else {
                Text(unavailableTitle).font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableTitle: String {
        containerIsAvailable ? "Нет свежих данных" : "Данные недоступны"
    }

    private func number(_ temperature: Int, size: CGFloat) -> some View {
        CoolantNumber(temperature: temperature, size: size)
            .foregroundStyle(useAppColors ? InstrumentPalette(scheme: scheme).reading : .primary)
    }

    private func alertTone(_ level: ThermalLevel) -> Color {
        useAppColors ? InstrumentPalette(scheme: scheme).tone(for: level) : .primary
    }
}

struct GlanceActivityInstrument: View {
    @Environment(\.colorScheme) private var scheme
    let state: CarGaugeAttributes.ContentState
    let source: DataSource
    let isStale: Bool
    let isSmall: Bool
    var isIsland = false

    private var palette: InstrumentPalette {
        InstrumentPalette(scheme: isIsland ? .dark : scheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 3 : 6) {
            if isStale {
                Label("Нет свежих данных", systemImage: "clock")
                    .font(isSmall ? .subheadline.weight(.semibold) : .headline)
                Text("Температура ОЖ").font(.caption2).foregroundStyle(.secondary)
            } else if isSmall {
                Label(state.level.glanceTitle ?? "Температура ОЖ",
                      systemImage: state.level.glanceSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.tone(for: state.level))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                CoolantNumber(temperature: state.coolant, size: 37)
                SampleClock(label: "Замер", date: state.sampleDate)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        CoolantNumber(temperature: state.coolant, size: 40).fixedSize()
                        sampleDetails.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CoolantNumber(temperature: state.coolant, size: 40)
                        sampleDetails
                    }
                }
            }
            if source == .simulator { testBadge }
        }
        .foregroundStyle(isSmall ? Color.primary : palette.reading)
        .padding(isSmall ? 8 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var sampleDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Температура ОЖ", systemImage: "thermometer.medium")
                .font(.caption.weight(.semibold))
            if let alert = state.level.glanceTitle {
                Label(alert, systemImage: state.level.glanceSymbol)
                    .font(.caption.bold())
                    .foregroundStyle(palette.tone(for: state.level))
            }
            SampleClock(label: "Замер", date: state.sampleDate)
        }
    }
}

private struct CoolantNumber: View {
    let temperature: Int
    let size: CGFloat

    var body: some View {
        let digits = Text("\(temperature)")
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
        let unit = Text("°C").font(.system(size: size * 0.48, weight: .medium))
        Text("\(digits) \(unit)")
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .accessibilityLabel("\(temperature) °C")
    }
}

private struct SampleClock: View {
    let label: String
    let date: Date

    var body: some View {
        Text("\(label) \(date, format: .dateTime.hour().minute().second())")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

private var testBadge: some View {
    Text("Тестовые данные")
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
}

struct InstrumentPalette {
    let scheme: ColorScheme

    var surface: Color {
        scheme == .dark ? Color(red: 0.09, green: 0.10, blue: 0.11) : Color(red: 0.96, green: 0.95, blue: 0.93)
    }

    var reading: Color {
        scheme == .dark ? Color(red: 0.96, green: 0.94, blue: 0.91) : Color(red: 0.14, green: 0.13, blue: 0.11)
    }

    func tone(for level: ThermalLevel) -> Color {
        switch level {
        case .normal:
            scheme == .dark ? Color(red: 0.64, green: 0.80, blue: 0.66) : Color(red: 0.16, green: 0.38, blue: 0.24)
        case .warning:
            scheme == .dark ? Color(red: 0.96, green: 0.75, blue: 0.47) : Color(red: 0.53, green: 0.29, blue: 0.05)
        case .critical:
            scheme == .dark ? Color(red: 1, green: 0.66, blue: 0.59) : Color(red: 0.63, green: 0.21, blue: 0.17)
        }
    }
}

extension ThermalLevel {
    var glanceTitle: String? {
        switch self {
        case .normal: nil
        case .warning: "Выше нормы"
        case .critical: "Перегрев"
        }
    }

    var glanceSymbol: String {
        self == .normal ? "thermometer.medium" : "exclamationmark.triangle.fill"
    }
}

#if DEBUG
struct GlancePreviewFixture: View {
    @Environment(\.colorScheme) private var scheme
    @State private var mode = Mode.fresh
    private let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)

    private enum Mode: String, CaseIterable, Identifiable {
        case fresh, stale, noGroup
        var id: Self { self }
        var title: String {
            switch self {
            case .fresh: "Свежие"
            case .stale: "Устаревшие"
            case .noGroup: "Без группы"
            }
        }
        var identifier: String {
            switch self {
            case .fresh: "glance-fixture-fresh"
            case .stale: "glance-fixture-stale"
            case .noGroup: "glance-fixture-no-group"
            }
        }
    }

    var body: some View {
        let palette = InstrumentPalette(scheme: scheme)
        let sample = WidgetSnapshot(source: .simulator, temperature: 92, sampleDate: sampleDate, level: .normal)
        let evaluationDate = sampleDate.addingTimeInterval(mode == .stale ? 60 : 5)
        let displayed = mode != .noGroup && sample.isCurrent(at: evaluationDate) ? sample : nil
        let state = CarGaugeAttributes.ContentState(coolant: sample.temperature, sampleDate: sampleDate, level: .normal)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Проверка экранов").font(.title2.bold())
                HStack {
                    ForEach(Mode.allCases) { item in
                        Button(item.title) { mode = item }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(item.identifier)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    GlanceWidgetInstrument(sample: displayed, containerIsAvailable: mode != .noGroup)
                        .padding(12)
                        .frame(width: 152, height: 152, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("glance-widget")
                    GlanceActivityInstrument(state: state, source: .simulator, isStale: mode == .stale, isSmall: true)
                        .frame(width: 152, height: 152, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("glance-small-activity")
                }
                GlanceActivityInstrument(state: state, source: .simulator, isStale: mode == .stale, isSmall: false)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("glance-lock-activity")
            }
            .padding()
        }
        .accessibilityIdentifier("glance-preview")
    }
}
#endif

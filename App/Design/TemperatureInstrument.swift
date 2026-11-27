import CarGaugeCore
import SwiftUI

struct TemperatureInstrument: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 112
    @ScaledMetric(relativeTo: .title) private var accessibilityDisplaySize: CGFloat = 58

    let value: Double?
    let thresholds: ThermalThresholds
    let alert: ThermalLevel

    var body: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
            Text("Температура ОЖ")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.muted)
                .accessibilityLabel("Температура охлаждающей жидкости")
                .accessibilityAddTraits(.isHeader)

            if let value {
                digits(Int(value))
            } else {
                Text("Нет свежей температуры")
                    .font(.title2.weight(.semibold))
                    .accessibilityLabel("Нет свежих данных")
                    .accessibilityIdentifier("coolant-value")
            }

            let status = statusContent
            if value != nil || alert != .normal {
                GaugeStatus(title: status.title, symbol: status.symbol, tone: status.tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(status.id)
            }

            if let value, !typeSize.isAccessibilitySize {
                TemperatureTrack(value: value, thresholds: thresholds, tone: status.tone)
                    .padding(.top, GaugeSpacing.xsmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func digits(_ number: Int) -> some View {
        let size = typeSize >= .xxLarge ? min(accessibilityDisplaySize, 132) : min(displaySize, 134)
        let amount = Text(number, format: .number.grouping(.never))
            .font(.system(size: size, weight: .medium))
            .monospacedDigit()
            .tracking(-size * 0.045)
        let unit = Text("°C")
            .font(.title2.weight(.medium))
            .foregroundStyle(palette.muted)

        return Text("\(amount) \(unit)")
            .foregroundStyle(readingTone)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(number)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: number)
            .accessibilityLabel("\(number) градусов Цельсия")
            .accessibilityIdentifier("coolant-value")
    }

    private var state: EngineTemperatureState? {
        value.map { thresholds.state(at: $0, alert: alert) }
    }

    private var readingTone: Color {
        switch state {
        case .warning: palette.warning
        case .critical: palette.critical
        default: palette.text
        }
    }

    private var statusContent: (title: String, symbol: String, tone: Color, id: String) {
        switch state {
        case .warmingUp: ("Прогрев", "thermometer.low", palette.warming, "temperature-state")
        case .operating: ("Рабочая температура", "checkmark.circle", palette.operating, "temperature-state")
        case .warning: ("Высокая температура", "exclamationmark.triangle", palette.warning, "overheat-warning")
        case .critical: ("Перегрев", "exclamationmark.triangle.fill", palette.critical, "overheat-critical")
        case nil where alert == .critical:
            ("Ранее был перегрев", "exclamationmark.triangle.fill", palette.critical, "stale-temperature-alert")
        case nil where alert == .warning:
            ("Ранее была высокая температура", "exclamationmark.triangle", palette.warning, "stale-temperature-alert")
        case nil:
            ("Нет свежих данных", "circle.dotted", palette.muted, "temperature-state")
        }
    }
}

private struct TemperatureTrack: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double
    let thresholds: ThermalThresholds
    let tone: Color

    private var lower: Double { Double(thresholds.operating - 25) }
    private var upper: Double { Double(thresholds.critical + 12) }

    var body: some View {
        VStack(spacing: GaugeSpacing.small) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 8)
                let marker = 4 + width * fraction(value)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let bounds = [lower, Double(thresholds.operating), Double(thresholds.warning),
                                      Double(thresholds.critical), upper]
                        let colors = [palette.warming, palette.operating, palette.warning, palette.critical]
                        for index in colors.indices {
                            let start = width * fraction(bounds[index])
                            let end = width * fraction(bounds[index + 1])
                            let line = CGRect(x: start + 4, y: 4, width: max(0, end - start - 2), height: 4)
                            context.fill(Path(roundedRect: line, cornerRadius: 1),
                                         with: .color(colors[index].opacity(0.62)))
                        }
                    }

                    RoundedRectangle(cornerRadius: 2)
                        .fill(tone)
                        .frame(width: 7, height: 12)
                        .position(x: marker, y: 6)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: marker)
                }
            }
            .frame(height: 12)
            HStack {
                Text("\(Int(lower))°")
                Spacer()
                Text("\(Int(upper))°")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.muted)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private func fraction(_ reading: Double) -> CGFloat {
        CGFloat(min(1, max(0, (reading - lower) / (upper - lower))))
    }
}

import CarGaugeCore
import SwiftUI

struct TemperatureInstrument: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var digitSize: CGFloat = 94
    let value: Double?
    let thresholds: ThermalThresholds
    let alert: ThermalLevel
    let phase: MeasurementPhase
    let source: DataSource

    var body: some View {
        GaugePanel(instrument: true, inset: GaugeSpacing.large) {
            VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                GaugeCaption(title: "ТЕМПЕРАТУРА ОЖ", symbol: "thermometer.medium")
                if typeSize.isAccessibilitySize {
                    digits
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            digits.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: GaugeSpacing.small)
                            InstrumentSweep(value: value, thresholds: thresholds, tone: tone)
                                .frame(width: 120, height: 98)
                                .accessibilityHidden(true)
                        }
                        digits
                    }
                }
                Rectangle().fill(palette.line).frame(height: 1).accessibilityHidden(true)
                status
                    .padding(.top, GaugeSpacing.xsmall)
            }
        }
    }

    private var state: EngineTemperatureState? {
        value.map { thresholds.state(at: $0, alert: alert) }
    }

    private var tone: Color { state.map(palette.tone(for:)) ?? palette.muted }

    private var digits: some View {
        let number = value.map { String(Int($0)) } ?? "—"
        let digit = Text(number)
            .font(.system(size: digitSize, weight: .medium, design: .default))
            .monospacedDigit()
        let unit = Text("°C").font(.title2.weight(.medium))
        let readout: LocalizedStringKey = value == nil ? "\(digit)" : "\(digit) \(unit)"

        return Text(readout)
            .foregroundStyle(tone)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .accessibilityLabel(value == nil ? number : "\(number) °C")
            .accessibilityIdentifier("coolant-value")
    }

    private var status: some View {
        let presentation = statusContent
        return GaugeStatus(title: presentation.title, symbol: presentation.symbol, tone: presentation.tone)
            .accessibilityIdentifier(presentation.id)
    }

    private var statusContent: (title: String, symbol: String, tone: Color, id: String) {
        switch state {
        case .warmingUp: ("Прогрев", "circle.lefthalf.filled", palette.warming, "temperature-state")
        case .operating: ("Рабочая температура", "checkmark.circle", palette.operating, "temperature-state")
        case .warning: ("Высокая температура", "exclamationmark.triangle", palette.warning, "overheat-warning")
        case .critical: ("Перегрев", "exclamationmark.triangle.fill", palette.critical, "overheat-critical")
        case nil where alert == .critical:
            ("Нет данных · ранее перегрев", "exclamationmark.triangle.fill", palette.critical, "stale-temperature-alert")
        case nil where alert == .warning:
            ("Нет данных · ранее высокая температура", "exclamationmark.triangle", palette.warning, "stale-temperature-alert")
        case nil:
            switch phase {
            case .connecting: ("Подключение…", "dot.radiowaves.left.and.right", palette.accent, "connection-status")
            case .retrying: ("Восстанавливаем связь…", "arrow.trianglehead.clockwise", palette.accent, "connection-status")
            case .awaitingAdapter: ("Адаптер не выбран", "link", palette.muted, "connection-status")
            case .failed where source == .vehicle: ("Ошибка подключения", "exclamationmark.circle", palette.warning, "connection-status")
            case .stopped: ("Измерения остановлены", "pause.circle", palette.muted, "connection-status")
            default: ("Нет свежих данных", "circle.dotted", palette.muted, "connection-status")
            }
        }
    }
}

private struct InstrumentSweep: View {
    @Environment(\.gaugePalette) private var palette
    let value: Double?
    let thresholds: ThermalThresholds
    let tone: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.60)
            let radius = min(size.width / 2 - 8, size.height * 0.56)
            let position = value.map { fraction($0) }

            context.stroke(arc(at: center, radius: radius, through: 1), with: .color(palette.line),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

            if let position, position > 0 {
                context.stroke(arc(at: center, radius: radius, through: position), with: .color(tone),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            for tick in 0...24 {
                let start = point(at: Double(tick) / 24, center: center, radius: radius - 10)
                let length: CGFloat = tick.isMultiple(of: 6) ? 9 : 4
                let end = point(at: Double(tick) / 24, center: center, radius: radius - 10 - length)
                var mark = Path()
                mark.move(to: start)
                mark.addLine(to: end)
                context.stroke(mark, with: .color(palette.muted.opacity(tick.isMultiple(of: 6) ? 0.82 : 0.4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }

            let pivot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(pivot, with: .color(value == nil ? palette.line : tone))
            if let position {
                var needle = Path()
                needle.move(to: point(at: position, center: center, radius: 9))
                needle.addLine(to: point(at: position, center: center, radius: radius - 19))
                context.stroke(needle, with: .color(tone), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }

    private func fraction(_ temperature: Double) -> Double {
        let minimum = Double(min(0, thresholds.operating - 40))
        let maximum = Double(thresholds.critical + 10)
        return max(0, min(1, (temperature - minimum) / (maximum - minimum)))
    }

    private func point(at fraction: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let radians = (140 + 260 * fraction) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private func arc(at center: CGPoint, radius: CGFloat, through fraction: Double) -> Path {
        var path = Path()
        path.move(to: point(at: 0, center: center, radius: radius))
        for step in 1...48 {
            path.addLine(to: point(at: fraction * Double(step) / 48, center: center, radius: radius))
        }
        return path
    }
}

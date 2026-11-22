import CarGaugeCore
import SwiftUI

struct TemperatureInstrument: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var digitSize: CGFloat = 86
    let value: Double?
    let thresholds: ThermalThresholds
    let alert: ThermalLevel

    var body: some View {
        Group {
            if typeSize >= .xxLarge {
                VStack(alignment: .leading, spacing: GaugeSpacing.small) { readout }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, GaugeSpacing.small)
            } else {
                ZStack(alignment: .bottom) {
                    ThermalDial(value: value, thresholds: thresholds, state: state)
                        .frame(height: 230)
                        .accessibilityHidden(true)
                    VStack(spacing: 0) { readout }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 12)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder private var readout: some View {
        Text("Охлаждающая жидкость")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.muted)
            .accessibilityAddTraits(.isHeader)
        digits
        let presentation = statusContent
        GaugeStatus(title: presentation.title, symbol: presentation.symbol, tone: presentation.tone)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(presentation.id)
    }

    private var state: EngineTemperatureState? {
        value.map { thresholds.state(at: $0, alert: alert) }
    }

    private var digits: some View {
        let number = value.map { String(Int($0)) } ?? "—"
        let digit = Text(number)
            .font(.system(size: digitSize, weight: .semibold))
            .monospacedDigit()
            .tracking(-3)
        let unit = Text("°C").font(.title2.weight(.medium)).foregroundColor(palette.muted)
        let readout: LocalizedStringKey = value == nil ? "\(digit)" : "\(digit) \(unit)"
        let tone = switch state {
        case .critical: palette.critical
        case .warning: palette.warning
        case nil: palette.muted
        default: palette.text
        }
        return Text(readout)
            .foregroundStyle(tone)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .accessibilityLabel(value == nil ? "Нет свежих данных" : "\(number) градусов Цельсия")
            .accessibilityIdentifier("coolant-value")
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

private struct ThermalDial: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double?
    let thresholds: ThermalThresholds
    let state: EngineTemperatureState?

    private let lower = -40.0
    private var upper: Double { Double(max(130, thresholds.critical + 12)) }

    private func fraction(_ value: Double) -> Double {
        min(1, max(0, (value - lower) / (upper - lower)))
    }

    var body: some View {
        let operating = fraction(Double(thresholds.operating))
        let warning = fraction(Double(thresholds.warning))
        let critical = fraction(Double(thresholds.critical))
        Canvas { context, size in
            let dial = DialGeometry(size: size)
            let bands: [(Double, Double, Color)] = [
                (0, operating, palette.warming),
                (operating, warning, palette.operating),
                (warning, critical, palette.warning),
                (critical, 1, palette.critical),
            ]
            for (start, end, tone) in bands {
                let gap = 0.003
                context.stroke(dial.arc(from: start + gap, to: end - gap),
                               with: .color(value == nil ? palette.line : tone.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .butt))
            }

            for tick in 0...34 {
                let major = tick.isMultiple(of: 4) || tick == 34
                let position = Double(tick) / 34
                var mark = Path()
                mark.move(to: dial.point(at: position, inset: 9))
                mark.addLine(to: dial.point(at: position, inset: major ? 20 : 14))
                context.stroke(mark, with: .color(major ? palette.muted : palette.line),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .overlay {
            if let value, let state {
                let position = fraction(value)
                DialMarker(position: position)
                    .fill(palette.tone(for: state))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: position)
            }
        }
        .overlay(alignment: .bottom) {
            if value != nil {
                HStack {
                    Text("\(Int(lower))°")
                    Spacer()
                    Text("\(Int(upper))°")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 6)
                .padding(.bottom, 1)
                .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
}

private struct DialGeometry {
    let size: CGSize
    var radius: CGFloat { min(size.width / 2 - 16, size.height - 73) }

    func point(at fraction: Double, inset: CGFloat = 0) -> CGPoint {
        let angle = (-195 + fraction * 210) * Double.pi / 180
        let distance = max(0, radius - inset)
        return CGPoint(x: size.width / 2 + cos(angle) * distance,
                       y: size.height - 65 + sin(angle) * distance)
    }

    func arc(from start: Double, to end: Double) -> Path {
        var path = Path()
        path.move(to: point(at: start))
        for step in 1...40 {
            path.addLine(to: point(at: start + (end - start) * Double(step) / 40))
        }
        return path
    }
}

private struct DialMarker: Shape {
    var position: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let point = DialGeometry(size: rect.size).point(at: position)
        return Path(ellipseIn: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11))
    }
}

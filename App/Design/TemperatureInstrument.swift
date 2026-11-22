import CarGaugeCore
import SwiftUI

struct TemperatureInstrument: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var digitSize: CGFloat = 108
    let value: Double?
    let thresholds: ThermalThresholds
    let alert: ThermalLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Температура ОЖ", systemImage: "thermometer.medium")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.muted)
                .accessibilityLabel("Температура охлаждающей жидкости")
                .accessibilityAddTraits(.isHeader)

            digits
                .padding(.top, 2)
                .padding(.bottom, GaugeSpacing.xsmall)
            if !typeSize.isAccessibilitySize {
                ThermalRail(state: state)
                    .padding(.bottom, GaugeSpacing.large)
            }
            status
        }
        .padding(GaugeSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 28)
            shape.fill(LinearGradient(colors: [palette.instrumentTop, palette.instrumentBottom],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [tone.opacity(0.13), .clear], center: .topTrailing,
                                      startRadius: 0, endRadius: 280))
            shape.strokeBorder(palette.line.opacity(0.65), lineWidth: 1)
        }
    }

    private var state: EngineTemperatureState? {
        value.map { thresholds.state(at: $0, alert: alert) }
    }

    private var tone: Color { state.map(palette.tone(for:)) ?? palette.muted }

    private var digits: some View {
        let number = value.map { String(Int($0)) } ?? "—"
        let digit = Text(number)
            .font(.system(size: digitSize, weight: .semibold))
            .monospacedDigit()
        let unit = Text("°C").font(.title2.weight(.medium)).foregroundColor(palette.muted)
        let readout: LocalizedStringKey = value == nil ? "\(digit)" : "\(digit) \(unit)"

        return Text(readout)
            .foregroundStyle(value == nil ? palette.muted : palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .accessibilityLabel(value == nil ? "Нет свежих данных" : "\(number) °C")
            .accessibilityIdentifier("coolant-value")
    }

    private var status: some View {
        let presentation = statusContent
        return GaugeStatus(title: presentation.title, symbol: presentation.symbol, tone: presentation.tone)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(presentation.tone.opacity(0.10), in: Capsule())
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
            ("Нет свежих данных", "circle.dotted", palette.muted, "temperature-state")
        }
    }
}

private struct ThermalRail: View {
    @Environment(\.gaugePalette) private var palette
    let state: EngineTemperatureState?

    private let stages: [EngineTemperatureState] = [.warmingUp, .operating, .warning, .critical]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(stages.indices, id: \.self) { index in
                let stage = stages[index]
                let selected = stage == state
                Capsule()
                    .fill(selected ? palette.tone(for: stage) : palette.line)
                    .frame(height: selected ? 7 : 3)
                    .frame(height: 7)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

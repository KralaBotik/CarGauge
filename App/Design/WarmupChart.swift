import CarGaugeCore
import Charts
import SwiftUI

struct WarmupChart: View {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var previewHeight: CGFloat = 164
    @ScaledMetric(relativeTo: .caption) private var historyHeight: CGFloat = 224
    @State private var selection: Selection = .latest
    @State private var scrubTime: Double?
    @State private var selectionFeedback = 0

    let points: [WarmupHistory.Point]
    let thresholds: ThermalThresholds
    let compact: Bool
    var alert: ThermalLevel = .normal
    var tripStartedAt: Date?

    private enum Selection {
        case latest
        case sample(Date)
        case gap(Double)
    }

    var body: some View {
        if let last = points.last {
            let window = ChartWindow(points: points, latest: last, tripStartedAt: tripStartedAt, compact: compact)
            if compact {
                plot(window, cursor: nil, sample: last)
            } else {
                history(window)
            }
        } else {
            Text("График появится после замера")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func history(_ window: ChartWindow) -> some View {
        let sample = selectedSample(in: window)
        let cursor = selectedTime(in: window)
        let previous = cursor.flatMap { time in window.points.last(where: { window.seconds($0) < time }) }
        let next = cursor.flatMap { time in window.points.first(where: { window.seconds($0) > time }) }

        return VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
            plot(window, cursor: cursor, sample: sample)
                .chartXSelection(value: $scrubTime)
                .onChange(of: scrubTime) { _, time in
                    if let time { select(at: time, in: window) }
                }
                .accessibilityIdentifier("history-plot")

            VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                Text("Замер в поездке")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.muted)
                if let sample {
                    Text("\(Int(sample.reading.value)) °C · \(window.duration(window.seconds(sample)))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityIdentifier("history-sample")
                } else {
                    Text("На этом участке нет замера")
                        .font(.subheadline)
                        .accessibilityIdentifier("history-gap")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: GaugeSpacing.small))
                : AnyLayout(HStackLayout(spacing: GaugeSpacing.small))
            layout {
                sampleButton("Раньше", icon: "chevron.left", id: "history-previous-reading", point: previous)
                sampleButton("Позже", icon: "chevron.right", id: "history-next-reading", point: next)
            }
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .onChange(of: window.points.first?.id) { _, first in
            guard let first else { return }
            switch selection {
            case .sample(let date) where date < first:
                selection = .latest
            case .gap(let time) where time < first.timeIntervalSince(window.origin):
                selection = .latest
            default:
                break
            }
        }
    }

    private func sampleButton(_ title: String, icon: String, id: String, point: WarmupHistory.Point?) -> some View {
        Button {
            if let point {
                selection = .sample(point.id)
                selectionFeedback += 1
            }
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(GaugeActionStyle())
        .disabled(point == nil)
        .accessibilityIdentifier(id)
    }

    private func selectedSample(in window: ChartWindow) -> WarmupHistory.Point? {
        switch selection {
        case .latest: window.points.last
        case .sample(let id): window.points.first { $0.id == id }
        case .gap: nil
        }
    }

    private func selectedTime(in window: ChartWindow) -> Double? {
        if case .gap(let time) = selection { return time }
        return selectedSample(in: window).map(window.seconds)
    }

    private func select(at time: Double, in window: ChartWindow) {
        if let sample = window.sample(at: time) {
            selection = .sample(sample.id)
        } else {
            selection = .gap(time)
        }
    }

    private func plot(_ window: ChartWindow, cursor: Double?, sample: WarmupHistory.Point?) -> some View {
        Chart {
            ForEach(window.points) { point in
                LineMark(x: .value("Время поездки, с", window.seconds(point)),
                         y: .value("Температура, °C", point.reading.value),
                         series: .value("Участок", point.segment))
                    .foregroundStyle(palette.trace)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                if window.singletons.contains(point.id) {
                    PointMark(x: .value("Время поездки, с", window.seconds(point)),
                              y: .value("Температура, °C", point.reading.value))
                        .foregroundStyle(palette.trace)
                        .symbolSize(24)
                }
            }
            if window.temperature.contains(Double(thresholds.warning)) {
                RuleMark(y: .value("Порог предупреждения", thresholds.warning))
                    .foregroundStyle(palette.warning.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let cursor, window.time.contains(cursor) {
                RuleMark(x: .value("Выбранное время", cursor))
                    .foregroundStyle(palette.muted.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: sample == nil ? [3, 3] : []))
                    .accessibilityHidden(true)
            }
            if let sample {
                PointMark(x: .value("Время поездки, с", window.seconds(sample)),
                          y: .value("Температура, °C", sample.reading.value))
                    .foregroundStyle(compact
                                     ? palette.tone(for: thresholds.state(at: sample.reading.value, alert: alert))
                                     : palette.accent)
                    .symbolSize(compact ? 30 : 62)
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: window.time)
        .chartYScale(domain: window.temperature)
        .chartXAxis {
            AxisMarks(values: window.ticks) { value in
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(palette.line)
                AxisValueLabel(anchor: .top, collisionResolution: .greedy) {
                    if let time = value.as(Double.self) {
                        Text(window.duration(time)).font(.caption2.monospacedDigit()).foregroundStyle(palette.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: compact ? 3 : 4)) { axis in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 3])).foregroundStyle(palette.line)
                AxisValueLabel {
                    if let value = axis.as(Double.self) {
                        Text("\(Int(value))°").font(.caption2.monospacedDigit()).foregroundStyle(palette.muted)
                    }
                }
            }
        }
        .frame(height: compact ? min(previewHeight, 248) : min(historyHeight, 300))
        .accessibilityLabel("График температуры охлаждающей жидкости")
    }
}

private struct ChartWindow {
    let points: [WarmupHistory.Point]
    let origin: Date
    let time: ClosedRange<Double>
    let temperature: ClosedRange<Double>
    let ticks: [Double]
    let singletons: Set<Date>

    init(points: [WarmupHistory.Point], latest: WarmupHistory.Point, tripStartedAt: Date?, compact: Bool) {
        let end = latest.id
        let visible = compact ? points.filter { end.timeIntervalSince($0.id) <= 300 } : points
        let origin = tripStartedAt ?? points.first?.id ?? end
        let last = end.timeIntervalSince(origin)
        let start = min((visible.first?.id ?? end).timeIntervalSince(origin), last - 12)
        let lower = max(0, start)
        let upper = max(lower + 12, last)
        let padding = max(1.5, (upper - lower) * 0.07)
        let desiredStep = (upper - lower) / Double(compact ? 3 : 4)
        let steps: [Double] = [1, 2, 5, 10, 15, 20, 30, 45, 60, 120, 180, 240, 300, 600, 900, 1800]
        let step = steps.first { $0 >= desiredStep } ?? 1800
        let first = ceil(lower / step) * step
        let temperatures = visible.map(\.reading.value)
        let cold = floor(((temperatures.min() ?? latest.reading.value) - 2) / 10) * 10
        let hot = ceil(((temperatures.max() ?? latest.reading.value) + 2) / 10) * 10

        self.points = visible
        self.origin = origin
        time = (lower - padding)...(upper + padding)
        temperature = cold...max(cold + 20, hot)
        ticks = (0..<5).map { first + Double($0) * step }.filter { $0 <= upper }
        singletons = Set(Dictionary(grouping: visible, by: \.segment).values
            .filter { $0.count == 1 }.compactMap { $0.first?.id })
    }

    func seconds(_ point: WarmupHistory.Point) -> Double {
        point.id.timeIntervalSince(origin)
    }

    func duration(_ time: Double) -> String {
        let total = max(0, Int(time.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    func sample(at time: Double) -> WarmupHistory.Point? {
        guard let right = points.firstIndex(where: { seconds($0) >= time }) else {
            guard let end = points.last, time - seconds(end) < 0.7 else { return nil }
            return end
        }

        let after = points[right]
        if seconds(after) - time < 0.7 { return after }
        guard right > points.startIndex else { return nil }
        let before = points[right - 1]
        if time - seconds(before) < 0.7 { return before }
        guard before.segment == after.segment else { return nil }
        return time - seconds(before) <= seconds(after) - time ? before : after
    }
}

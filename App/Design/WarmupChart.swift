import CarGaugeCore
import Charts
import SwiftUI

struct WarmupChart: View {
    @Environment(\.gaugePalette) private var palette
    @ScaledMetric(relativeTo: .caption) private var previewHeight: CGFloat = 96
    @ScaledMetric(relativeTo: .caption) private var historyHeight: CGFloat = 208
    let points: [WarmupHistory.Point]
    let thresholds: ThermalThresholds
    let compact: Bool

    var body: some View {
        Group {
            if let latest = points.last {
                plot(points, endingAt: latest)
            } else {
                VStack(spacing: GaugeSpacing.small) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text("График появится после замера")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(palette.muted)
                .frame(maxWidth: .infinity, minHeight: compact ? previewHeight : historyHeight)
            }
        }
    }

    private func plot(_ points: [WarmupHistory.Point], endingAt latest: WarmupHistory.Point) -> some View {
        let lastDate = latest.reading.timestamp
        let visible = compact ? points.filter { lastDate.timeIntervalSince($0.reading.timestamp) <= 300 } : points
        let firstDate = visible.first?.reading.timestamp ?? lastDate
        let windowStart = min(firstDate, lastDate.addingTimeInterval(-20))
        let windowEnd = lastDate.addingTimeInterval(2)
        let temperatures = visible.map(\.reading.value)
        let low = floor((temperatures.min() ?? 0) / 10) * 10
        let high = max(low + 20, ceil((temperatures.max() ?? 0) / 10) * 10 + 2)
        let singletons = Set(Dictionary(grouping: visible, by: \.segment).values.filter { $0.count == 1 }.compactMap { $0.first?.id })
        let timeFormat = compact ? Date.FormatStyle.dateTime.minute().second() : Date.FormatStyle.dateTime.hour().minute()

        return Chart {
            ForEach(visible) { point in
                LineMark(x: .value("Время", point.reading.timestamp),
                         y: .value("Температура, °C", point.reading.value),
                         series: .value("Участок", point.segment))
                    .foregroundStyle(palette.trace)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                if point.id == latest.id || singletons.contains(point.id) {
                    PointMark(x: .value("Время", point.reading.timestamp),
                              y: .value("Температура, °C", point.reading.value))
                        .foregroundStyle(point.id == latest.id
                                         ? palette.tone(for: thresholds.state(at: point.reading.value, alert: .normal))
                                         : palette.trace)
                        .symbolSize(28)
                        .accessibilityHidden(point.id == latest.id && !singletons.contains(point.id))
                }
            }
            if (low...high).contains(Double(thresholds.warning)) {
                RuleMark(y: .value("Порог предупреждения", thresholds.warning))
                    .foregroundStyle(palette.warning.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: windowStart...windowEnd)
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) {
                AxisGridLine().foregroundStyle(palette.line.opacity(0.55))
                AxisValueLabel(format: timeFormat).foregroundStyle(palette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                AxisGridLine().foregroundStyle(palette.line)
                AxisValueLabel {
                    if let temperature = value.as(Double.self) {
                        Text("\(Int(temperature))°").font(.caption2.monospacedDigit()).foregroundStyle(palette.muted)
                    }
                }
            }
        }
        .frame(height: compact ? previewHeight : historyHeight)
        .accessibilityLabel("График температуры охлаждающей жидкости")
    }
}

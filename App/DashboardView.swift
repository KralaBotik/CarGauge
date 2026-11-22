import CarGaugeCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    var previewDate: Date? = nil
    let showHistory: () -> Void
    let showSettings: () -> Void
    let showAdapter: () -> Void

    var body: some View {
        GaugePage {
            dashboardHeader
            connectionStatus

            if !model.hasConfiguredAdapter && !model.canRetryConnection && !model.isRunning && !isSimulation {
                adapterOnboarding
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = previewDate ?? context.date
                    let coolant = model.phase == .parked ? nil : model.coolant?.gaugeValue(at: now)
                    VStack(spacing: GaugeSpacing.medium) {
                        if model.phase == .parked {
                            parkedState
                        } else if coolant == nil && model.history.isEmpty {
                            waitingState
                        } else {
                            TemperatureInstrument(value: coolant, thresholds: model.thresholds,
                                                  alert: model.level)
                            metricStrip(at: now)
                            if model.phase == .failed || model.phase == .stopped { retryButton }
                        }
                    }
                }

                if !model.history.isEmpty {
                    chartPanel
                }
            }
        }
        .accessibilityIdentifier("instruments-screen")
    }

    private var isSimulation: Bool {
        #if DEBUG
        return model.source == .simulator
        #else
        return false
        #endif
    }

    private var dashboardHeader: some View {
        let actions = HStack(spacing: GaugeSpacing.small) {
            navigationButton("Поездка", symbol: "chart.xyaxis.line", id: "history-nav", action: showHistory)
            navigationButton("Настройки", symbol: "gearshape", id: "settings-nav", action: showSettings)
        }
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.small))
            : AnyLayout(HStackLayout(alignment: .center))
        return layout {
            Text("CarGauge")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .tracking(-1)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    private func navigationButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, GaugeSpacing.small)
            .padding(.vertical, GaugeSpacing.xsmall)
            .frame(minWidth: 44, minHeight: 44)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private var connectionStatus: some View {
        let (symbol, tone): (String, Color) = switch model.phase {
        case .streaming: ("checkmark.circle.fill", palette.operating)
        case .connecting, .retrying: ("dot.radiowaves.left.and.right", palette.accent)
        case .failed: ("exclamationmark.circle", palette.warning)
        case .parked, .stopped: ("pause.circle", palette.muted)
        case .idle, .awaitingAdapter: ("link", palette.muted)
        }
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.small))
            : AnyLayout(HStackLayout(spacing: GaugeSpacing.small))
        return layout {
            GaugeStatus(title: model.connectionTitle, symbol: symbol, tone: tone)
                .accessibilityIdentifier("connection-status")
            #if DEBUG
            if isSimulation {
                SourceIndicator(source: model.source)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var adapterOnboarding: some View {
        GaugePanel(instrument: true, inset: GaugeSpacing.section) {
            VStack(alignment: .leading, spacing: GaugeSpacing.large) {
                Image(systemName: "car.side")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 56, height: 56)
                    .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                Text("Подключите OBD-II адаптер")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Вставьте адаптер в разъём автомобиля и включите зажигание.")
                    .font(.body)
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: showAdapter) {
                    Label("Найти адаптер", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(GaugeActionStyle(emphasized: true))
                .accessibilityIdentifier("find-adapter")
            }
        }
    }

    private var waitingState: some View {
        GaugePanel(instrument: true) {
            VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                Text(model.phase == .failed ? "Проверьте подключение" : "Ожидание первого замера")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(model.phase == .failed
                     ? "Проверьте адаптер и попробуйте подключиться снова."
                     : "Показатели появятся после получения данных от автомобиля.")
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRunning {
                    ProgressView().accessibilityLabel("Подключаемся к адаптеру")
                } else if model.canRetryConnection {
                    retryButton
                }
            }
        }
    }

    private var parkedState: some View {
        GaugePanel(instrument: true) {
            VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                Text("Двигатель не работает")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Измерения приостановлены. История замеров доступна ниже.")
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Возобновить измерения") { model.start() }
                    .buttonStyle(GaugeActionStyle())
                    .accessibilityIdentifier("resume-measurements")
            }
        }
    }

    private var retryButton: some View {
        Button("Повторить подключение") { model.start(preservingHistory: true) }
            .buttonStyle(GaugeActionStyle(emphasized: true))
            .accessibilityIdentifier("retry-connection")
    }

    private var chartPanel: some View {
        GaugePanel {
            VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Прогрев").font(.headline).accessibilityAddTraits(.isHeader)
                        Text("Последние 5 минут").font(.caption).foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: GaugeSpacing.small)
                    Button(action: showHistory) {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel("Открыть историю")
                }
                .accessibilityIdentifier("chart-preview")
                WarmupChart(points: model.history, thresholds: model.thresholds, compact: true,
                            alert: model.level, tripStartedAt: model.tripStartedAt)
                    .accessibilityIdentifier("warmup-plot")
            }
        }
    }

    private func metricStrip(at now: Date) -> some View {
        let rpm = model.supplementary?.rpm?.gaugeValue(at: now)
        let voltage = model.supplementary?.voltage?.gaugeValue(at: now)
        let rpmLabel = rpm.map { String(Int($0.rounded())) } ?? "—"
        let voltageLabel = voltage.map { "\($0.formatted(.number.precision(.fractionLength(1)))) В" } ?? "—"
        let voltageDetail = voltage == nil ? "Нет данных" : (model.supplementary?.voltageSource == .adapter ? "По адаптеру" : "Блок управления")
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: GaugeSpacing.large))

        return layout {
            GaugeMetric(title: "Обороты", symbol: "gauge.with.dots.needle.33percent",
                        value: rpmLabel, detail: rpm == nil ? "Нет данных" : "об/мин", id: "rpm-value")
            GaugeMetric(title: "Напряжение", symbol: "bolt",
                        value: voltageLabel, detail: voltageDetail, id: "voltage-value")
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
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.muted)
            Text(value)
                .font(.system(size: numberSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(id)
                .accessibilityLabel(value == "—" ? "Нет данных" : value)
                .accessibilityHint("\(title), \(detail)")
            Text(detail).font(.caption).foregroundStyle(palette.muted)
        }
        .padding(GaugeSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: GaugeSpacing.corner))
    }
}

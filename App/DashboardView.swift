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
        GaugePage(spacing: GaugeSpacing.medium) {
            dashboardHeader
            GaugeRule()

            if needsAdapter {
                adapterOnboarding
            } else {
                connectionStatus
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = previewDate ?? context.date
                    let coolant = model.phase == .parked ? nil : model.coolant?.gaugeValue(at: now)
                    if model.phase == .parked {
                        parkedState
                    } else if coolant == nil && model.history.isEmpty {
                        waitingState
                    } else {
                        VStack(spacing: GaugeSpacing.medium) {
                            TemperatureInstrument(value: coolant, thresholds: model.thresholds, alert: model.level)
                            GaugeRule()
                            metrics(at: now)
                            if model.phase == .failed || model.phase == .stopped { retryButton }
                        }
                    }
                }

                if !model.history.isEmpty { chartSection }
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

    private var needsAdapter: Bool {
        !model.hasConfiguredAdapter && !model.canRetryConnection && !model.isRunning && !isSimulation
    }

    private var dashboardHeader: some View {
        let navigation = ViewThatFits(in: .horizontal) {
            HStack(spacing: GaugeSpacing.medium) { navigationActions }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: GaugeSpacing.small) { navigationActions }
        }
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: GaugeSpacing.small))
        return layout {
            Text("CarGauge")
                .font(.title.weight(.bold))
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            navigation
        }
    }

    @ViewBuilder private var navigationActions: some View {
        navigationButton("Поездка", symbol: "chart.xyaxis.line", id: "history-nav", action: showHistory)
        navigationButton("Настройки", symbol: "gearshape", id: "settings-nav", action: showSettings)
    }

    private func navigationButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(minWidth: 48, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.text)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private var connectionStatus: some View {
        let (symbol, tone): (String, Color) = switch model.phase {
        case .streaming: ("circle.fill", palette.operating)
        case .connecting, .retrying: ("dot.radiowaves.left.and.right", palette.accent)
        case .failed: ("exclamationmark.circle", palette.warning)
        case .parked, .stopped: ("pause.circle", palette.muted)
        case .idle, .awaitingAdapter: ("link", palette.muted)
        }

        let status = GaugeStatus(title: model.connectionTitle, symbol: symbol, tone: tone)
            .accessibilityIdentifier("connection-status")
        let stacked = VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            status
            connectionAccessory
        }
        return Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: GaugeSpacing.medium) {
                        status
                        connectionAccessory
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    stacked
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var connectionAccessory: some View {
        #if DEBUG
        if isSimulation {
            SourceIndicator(source: model.source)
        }
        #endif
    }

    private var adapterOnboarding: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.section) {
            PairingIllustration()
                .padding(.top, GaugeSpacing.large)
            GaugeHeading(title: "Подключите автомобиль",
                         subtitle: "CarGauge считывает температуру двигателя через Bluetooth-адаптер.")
            VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                Label("Вставьте адаптер в диагностический разъём", systemImage: "powerplug")
                Label("Включите зажигание", systemImage: "key")
            }
            .font(.body)
            .foregroundStyle(palette.text)

            Button(action: showAdapter) {
                Label("Найти адаптер", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(GaugeActionStyle(emphasized: true))
            .accessibilityIdentifier("find-adapter")
        }
        .padding(.bottom, GaugeSpacing.section)
    }

    private var waitingState: some View {
        let failed = model.phase == .failed
        let waiting = model.isRunning
        return VStack(alignment: .leading, spacing: GaugeSpacing.large) {
            if waiting {
                ProgressView().tint(palette.accent)
                    .accessibilityLabel("Подключаемся к адаптеру")
            }
            GaugeHeading(title: failed ? "Проверьте подключение" : waiting ? "Ожидание первого замера" : "Готово к поездке",
                         subtitle: failed ? connectionHelp : waiting
                             ? "Обычно достаточно включить зажигание."
                             : "Подключитесь, когда автомобиль будет готов.")
            if !waiting && model.canRetryConnection {
                retryButton
                if failed && !isSimulation {
                    Button("Выбрать другой адаптер", action: showAdapter)
                        .buttonStyle(GaugeActionStyle())
                }
            }
        }
        .padding(.vertical, GaugeSpacing.section)
    }

    private var connectionHelp: String {
        switch model.ble.diagnosticDetail {
        case .poweredOff: "Включите Bluetooth на iPhone и повторите подключение."
        case .unauthorized: "Разрешите CarGauge доступ к Bluetooth в настройках iPhone."
        case .unsupportedProfile: "CarGauge не нашёл канал связи с адаптером. Проверьте, что это BLE-модель."
        default: "Убедитесь, что адаптер получает питание и зажигание включено."
        }
    }

    private var parkedState: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.large) {
            GaugeHeading(title: "Двигатель не работает",
                         subtitle: "Измерения приостановлены. Температура за поездку доступна на графике.")
            Button("Возобновить измерения") { model.start() }
                .buttonStyle(GaugeActionStyle())
                .accessibilityIdentifier("resume-measurements")
        }
        .padding(.vertical, GaugeSpacing.section)
    }

    private var retryButton: some View {
        Button("Повторить подключение") { model.start(preservingHistory: true) }
            .buttonStyle(GaugeActionStyle(emphasized: true))
            .accessibilityIdentifier("retry-connection")
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            GaugeRule()
            Button(action: showHistory) {
                HStack(spacing: GaugeSpacing.medium) {
                    VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                        Text("Температура в поездке").font(.headline)
                        Text("Последние 5 минут").font(.caption).foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: GaugeSpacing.small)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открывает историю замеров")
            .accessibilityIdentifier("chart-preview")
            WarmupChart(points: model.history, thresholds: model.thresholds, compact: true,
                        alert: model.level, tripStartedAt: model.tripStartedAt)
                .accessibilityIdentifier("warmup-plot")
        }
    }

    private func metrics(at now: Date) -> some View {
        let rpm = model.supplementary?.rpm?.gaugeValue(at: now)
        let voltage = model.supplementary?.voltage?.gaugeValue(at: now)
        let rpmLabel = rpm.map { Int($0.rounded()).formatted() }
        let voltageLabel = voltage.map { $0.formatted(.number.precision(.fractionLength(1))) }
        let layout = typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: GaugeSpacing.large))

        return layout {
            GaugeMetric(title: "Обороты", value: rpmLabel, unit: "об/мин", spokenUnit: "оборотов в минуту",
                        id: "rpm-value")
            if typeSize >= .xxLarge { GaugeRule() }
            GaugeMetric(title: "Напряжение", value: voltageLabel, unit: "В", spokenUnit: "вольт",
                        detail: voltage == nil ? nil : model.supplementary?.voltageSource == .adapter ? "По адаптеру" : "По ЭБУ",
                        id: "voltage-value")
        }
    }
}

private struct GaugeMetric: View {
    @Environment(\.gaugePalette) private var palette
    @ScaledMetric(relativeTo: .title) private var digitSize: CGFloat = 34
    let title: String
    let value: String?
    let unit: String
    let spokenUnit: String
    var detail: String?
    let id: String

    var body: some View {
        let digits = Text(value ?? "—")
            .font(.system(size: digitSize, weight: .semibold))
            .monospacedDigit()
        let suffix = Text(unit).font(.caption.weight(.medium)).foregroundColor(palette.muted)
        let reading: LocalizedStringKey = value == nil ? "\(digits)" : "\(digits) \(suffix)"
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(palette.muted)
            Text(reading)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel(value.map { "\($0) \(spokenUnit)" } ?? "Нет данных")
                .accessibilityIdentifier(id)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PairingIllustration: View {
    @Environment(\.gaugePalette) private var palette

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "iphone")
            Capsule().fill(palette.line).frame(width: 22, height: 1)
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(palette.accent)
            Capsule().fill(palette.line).frame(width: 22, height: 1)
            Image(systemName: "car.side")
        }
        .font(.system(size: 29, weight: .light))
        .foregroundStyle(palette.muted)
        .accessibilityHidden(true)
    }
}

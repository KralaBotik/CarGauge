import CarGaugeCore
import SwiftUI
import UIKit

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.gaugePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL

    var previewDate: Date?
    let showHistory: () -> Void
    let showAdapter: () -> Void

    var body: some View {
        GaugePage(spacing: GaugeSpacing.large) {
            dashboardHeader
            GaugeRule()
            if needsAdapter {
                onboarding
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    instruments(at: previewDate ?? context.date)
                }
                if !model.history.isEmpty { chartSection }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if needsAdapter {
                primaryAction("Найти адаптер", symbol: "arrow.right", id: "find-adapter", action: showAdapter)
                    .frame(maxWidth: 516)
                    .padding(.horizontal, GaugeSpacing.page)
                    .padding(.vertical, GaugeSpacing.medium)
                    .frame(maxWidth: .infinity)
                    .background(palette.canvas)
            }
        }
        .accessibilityIdentifier("instruments-screen")
    }

    private var isSimulation: Bool {
        #if DEBUG
        model.source == .simulator
        #else
        false
        #endif
    }

    private var needsAdapter: Bool {
        !model.hasConfiguredAdapter && !model.canRetryConnection && !model.isRunning && !isSimulation
    }

    private var dashboardHeader: some View {
        let wordmark = HStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.body.weight(.medium))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text("CarGauge")
                .font(.title3.weight(.semibold))
                .tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
        }

        return VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            if needsAdapter {
                wordmark
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: GaugeSpacing.medium) {
                        wordmark.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        connectionStatus.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: GaugeSpacing.small) {
                        wordmark
                        connectionStatus
                    }
                }
                #if DEBUG
                if isSimulation { SourceIndicator(source: model.source) }
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionStatus: some View {
        let (symbol, tone): (String, Color) = switch model.phase {
        case .streaming: ("link", palette.operating)
        case .connecting, .retrying: ("dot.radiowaves.left.and.right", palette.accent)
        case .failed: ("exclamationmark.circle", palette.warning)
        case .parked, .stopped: ("pause.circle", palette.muted)
        case .idle, .awaitingAdapter: ("link", palette.muted)
        }

        return Label(model.connectionTitle, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone)
            .accessibilityIdentifier("connection-status")
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.section) {
            GaugeHeading(title: "Подключите автомобиль", subtitle: "Понадобится Bluetooth-адаптер OBD-II.")

            OBDConnectorDiagram()
                .frame(height: typeSize.isAccessibilitySize ? 74 : 120)

            VStack(alignment: .leading, spacing: GaugeSpacing.large) {
                OnboardingStep(symbol: "arrow.down.to.line", title: "Вставьте адаптер", detail: "В диагностический разъём автомобиля.")
                GaugeRule()
                OnboardingStep(symbol: "key", title: "Включите зажигание", detail: "Затем выберите адаптер из списка.")
            }
        }
        .padding(.top, GaugeSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func instruments(at now: Date) -> some View {
        let coolant = model.coolant?.gaugeValue(at: now)
        if model.phase == .parked {
            parkedState
        } else if model.phase == .failed || model.phase == .stopped || model.phase == .idle {
            if !model.history.isEmpty {
                TemperatureInstrument(value: nil, thresholds: model.thresholds, alert: model.level)
            }
            connectionRecovery
        } else if coolant == nil && model.history.isEmpty && model.phase != .streaming {
            waitingState
        } else {
            VStack(alignment: .leading, spacing: GaugeSpacing.large) {
                TemperatureInstrument(value: coolant, thresholds: model.thresholds, alert: model.level)
                    .padding(.vertical, typeSize.isAccessibilitySize ? GaugeSpacing.xsmall : GaugeSpacing.medium)
                if model.phase == .retrying || model.phase == .connecting {
                    Label("Ждём ответ автомобиля", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                } else {
                    GaugeRule()
                    metrics(at: now)
                }
            }
        }
    }

    private var waitingState: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.large) {
            ProgressView().tint(palette.accent)
                .accessibilityLabel("Подключаемся к адаптеру")
            GaugeHeading(title: "Ожидание первого замера",
                         subtitle: "Оставьте зажигание включённым. Показания появятся, когда автомобиль ответит.")
        }
        .padding(.vertical, GaugeSpacing.large)
    }

    private var connectionRecovery: some View {
        let failed = model.phase == .failed
        return VStack(alignment: .leading, spacing: GaugeSpacing.large) {
            GaugeHeading(title: failed ? "Проверьте подключение" :
                            model.phase == .stopped ? "Измерения остановлены" : "Готово к поездке",
                         subtitle: failed ? connectionHelp : "Подключитесь, когда автомобиль будет готов.")
            if failed && model.ble.diagnosticDetail == .unauthorized {
                primaryAction("Открыть настройки iPhone", symbol: "arrow.up.right", id: "open-bluetooth-settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if model.canRetryConnection {
                primaryAction("Повторить подключение", symbol: "arrow.clockwise", id: "retry-connection") {
                    model.start(preservingHistory: true)
                }
            }
            if failed && !isSimulation {
                Button("Выбрать другой адаптер", action: showAdapter)
                    .buttonStyle(GaugeActionStyle())
            }
        }
        .padding(.vertical, GaugeSpacing.small)
    }

    private var connectionHelp: String {
        switch model.ble.diagnosticDetail {
        case .poweredOff: "Включите Bluetooth на iPhone и повторите подключение."
        case .unauthorized: "Разрешите CarGauge доступ к Bluetooth в настройках iPhone."
        case .unsupportedProfile: "Проверьте, что ваш OBD-II адаптер поддерживает Bluetooth LE."
        default: "Убедитесь, что адаптер получает питание и зажигание включено."
        }
    }

    private var parkedState: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.large) {
            GaugeHeading(title: "Двигатель не работает", subtitle: "Измерения приостановлены.")
            primaryAction("Возобновить измерения", symbol: "arrow.right", id: "resume-measurements") {
                model.start()
            }
        }
        .padding(.vertical, GaugeSpacing.large)
    }

    private func primaryAction(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GaugeSpacing.medium) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: symbol).accessibilityHidden(true)
            }
            .frame(minHeight: 36)
        }
        .buttonStyle(GaugeActionStyle(emphasized: true))
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.small) {
            GaugeRule()
            Button(action: showHistory) {
                HStack(spacing: GaugeSpacing.medium) {
                    VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                        Text("График поездки")
                            .font(.headline)
                        Text(model.phase == .streaming ? "До 5 минут замеров" : "Последние полученные замеры")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: GaugeSpacing.small)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("График температуры в поездке")
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
        let rpmLabel = rpm.map { Int($0.rounded()).formatted(.number.grouping(.never)) }
        let voltageLabel = voltage.map { $0.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
        let layout = typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: GaugeSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: GaugeSpacing.large))

        return layout {
            GaugeMetric(title: "Обороты", value: rpmLabel, unit: "об/мин", spokenUnit: "оборотов в минуту",
                        id: "rpm-value")
            if typeSize >= .xxLarge {
                GaugeRule()
            } else {
                Rectangle().fill(palette.line).frame(width: 1, height: 68).accessibilityHidden(true)
            }
            GaugeMetric(title: "Напряжение", value: voltageLabel, unit: "В", spokenUnit: "вольт",
                        detail: voltage == nil ? nil : model.supplementary?.voltageSource == .adapter ? "Оценка адаптера" : "От автомобиля",
                        id: "voltage-value")
        }
    }
}

private struct OBDConnectorDiagram: View {
    @Environment(\.gaugePalette) private var palette

    var body: some View {
        Canvas { context, size in
            let scale = min(size.height / 108, size.width / 280)
            let center = size.width / 2
            let top = (size.height - 96 * scale) / 2
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center + x * scale, y: top + y * scale)
            }

            var housing = Path()
            housing.move(to: point(-63, 13))
            housing.addLine(to: point(63, 13))
            housing.addLine(to: point(49, 63))
            housing.addQuadCurve(to: point(41, 70), control: point(47, 70))
            housing.addLine(to: point(-41, 70))
            housing.addQuadCurve(to: point(-49, 63), control: point(-47, 70))
            housing.closeSubpath()
            context.fill(housing, with: .color(palette.panel))
            context.stroke(housing, with: .color(palette.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            var cable = Path()
            cable.move(to: point(-28, 70))
            cable.addLine(to: point(-28, 83))
            cable.addLine(to: point(28, 83))
            cable.addLine(to: point(28, 70))
            cable.move(to: point(0, 84))
            cable.addLine(to: point(0, 96))
            context.stroke(cable, with: .color(palette.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for row in 0..<2 {
                for column in 0..<8 {
                    let pin = point(-37.5 + 10 * CGFloat(column), 29 + 16 * CGFloat(row))
                    context.fill(Path(roundedRect: CGRect(origin: pin, size: CGSize(width: 5 * scale, height: 5 * scale)),
                                      cornerRadius: scale), with: .color(palette.muted))
                }
            }

            for side in [-1.0, 1.0] {
                var guide = Path()
                guide.move(to: point(CGFloat(side) * 73, 41))
                guide.addLine(to: point(CGFloat(side) * 127, 41))
                context.stroke(guide, with: .color(palette.line), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GaugeMetric: View {
    @Environment(\.gaugePalette) private var palette
    @ScaledMetric(relativeTo: .title) private var digitSize: CGFloat = 39

    let title: String
    let value: String?
    let unit: String
    let spokenUnit: String
    var detail: String?
    let id: String

    var body: some View {
        let digits = Text(value ?? "—")
            .font(.system(size: min(digitSize, 84), weight: .medium))
            .monospacedDigit()
            .tracking(-0.9)
        let suffix = Text(unit).font(.caption.weight(.semibold)).foregroundStyle(palette.muted)
        let reading: LocalizedStringKey = value == nil ? "\(digits)" : "\(digits) \(suffix)"

        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.muted)
            Text(reading)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityLabel(value.map { "\($0) \(spokenUnit)" } ?? "Нет данных")
                .accessibilityIdentifier(id)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingStep: View {
    @Environment(\.gaugePalette) private var palette

    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: GaugeSpacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(palette.accent)
                .font(.body.weight(.medium))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

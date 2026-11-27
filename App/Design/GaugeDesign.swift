import CarGaugeCore
import SwiftUI

enum GaugeAppearance: String, CaseIterable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: "Как в iOS"
        case .dark: "Тёмная"
        case .light: "Светлая"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum GaugeSpacing {
    static let xsmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let page: CGFloat = 22
    static let section: CGFloat = 24
}

struct GaugePalette {
    let scheme: ColorScheme

    var canvas: Color { pair(0x17191C, 0xF6F3ED) }
    var panel: Color { pair(0x232529, 0xEEE8DE) }
    var line: Color { pair(0x49494B, 0xC9C0B3) }
    var text: Color { pair(0xF5F0E7, 0x23201D) }
    var muted: Color { pair(0xBCB5AA, 0x5D554A) }
    var accent: Color { pair(0xECC38D, 0x744A18) }
    var trace: Color { pair(0xCFB48E, 0x895C2A) }
    var warming: Color { pair(0xAEC9E4, 0x355B78) }
    var operating: Color { pair(0xA4CBA9, 0x2A623C) }
    var warning: Color { pair(0xF4BE79, 0x874A0D) }
    var critical: Color { pair(0xFFA797, 0xA0352C) }
    var actionText: Color { pair(0x241C14, 0xFFFFFF) }

    func tone(for state: EngineTemperatureState) -> Color {
        switch state {
        case .warmingUp: warming
        case .operating: operating
        case .warning: warning
        case .critical: critical
        }
    }

    private func pair(_ dark: UInt32, _ light: UInt32) -> Color {
        let rgb = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

private struct GaugePaletteKey: EnvironmentKey {
    static let defaultValue = GaugePalette(scheme: .dark)
}

extension EnvironmentValues {
    var gaugePalette: GaugePalette {
        get { self[GaugePaletteKey.self] }
        set { self[GaugePaletteKey.self] = newValue }
    }
}

struct GaugeRule: View {
    @Environment(\.gaugePalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.line.opacity(0.75))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct GaugeSection<Content: View>: View {
    @Environment(\.gaugePalette) private var palette
    let title: String
    var headerID: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
            GaugeRule()
            let heading = Text(title)
                .font(.headline)
                .foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
            if let headerID { heading.accessibilityIdentifier(headerID) } else { heading }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GaugePage<Content: View>: View {
    @Environment(\.gaugePalette) private var palette
    var spacing: CGFloat = GaugeSpacing.large
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, GaugeSpacing.page)
                .padding(.vertical, GaugeSpacing.large)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(palette.canvas.ignoresSafeArea())
        .foregroundStyle(palette.text)
    }
}

struct GaugeHeading: View {
    @Environment(\.gaugePalette) private var palette
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.small) {
            Text(title).font(.largeTitle.weight(.semibold)).tracking(-1).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.body).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GaugeStatus: View {
    let title: String
    let symbol: String
    let tone: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tone)
    }
}

#if DEBUG
struct SourceIndicator: View {
    @Environment(\.gaugePalette) private var palette
    let source: DataSource

    var body: some View {
        Label(source == .simulator ? "Тестовые данные" : "Автомобиль",
              systemImage: source == .simulator ? "flask" : "car.side")
            .font(.caption.weight(.semibold))
            .foregroundStyle(source == .simulator ? palette.warning : palette.muted)
            .accessibilityIdentifier("source-indicator")
    }
}
#endif

struct GaugeActionStyle: ButtonStyle {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        let solid = emphasized && isEnabled
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, GaugeSpacing.medium)
            .padding(.vertical, GaugeSpacing.small)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(!isEnabled ? palette.muted : solid ? palette.actionText : palette.text)
            .background(solid ? palette.accent : palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

extension Reading {
    func gaugeValue(at now: Date) -> Double? { isFresh(at: now) ? value : nil }
}

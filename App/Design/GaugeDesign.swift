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
    static let page: CGFloat = 20
    static let section: CGFloat = 24
    static let corner: CGFloat = 20
}

struct GaugePalette {
    let scheme: ColorScheme

    var canvas: Color { pair(0x111A1F, 0xEDF1F0) }
    var panel: Color { pair(0x1A262C, 0xF9FBFA) }
    var raised: Color { pair(0x243239, 0xE1E8E7) }
    var instrumentTop: Color { pair(0x263942, 0xFFFFFF) }
    var instrumentBottom: Color { pair(0x19252B, 0xE6EFEE) }
    var line: Color { pair(0x3B5059, 0xBECBCB) }
    var text: Color { pair(0xF3F6F4, 0x15292E) }
    var muted: Color { pair(0xAEBDC5, 0x465D64) }
    var accent: Color { pair(0xFFAE80, 0x8C3B21) }
    var trace: Color { pair(0x9BDACB, 0x256C64) }
    var warming: Color { pair(0xA7D5EF, 0x315E77) }
    var operating: Color { pair(0xA9DCC2, 0x23634F) }
    var warning: Color { pair(0xFFD08B, 0x815013) }
    var critical: Color { pair(0xFFAA9C, 0x9D332A) }
    var action: Color { pair(0xFFAE80, 0x8C3B21) }
    var actionText: Color { pair(0x291A16, 0xFFFFFF) }

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

struct GaugePanel<Content: View>: View {
    @Environment(\.gaugePalette) private var palette
    var instrument = false
    var inset: CGFloat = GaugeSpacing.large
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GaugeSpacing.corner)
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if instrument {
                    shape.fill(LinearGradient(colors: [palette.instrumentTop, palette.instrumentBottom],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(palette.panel)
                }
            }
            .overlay { shape.strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct GaugePage<Content: View>: View {
    @Environment(\.gaugePalette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GaugeSpacing.medium) {
                content
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, GaugeSpacing.page)
            .padding(.top, GaugeSpacing.medium)
            .padding(.bottom, GaugeSpacing.section)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(palette.canvas.ignoresSafeArea())
        .foregroundStyle(palette.text)
    }
}

struct GaugeHeading: View {
    @Environment(\.gaugePalette) private var palette
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GaugeSpacing.xsmall) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(palette.muted)
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
            .foregroundStyle(source == .simulator ? palette.accent : palette.muted)
            .accessibilityIdentifier("source-indicator")
    }
}
#endif

struct GaugeActionStyle: ButtonStyle {
    @Environment(\.gaugePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, GaugeSpacing.medium)
            .padding(.vertical, GaugeSpacing.small)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(!isEnabled ? palette.muted : emphasized ? palette.actionText : palette.text)
            .background(emphasized && isEnabled ? palette.action : palette.raised, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

extension Reading {
    func gaugeValue(at now: Date) -> Double? { isFresh(at: now) ? value : nil }
}

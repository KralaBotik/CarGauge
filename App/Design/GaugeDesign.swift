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

    var canvas: Color { pair(0x171B1E, 0xEDECE8) }
    var panel: Color { pair(0x20262A, 0xFAF9F5) }
    var raised: Color { pair(0x2A3034, 0xE7E7E0) }
    var instrumentTop: Color { pair(0x2B3338, 0xFDFBF6) }
    var instrumentBottom: Color { pair(0x22292D, 0xEEEFE8) }
    var line: Color { pair(0x3C454B, 0xC9CECA) }
    var text: Color { pair(0xF3F1EB, 0x20282B) }
    var muted: Color { pair(0xB1BDC3, 0x526066) }
    var accent: Color { pair(0xF1C9A1, 0x854721) }
    var trace: Color { pair(0xADD4C3, 0x326752) }
    var warming: Color { pair(0xB0CEDD, 0x356176) }
    var operating: Color { pair(0xBAD8C2, 0x306144) }
    var warning: Color { pair(0xF7CA84, 0x8C4F14) }
    var critical: Color { pair(0xFFA89E, 0x9A332E) }
    var accentWash: Color { pair(0x3B332D, 0xF1DFCE) }

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
        .toolbarBackground(palette.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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

struct GaugeCaption: View {
    @Environment(\.gaugePalette) private var palette
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: GaugeSpacing.small) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title).tracking(0.45)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(palette.muted)
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

struct SourceIndicator: View {
    @Environment(\.gaugePalette) private var palette
    let source: DataSource

    var body: some View {
        Label(source == .simulator ? "Симулятор" : "Автомобиль",
              systemImage: source == .simulator ? "flask" : "car.side")
            .font(.caption.weight(.semibold))
            .foregroundStyle(source == .simulator ? palette.accent : palette.muted)
            .accessibilityIdentifier("source-indicator")
    }
}

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
            .foregroundStyle(isEnabled ? palette.accent : palette.muted)
            .background(emphasized ? palette.accentWash : palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

extension Reading {
    func gaugeValue(at now: Date) -> Double? { isFresh(at: now) ? value : nil }
}

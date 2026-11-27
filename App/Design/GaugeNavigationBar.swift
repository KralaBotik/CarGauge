import SwiftUI

enum GaugeMainSection: String, CaseIterable {
    case instruments, history, settings

    var title: String {
        switch self {
        case .instruments: "Приборы"
        case .history: "Поездка"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .instruments: "gauge.with.dots.needle.33percent"
        case .history: "chart.xyaxis.line"
        case .settings: "gearshape"
        }
    }
}

struct GaugeNavigationBar: View {
    @Environment(\.gaugePalette) private var palette
    @State private var selectionFeedback = 0
    let selection: GaugeMainSection
    let select: (GaugeMainSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GaugeRule()
            HStack(spacing: GaugeSpacing.small) {
                ForEach(GaugeMainSection.allCases, id: \.self) { section in
                    sectionButton(section)
                }
            }
            .padding(.horizontal, GaugeSpacing.large)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(palette.canvas, ignoresSafeAreaEdges: .bottom)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Основная навигация")
    }

    private func sectionButton(_ section: GaugeMainSection) -> some View {
        let selected = section == selection
        return Button {
            if !selected { selectionFeedback += 1 }
            select(section)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: section.symbol)
                    .font(.body.weight(selected ? .semibold : .regular))
                ViewThatFits(in: .horizontal) {
                    Text(section.title)
                        .font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 53)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? palette.accent : palette.muted)
            .overlay(alignment: .top) {
                if selected {
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 25, height: 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(section.rawValue)-nav")
    }
}

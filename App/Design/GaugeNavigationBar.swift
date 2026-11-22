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
    let selection: GaugeMainSection
    let select: (GaugeMainSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GaugeRule()
            HStack(spacing: GaugeSpacing.xsmall) {
                ForEach(GaugeMainSection.allCases, id: \.self) { section in
                    sectionButton(section)
                }
            }
            .padding(.horizontal, GaugeSpacing.medium)
            .padding(.vertical, GaugeSpacing.xsmall)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(palette.canvas, ignoresSafeAreaEdges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Основная навигация")
    }

    private func sectionButton(_ section: GaugeMainSection) -> some View {
        let selected = section == selection
        return Button {
            select(section)
        } label: {
            ViewThatFits(in: .horizontal) {
                Label(section.title, systemImage: section.symbol)
                    .fixedSize(horizontal: true, vertical: false)
                Text(section.title)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: section.symbol)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? palette.accent : palette.muted)
            .background(selected ? palette.panel : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(section.rawValue)-nav")
    }
}

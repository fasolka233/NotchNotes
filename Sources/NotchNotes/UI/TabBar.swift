import SwiftUI

struct TabBar: View {
    @Binding var selection: NotchTab
    var badges: [NotchTab: Int] = [:]

    @Namespace private var ns
    @State private var hovered: NotchTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(NotchTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    withAnimation(Theme.snap) { selection = tab }
                } label: {
                    tabLabel(tab)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tab : (hovered == tab ? nil : hovered) }
                .help("\(tab.title)  ⌘\(index + 1)")
                .accessibilityLabel(tab.title)
            }
        }
        .padding(3)
        .background(Theme.Surface.base, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.hairline, lineWidth: 1))
        .animation(Theme.quick, value: hovered)
    }

    /// Подпись показываем у выбранной вкладки и у той, на которую навели —
    /// иначе иконки без подписей приходится расшифровывать каждый раз.
    @ViewBuilder
    private func tabLabel(_ tab: NotchTab) -> some View {
        let isOn = selection == tab
        let showTitle = isOn || hovered == tab
        let count = badges[tab] ?? 0

        HStack(spacing: 5) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14)

            if showTitle {
                Text(tab.title)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .fixedSize()
            }

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn ? Theme.Ink.secondary : Theme.Ink.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            if isOn {
                Capsule()
                    .fill(Theme.Surface.active)
                    .matchedGeometryEffect(id: "tabbg", in: ns)
            } else if hovered == tab {
                Capsule().fill(Theme.Surface.hover)
            }
        }
        .foregroundStyle(isOn ? Theme.Ink.primary : Theme.Ink.secondary)
        .contentShape(Capsule())
    }
}

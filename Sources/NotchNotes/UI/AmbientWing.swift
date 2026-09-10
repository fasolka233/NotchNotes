import SwiftUI

/// Одно крыло свёрнутой челки — узкая полоска слева или справа от выреза.
///
/// Крыло само по себе пустое: оно отвечает за ширину, выравнивание к вырезу,
/// наведение и клик. Что именно показать, решает `NotchView` — так правила
/// приоритета («просрочка важнее счётчика задач») живут в одном месте.
struct AmbientWing<Content: View>: View {
    @ObservedObject var vm: NotchViewModel
    let side: NotchViewModel.Wing
    let onOpen: (NotchTab) -> Void
    @ViewBuilder var content: () -> Content

    private var isEmpty: Bool { !vm.hasBadge(side) }

    var body: some View {
        content()
            // Отступы — ВНУТРИ фиксированной ширины. Снаружи они добавляли
            // крылу лишние пункты, сумма переставала совпадать с collapsedSize,
            // и SwiftUI сжимал резерв под вырез: нарисованная челка становилась
            // уже физической, а значки наползали на камеру.
            // 8 пт у выреза — воздух вокруг камеры, 6 пт снаружи — чтобы текст
            // не упирался в скруглённый край панели.
            .padding(.leading, side == .left ? 6 : 8)
            .padding(.trailing, side == .left ? 8 : 6)
            // Содержимое прижимаем к вырезу: значки читаются как продолжение
            // челки, а не как две отдельные наклейки по краям экрана.
            // Ширина одна на оба крыла — пустое остаётся пустым местом, иначе
            // раскладка съезжает и вырез перестаёт совпадать с физическим.
            .frame(width: vm.wingWidth,
                   alignment: side == .left ? .trailing : .leading)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard !isEmpty else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    vm.hoveredWing = hovering ? side : (vm.hoveredWing == side ? nil : vm.hoveredWing)
                }
            }
            .onTapGesture {
                guard !isEmpty else { return }
                onOpen(vm.tab(for: side))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .allowsHitTesting(!isEmpty)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: vm.wingWidth)
    }
}

/// Значок в крыле: только значение, а под курсором — ещё и подпись.
///
/// Иконок нет намеренно. В крыле шириной с палец иконка съедала 20 пт из ~40
/// доступных ради символа, который ничего не добавлял: слева всегда задачи,
/// справа всегда таймер — место постоянное, и оно само по себе есть смысл.
/// Освободившиеся пункты ушли цифре, ради которой на челку и смотрят.
///
/// Значение (счётчик, mm:ss) всегда моноширинное — иначе на каждой секунде
/// меняется ширина строки и челка «дышит» вместе с таймером.
struct AmbientBadge: View {
    let value: String
    let label: String
    let tint: Color
    var expanded = false
    var mono = false
    /// Медленная пульсация: состояние ждёт реакции (просрочка, отзвеневший таймер)
    var pulses = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            if !value.isEmpty {
                // Значение (счётчик, mm:ss) не жмём и не режем: это сам смысл
                // значка. Место под него крыло заложило заранее.
                Text(value)
                    .font(mono ? Theme.Font.mono(11) : Theme.Font.badgeSmall)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .fixedSize()
                    .layoutPriority(1)
            }

            if expanded && !label.isEmpty {
                // Подпись — единственное, чем можно пожертвовать, если строка
                // упёрлась в потолок крыла. Гасим её многоточием, а не режем
                // ножом по глифу, как делал .clipped() у крыла.
                Text(label)
                    .font(Theme.Font.captionSmall)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .onAppear { startPulse() }
        .onChange(of: pulses) { startPulse() }
        .accessibilityLabel("\(label) \(value)")
    }

    private func startPulse() {
        guard pulses else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

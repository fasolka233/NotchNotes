import SwiftUI

struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    var onClose: () -> Void
    /// Клик по крылу свёрнутой челки — сразу нужная вкладка, без промежуточного шага
    var onOpenTab: (NotchTab) -> Void = { _ in }
    var onSettings: () -> Void = {}

    private var shapeSize: CGSize { vm.isOpen ? vm.contentSize : vm.collapsedSize }

    /// «Ушки» рисуем всегда, когда плашка шире выреза: без них расширенная челка
    /// выглядит прямоугольной наклейкой поверх выреза, а не его продолжением.
    private var topR: CGFloat {
        if vm.isOpen { return 12 }
        return vm.collapsedSize.width > vm.notchSize.width ? 10 : 0
    }
    private var bottomR: CGFloat { vm.isOpen ? 22 : (vm.collapsedSize.width > vm.notchSize.width ? 12 : 8) }

    private var shape: NotchShape { NotchShape(topRadius: topR, bottomRadius: bottomR) }

    var body: some View {
        VStack(spacing: 0) {
            shape
                .fill(Color.black)
                // едва заметный блик сверху — панель перестаёт быть плоским прямоугольником
                .overlay {
                    LinearGradient(colors: [Color.white.opacity(0.055), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
                .overlay { vm.isOpen ? AnyView(expanded) : AnyView(collapsed) }
                .clipShape(shape)
                .overlay {
                    // пунктир = «мишень готова», сплошной акцент = «отпускай»
                    if vm.isDropTargeted || (!vm.isOpen && vm.isSystemDragging) {
                        shape.strokeBorder(
                            vm.isDropTargeted ? Theme.Accent.tint : Color.white.opacity(0.45),
                            style: StrokeStyle(lineWidth: vm.isDropTargeted ? 2 : 1.5,
                                               dash: vm.isDropTargeted ? [] : [5, 4])
                        )
                    } else if vm.isOpen {
                        // волосяная рамка: отделяет панель от тёмных обоев
                        shape.strokeBorder(Theme.Stroke.hairline, lineWidth: 1)
                    }
                }
                .frame(width: shapeSize.width, height: shapeSize.height)
                .shadow(color: .black.opacity(vm.isOpen ? 0.6 : 0.3), radius: 24, y: 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.motion(.spring(response: 0.34, dampingFraction: 0.84)), value: vm.isOpen)
        .animation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.8)), value: vm.collapsedSize)
    }

    // MARK: - Свёрнутое состояние (ambient)

    private var ambientTint: Color {
        if vm.timer.isFinished { return Theme.Accent.warning }
        return vm.timer.pomodoroEnabled && vm.timer.phase.isBreak
            ? Theme.Accent.success : Theme.Ink.primary
    }

    @ViewBuilder
    private var collapsed: some View {
        if vm.droppedCount > 0 {
            dropConfirmation
        } else if vm.isSystemDragging || vm.isDropTargeted {
            dropTarget
        } else {
            ambient
        }
    }

    /// Мишень для броска: появляется, когда файл поднесли к челке.
    /// Иконка слева от выреза, подпись справа — ничего не заходит под камеру.
    private var dropTarget: some View {
        notchSplit(wing: vm.dropWingWidth) {
            Image(systemName: vm.isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(Theme.Icon.small)
                .foregroundStyle(vm.isDropTargeted ? Theme.Accent.tint : Theme.Ink.primary)
        } right: {
            Text(vm.dropHint)
                .font(Theme.Font.badge)
                .foregroundStyle(vm.isDropTargeted ? Theme.Ink.primary : Theme.Ink.secondary)
                .lineLimit(1)
        }
        .animation(Theme.motion(.easeOut(duration: 0.15)), value: vm.isDropTargeted)
    }

    /// После броска панель не раскрываем — вместо этого секунда подтверждения:
    /// пользователь в этот момент работает в другом приложении.
    private var dropConfirmation: some View {
        notchSplit(wing: vm.confirmWingWidth) {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.Icon.small)
                .foregroundStyle(Theme.Accent.success)
        } right: {
            Text(vm.dropConfirmText)
                .font(Theme.Font.badge)
                .foregroundStyle(Theme.Ink.primary)
                .lineLimit(1)
        }
        .transition(.opacity)
    }

    /// Крыло | физический вырез | крыло. Содержимое прижато к вырезу с зазором
    /// 8 пт, как у ambient-крыльев: под камеру не попадает ни пиксель.
    private func notchSplit<L: View, R: View>(wing: CGFloat,
                                              @ViewBuilder left: () -> L,
                                              @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: wing)
                .overlay(alignment: .trailing) { left().padding(.trailing, 8) }
            Color.clear.frame(width: vm.notchSize.width)
            Color.clear.frame(width: wing)
                .overlay(alignment: .leading) { right().padding(.leading, 8).padding(.trailing, 9) }
        }
        .frame(height: vm.notchSize.height)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Свёрнутая челка в покое: два крыла по бокам от физического выреза.
    /// Слева — накопленное (просрочка / открытые задачи), справа — текущее
    /// (таймер, вспышка подтверждения). Между ними резерв ровно под вырез,
    /// поэтому значки никогда не наезжают на камеру.
    private var ambient: some View {
        HStack(spacing: 0) {
            AmbientWing(vm: vm, side: .left, onOpen: onOpenTab) { leftContent }
            Color.clear.frame(width: vm.notchSize.width)
            AmbientWing(vm: vm, side: .right, onOpen: onOpenTab) { rightContent }
        }
        .frame(height: vm.notchSize.height)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var leftContent: some View {
        switch vm.leftBadge {
        case .overdue(let n):
            // Иконки нет — просрочку теперь несут цвет и пульсация. Слово
            // «просрочено» под курсором остаётся: цвет один смысл не передаёт.
            AmbientBadge(value: "\(n)",
                         label: "просрочено",
                         tint: Theme.Accent.danger,
                         expanded: vm.hoveredWing == .left,
                         pulses: true)
        case .tasks(let n):
            AmbientBadge(value: "\(n)",
                         label: n == 1 ? "задача" : "в работе",
                         tint: Theme.Ink.secondary,
                         expanded: vm.hoveredWing == .left)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        switch vm.rightBadge {
        case .flash(.copied):
            AmbientBadge(value: "",
                         label: "скопировано",
                         tint: Theme.Accent.tint,
                         expanded: true)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        case .flash(.taskDone(let left)):
            AmbientBadge(value: left > 0 ? "\(left)" : "",
                         label: left > 0 ? "осталось" : "всё готово",
                         tint: Theme.Accent.success,
                         expanded: true)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        case .timer:
            // Кольцо прогресса ушло вместе с иконкой: время и так видно цифрами,
            // а отзвеневший таймер по-прежнему опознаётся цветом и пульсацией.
            AmbientBadge(value: vm.timer.formatted,
                         label: vm.timer.pomodoroEnabled ? vm.timer.phase.title : "таймер",
                         tint: ambientTint,
                         expanded: vm.hoveredWing == .right,
                         mono: true,
                         pulses: vm.timer.isFinished)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Раскрытое состояние

    private var expanded: some View {
        VStack(spacing: 0) {
            topStrip
            pane
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Полоса на уровне выреза: слева вкладки, по центру резерв под челку, справа кнопки
    private var topStrip: some View {
        HStack(spacing: 0) {
            TabBar(selection: Binding(
                get: { vm.tab },
                set: { vm.tab = $0 }
            ), badges: [
                .notes: vm.notes.notes.count,
                .tasks: vm.notes.openTaskCount,
                .clipboard: vm.clipboard.items.count,
                .shelf: vm.shelf.items.count
            ])
            .padding(.leading, 12)

            Spacer(minLength: 4)
            Color.clear.frame(width: vm.notchSize.width)   // физический вырез
            Spacer(minLength: 4)

            HStack(spacing: 2) {
                IconButton(icon: vm.isPinnedOpen ? "pin.fill" : "pin",
                           tint: vm.isPinnedOpen ? Theme.Accent.pin : Theme.Ink.secondary,
                           hint: "Закрепить открытой") { vm.isPinnedOpen.toggle() }

                IconButton(icon: "gearshape", hint: "Настройки (⌘,)", action: onSettings)

                IconButton(icon: "xmark", hint: "Закрыть (Esc)", action: onClose)
            }
            .padding(.trailing, 10)
        }
        .frame(height: vm.notchSize.height)
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .notes:     NotesPane(store: vm.notes, selectedID: $vm.selectedNoteID)
        case .tasks:
            TasksPane(store: vm.notes, onReveal: { vm.reveal($0) },
                      autoFocusDraft: vm.isCapturing,
                      onAdded: { if vm.isCapturing { onClose() } })
        case .clipboard: ClipboardPane(store: vm.clipboard)
        case .timer:     TimerPane(timer: vm.timer)
        case .shelf:     ShelfPane(store: vm.shelf, isTargeted: $vm.isDropTargeted)
        }
    }
}

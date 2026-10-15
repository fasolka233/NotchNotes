import SwiftUI
import AppKit

/// Единственный источник правды для цвета, типографики и метрик.
/// Все вью берут значения отсюда — руками `Color.white.opacity(...)` больше не пишем.
enum Theme {

    // MARK: - Поверхности
    //
    // Панель чёрная (продолжение физической челки), поэтому все уровни —
    // белый с прозрачностью. Ровно четыре ступени, между ними заметная разница.

    enum Surface {
        /// Фон карточки/строки в покое
        static let base    = Color.white.opacity(0.05)
        /// То же под курсором
        static let hover   = Color.white.opacity(0.09)
        /// Поля ввода, контейнеры-«таблетки»
        static let field   = Color.white.opacity(0.08)
        /// Выбранная строка, активный чип
        static let active  = Color.white.opacity(0.16)
    }

    enum Stroke {
        /// Волосяная линия по краю панели и разделители
        static let hairline = Color.white.opacity(0.10)
        /// Рамка контейнера, который надо выделить (пустая полка)
        static let outline  = Color.white.opacity(0.16)
    }

    // MARK: - Текст
    //
    // Три уровня, не десять. `primary` — читаемый контент,
    // `secondary` — метаданные, `tertiary` — то, что можно не читать.

    enum Ink {
        static let primary   = Color.white.opacity(0.95)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary  = Color.white.opacity(0.38)
        /// Текст на акцентной заливке
        static let onAccent  = Color.white
    }

    enum Accent {
        static let tint    = Color.accentColor
        static let danger  = Color(red: 1.00, green: 0.42, blue: 0.42)
        static let warning = Color(red: 1.00, green: 0.72, blue: 0.30)
        static let success = Color(red: 0.36, green: 0.86, blue: 0.55)
        static let pin     = Color(red: 1.00, green: 0.82, blue: 0.35)
    }

    // MARK: - Типографика
    //
    // Шкала из пяти шагов, минимум 11pt — ниже macOS HIG читать нельзя.
    // Цифры (таймер, счётчики) — rounded + monospaced, чтобы не «прыгали».

    enum Font {
        static let title    = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body     = SwiftUI.Font.system(size: 12.5)
        static let label    = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption  = SwiftUI.Font.system(size: 11)
        static let badge    = SwiftUI.Font.system(size: 11, weight: .semibold, design: .rounded)

        // Свёрнутая челка — единственное место, где шрифт мельче 11 пт оправдан:
        // это глиф в вырезе на расстоянии вытянутой руки, а не текст для чтения.
        // Ниже 10 пт не опускаемся — цифры перестают опознаваться беглым взглядом.
        static let badgeSmall   = SwiftUI.Font.system(size: 10, weight: .semibold, design: .rounded)
        static let captionSmall = SwiftUI.Font.system(size: 10)

        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
    }

    /// Иконки одного смысла должны быть одного размера во всех панелях.
    enum Icon {
        static let small  = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let medium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let action = SwiftUI.Font.system(size: 13, weight: .medium)
        static let empty  = SwiftUI.Font.system(size: 28, weight: .light)
        /// Чекбокс — один размер везде: и в заметках, и в задачах
        static let check  = SwiftUI.Font.system(size: 13, weight: .regular)
    }

    // MARK: - Метрики

    enum Radius {
        static let row: CGFloat   = 8
        static let card: CGFloat  = 10
        static let panel: CGFloat = 12
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat  = 6
        static let m: CGFloat  = 10
        static let l: CGFloat  = 14
    }

    /// Одна анимация на все состояния наведения/выбора — интерфейс ощущается цельным.
    static var quick: Animation? { motion(.easeOut(duration: 0.13)) }
    static var snap: Animation?  { motion(.spring(response: 0.28, dampingFraction: 0.82)) }

    /// «Уменьшить движение» в Универсальном доступе: состояние меняется сразу,
    /// без пружин. Читаем каждый раз — настройку могут переключить на ходу.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func motion(_ animation: Animation) -> Animation? { reduceMotion ? nil : animation }
}

// MARK: - Общие модификаторы

/// Подсветка строки под курсором + выделение. Раньше строки были мёртвыми на вид.
struct RowHighlight: ViewModifier {
    var isSelected: Bool
    var radius: CGFloat = Theme.Radius.row
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isSelected ? Theme.Surface.active
                : hovering ? Theme.Surface.hover
                : Color.clear,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

/// Карточка со своим фоном (буфер, полка, группы задач) — тот же hover-отклик.
struct CardHighlight: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.Surface.hover : Theme.Surface.base,
                        in: RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

/// Иконочная кнопка: подложка появляется под курсором, поэтому цель клика видна.
struct IconButton: View {
    let icon: String
    var tint: Color = Theme.Ink.secondary
    var hint: String? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.Icon.action)
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.Surface.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(hovering ? Theme.Ink.primary : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help(hint ?? "")
    }
}

/// Чип фильтра. Подпись показываем у активного чипа и под курсором:
/// места в панели мало, а голая иконка без подписи не читается.
/// `alwaysShowTitle` — для рядов, где чипов мало и всё влезает.
struct FilterChip: View {
    let icon: String
    let title: String
    var count: Int? = nil
    let isOn: Bool
    var tint: Color? = nil
    var alwaysShowTitle = false
    let action: () -> Void

    @State private var hovering = false

    private var showTitle: Bool { alwaysShowTitle || isOn || hovering }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if showTitle {
                    Text(title)
                        .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                        .fixedSize()
                }
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isOn ? Theme.Ink.primary : Theme.Ink.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isOn ? Theme.Surface.active
                        : hovering ? Theme.Surface.hover : .clear,
                        in: Capsule())
            .foregroundStyle(tint ?? (isOn ? Theme.Ink.primary : Theme.Ink.secondary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Пустое состояние с действием — раньше был только серый текст без выхода.
struct EmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(Theme.Icon.empty)
                .foregroundStyle(Theme.Ink.tertiary)

            VStack(spacing: 3) {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Ink.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.Surface.field, in: Capsule())
                        .foregroundStyle(Theme.Ink.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// «Удалено «…» · Отменить» внизу панели, ⌘Z. Через 5 секунд прячется сам —
/// `onExpire` вызывается, только если плашку не сменила новая (`token` тот же).
struct UndoToast<Token: Equatable>: View {
    let token: Token
    let title: String
    let onUndo: () -> Void
    let onExpire: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "trash").font(Theme.Icon.small)
            Text("Удалено «\(title)»")
                .font(Theme.Font.caption)
                .lineLimit(1)
            Button("Отменить", action: onUndo)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Accent.tint)
                .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color(white: 0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        .padding(.bottom, 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: token) {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { onExpire() }
        }
    }
}

/// Поле поиска/ввода одного вида во всех панелях.
struct SearchField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var icon: String = "magnifyingglass"
    var onSubmit: (() -> Void)? = nil
    /// Чтобы ⌘F / ⌘N могли поставить курсор в поле
    var focus: FocusState<Bool>.Binding? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(Theme.Icon.small)
                .foregroundStyle(Theme.Ink.tertiary)

            if let focus {
                field.focused(focus)
            } else {
                field
            }

            trailing()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(Theme.Surface.field, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.hairline, lineWidth: 1))
    }

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Ink.primary)
            .onSubmit { onSubmit?() }
    }
}

extension SearchField where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>,
         icon: String = "magnifyingglass", onSubmit: (() -> Void)? = nil,
         focus: FocusState<Bool>.Binding? = nil) {
        self.init(placeholder: placeholder, text: text,
                  icon: icon, onSubmit: onSubmit, focus: focus) { EmptyView() }
    }
}

extension View {
    func rowHighlight(selected: Bool, radius: CGFloat = Theme.Radius.row) -> some View {
        modifier(RowHighlight(isSelected: selected, radius: radius))
    }

    func cardHighlight(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardHighlight(radius: radius))
    }
}

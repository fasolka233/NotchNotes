import SwiftUI
import Combine

enum NotchTab: String, CaseIterable, Identifiable {
    case notes, tasks, clipboard, timer, shelf

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .notes:     return "note.text"
        case .tasks:     return "checklist"
        case .clipboard: return "doc.on.clipboard"
        case .timer:     return "timer"
        case .shelf:     return "tray.full"
        }
    }

    var title: String {
        switch self {
        case .notes:     return "Заметки"
        case .tasks:     return "Задачи"
        case .clipboard: return "Буфер"
        case .timer:     return "Таймер"
        case .shelf:     return "Файлы"
        }
    }
}

/// Клавиши раскрытой панели. Ловит `NotchController` (монитор keyDown),
/// обрабатывает панель текущей вкладки — она же говорит, съела ли нажатие.
enum KeyCommand {
    case find, new, up, down, open, toggle

    /// ponytail: по обработчику на вкладку, глобально — панель в приложении одна
    static var handlers: [NotchTab: (KeyCommand) -> Bool] = [:]
}

final class NotchViewModel: ObservableObject {

    @Published var isOpen = false
    @Published var isPinnedOpen = false
    @Published var isDropTargeted = false
    /// Файл поднесли к челке — показываем крупную мишень для броска
    @Published var isSystemDragging = false
    /// Сколько файлов в текущем переносе — уточняем подсказку («Отпустите — 3 файла»)
    @Published var dragItemCount = 0
    /// Короткое подтверждение после броска вместо раскрытия панели
    @Published var droppedCount = 0
    @Published var tab: NotchTab = .notes
    @Published var notchSize = CGSize(width: 220, height: 32)
    /// Общая для «Заметок» и «Задач»: из задачи можно прыгнуть в её заметку
    @Published var selectedNoteID: Note.ID?
    /// Панель открыта быстрой записью: после Enter она сама свернётся
    @Published var isCapturing = false

    let notes = NotesStore()
    let clipboard = ClipboardStore()
    let timer = TimerModel()
    let shelf = ShelfStore()
    let reminders: ReminderCenter

    /// Раскрытая плашка. Ширина считана от содержимого: 248 колонка списка +
    /// редактор, где в одну строку должны уместиться цвета, срок и напоминание.
    let contentSize = CGSize(width: 780, height: 380)

    private var bag = Set<AnyCancellable>()

    init() {
        reminders = ReminderCenter(store: notes)

        // прокидываем изменения вложенных стораджей во вью
        for obj in [notes.objectWillChange.eraseToAnyPublisher(),
                    clipboard.objectWillChange.eraseToAnyPublisher(),
                    timer.objectWillChange.eraseToAnyPublisher(),
                    shelf.objectWillChange.eraseToAnyPublisher(),
                    reminders.objectWillChange.eraseToAnyPublisher()] {
            obj.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    /// Что показывать на свёрнутой челке, кроме таймера
    var hasAlert: Bool { notes.overdueCount > 0 }

    // MARK: - Свёрнутые мини-состояния
    //
    // Свёрнутая челка — это два независимых «крыла» по бокам от выреза.
    // Левое отвечает на «что у меня накопилось», правое — на «что идёт прямо
    // сейчас». В каждом крыле показываем РОВНО ОДИН значок: два значка в 60 пт
    // не читаются с расстояния, а челка перестаёт быть челкой.

    /// Крыло, на которое сейчас наведён курсор — оно раскрывается подписью
    @Published var hoveredWing: Wing?
    /// Короткая вспышка справа: скопировали в буфер / закрыли задачу
    @Published var flash: Flash?

    enum Wing { case left, right }

    enum Flash: Equatable {
        case copied          // поймали новую запись в буфере
        case taskDone(Int)   // закрыли задачу, осталось n
    }

    /// Левое крыло: накопленное. Просрочка важнее общего числа задач —
    /// она требует действия, а счётчик задач только информирует.
    enum LeftBadge: Equatable {
        case overdue(Int)
        case tasks(Int)
    }

    var leftBadge: LeftBadge? {
        if notes.overdueCount > 0 { return .overdue(notes.overdueCount) }
        if notes.openTaskCount > 0 { return .tasks(notes.openTaskCount) }
        return nil
    }

    /// Правое крыло: происходящее сейчас. Вспышка перебивает таймер на секунду —
    /// она короткая и подтверждает только что сделанное действие.
    enum RightBadge: Equatable {
        case flash(Flash)
        case timer
    }

    var rightBadge: RightBadge? {
        if let flash { return .flash(flash) }
        if timer.isAmbient { return .timer }
        return nil
    }

    private var flashWork: DispatchWorkItem?

    /// Показать вспышку в правом крыле и убрать её через 1.6 с
    func showFlash(_ f: Flash) {
        flashWork?.cancel()
        withAnimation(Theme.motion(.spring(response: 0.26, dampingFraction: 0.8))) { flash = f }

        let work = DispatchWorkItem { [weak self] in
            withAnimation(Theme.motion(.easeOut(duration: 0.22))) { self?.flash = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Вкладка, которую открывает клик по крылу
    func tab(for wing: Wing) -> NotchTab {
        switch wing {
        case .left:  return .tasks
        case .right:
            if case .flash(.copied) = rightBadge { return .clipboard }
            return timer.isAmbient ? .timer : .notes
        }
    }

    /// Сколько места просит содержимое крыла. 0 — крыла нет.
    ///
    /// Ширину считаем ОТ СОДЕРЖИМОГО, а не берём из таблицы констант: подпись
    /// со вспышкой («скопировано») показывается всегда развёрнутой, и при
    /// фиксированных 38 пт её резало посреди буквы. Значение и подпись меряем
    /// теми же шрифтами, которыми рисуем, — тогда крыло всегда ровно по тексту.
    private func wingContentWidth(_ wing: Wing) -> CGFloat {
        switch wing {
        case .left:
            guard let badge = leftBadge else { return 0 }
            switch badge {
            case .overdue(let n):
                return wingWidth(value: "\(n)", label: "просрочено",
                                 showLabel: hoveredWing == .left)
            case .tasks(let n):
                return wingWidth(value: "\(n)", label: n == 1 ? "задача" : "в работе",
                                 showLabel: hoveredWing == .left)
            }
        case .right:
            guard let badge = rightBadge else { return 0 }
            switch badge {
            case .flash(.copied):
                // вспышка сама себе подпись — она и есть всё сообщение
                return wingWidth(value: "", label: "скопировано", showLabel: true)
            case .flash(.taskDone(let left)):
                return wingWidth(value: left > 0 ? "\(left)" : "",
                                 label: left > 0 ? "осталось" : "всё готово",
                                 showLabel: true)
            case .timer:
                return wingWidth(value: timer.formatted,
                                 label: timer.pomodoroEnabled ? timer.phase.title : "таймер",
                                 showLabel: hoveredWing == .right,
                                 mono: true)
            }
        }
    }

    /// Ширина значка = зазоры + фактическая ширина строк.
    ///
    /// Раскладка обязана совпасть с `AmbientBadge`, иначе или обрежется текст,
    /// или крыло раздуется пустотой. Меняешь одно — правь второе.
    /// Иконки в значке больше нет, поэтому её ширина здесь не закладывается —
    /// зазор считаем только МЕЖДУ строками, а не перед первой.
    private func wingWidth(value: String, label: String,
                           showLabel: Bool, mono: Bool = false) -> CGFloat {
        var w = Self.wingInnerPadding
        var parts = 0
        if !value.isEmpty {
            w += textWidth(value, font: mono ? Self.monoValueFont : Self.valueFont)
            parts += 1
        }
        if showLabel && !label.isEmpty {
            if parts > 0 { w += Self.badgeSpacing }
            w += textWidth(label, font: Self.labelFont)
            parts += 1
        }
        // Крыло без строк — это отсутствующее крыло, а не полоска из отступов.
        guard parts > 0 else { return 0 }
        // Крылья симметричны и множатся на два — не даём одному значку
        // растянуть челку на пол-экрана. Подпись длиннее просто не влезает.
        return min(w.rounded(.up), showLabel ? maxExpandedWingWidth : maxWingWidth)
    }

    /// Ширина строки в пунктах. NSAttributedString меряет ровно то, что нарисует
    /// AppKit под SwiftUI, поэтому округления вверх на 1 пт достаточно.
    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    // Шрифты-двойники того, что рисует `AmbientBadge`. `Theme.Font` возвращает
    // SwiftUI.Font, которую нельзя измерить, поэтому здесь их AppKit-аналоги.
    private static let valueFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let monoValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    /// Зазор между значением и подписью в `AmbientBadge`
    private static let badgeSpacing: CGFloat = 4
    /// Отступ крыла от выреза + воздух у внешнего края
    static let wingInnerPadding: CGFloat = 8 + 6

    /// Ширина, которую занимает КАЖДОЕ крыло в раскладке.
    ///
    /// Окно центрировано по физическому вырезу, поэтому оба крыла всегда одной
    /// ширины: если пустое крыло схлопнуть в ноль, содержимое HStack станет уже
    /// окна, и SwiftUI сдвинет резерв под вырез вбок — нарисованная челка уедет
    /// от настоящей. Пустое крыло остаётся пустым местом, а не исчезает.
    var wingWidth: CGFloat {
        max(wingContentWidth(.left), wingContentWidth(.right))
    }

    /// Есть ли в крыле значок — пустое крыло не реагирует на курсор и клик
    func hasBadge(_ wing: Wing) -> Bool { wingContentWidth(wing) > 0 }

    /// Свёрнутый размер: расширяем челку, если идёт таймер или тянут файл.
    ///
    /// Высота НИКОГДА не превышает физический вырез: всё, что ниже
    /// `notchSize.height`, выезжает из-под челки на обои и читается как
    /// отдельная чёрная плашка, а не как часть выреза.
    var collapsedSize: CGSize {
        // мишень расширяется только вбок и умеренно: вырез ~179 пт, поэтому
        // «крыльев» по 60 пт хватает, чтобы прицелиться, и силуэт челки остаётся.
        if isSystemDragging || isDropTargeted {
            return CGSize(width: notchSize.width + 2 * dropWingWidth,
                          height: notchSize.height)
        }
        // подтверждение броска: та же высота, крыло поуже — размер не мельтешит
        if droppedCount > 0 {
            return CGSize(width: notchSize.width + 2 * confirmWingWidth,
                          height: notchSize.height)
        }
        // ambient: вырез + два симметричных крыла. Симметрия обязательна —
        // окно центрируется по вырезу, и разной ширины крылья сдвинули бы
        // нарисованную челку относительно физической.
        return CGSize(width: notchSize.width + 2 * wingWidth, height: notchSize.height)
    }

    /// Насколько мишень выступает за вырез с каждой стороны
    let dropWingWidth: CGFloat = 60
    let confirmWingWidth: CGFloat = 52

    // Крылья симметричны, поэтому каждый лишний пункт множится на два и панель
    // быстро перестаёт читаться как челка. Ширину задаёт содержимое, но сверху
    // стоит потолок: значок должен выглядеть каймой вокруг выреза, а не
    // отдельной плашкой рядом с ним.

    /// Потолок крыла. Подпись длиннее гасится многоточием — лучше
    /// «скопирова…», чем челка во весь экран.
    ///
    /// Потолка два. Пассивное крыло висит на экране постоянно, поэтому оно
    /// узкое: это кайма вокруг выреза. Раскрытое (наведение или вспышка) живёт
    /// секунду и по прямому намерению пользователя — ему можно дать место под
    /// целое слово, иначе «просрочено» и названия фаз помидора обрезаются.
    /// Пассивный потолок держит часовой таймер («1:00:00») целиком: значение —
    /// это весь смысл значка, обрезать его нельзя никогда.
    let maxWingWidth: CGFloat = 86
    let maxExpandedWingWidth: CGFloat = 124

    /// Размер окна (с запасом под «ушки» и тень)
    var windowSize: CGSize {
        isOpen
        ? CGSize(width: contentSize.width + 44, height: contentSize.height + 30)
        : CGSize(width: collapsedSize.width + 30, height: collapsedSize.height + 16)
    }

    func select(_ newTab: NotchTab) {
        withAnimation(Theme.motion(.spring(response: 0.28, dampingFraction: 0.85))) { tab = newTab }
    }

    /// Открыть заметку во вкладке «Заметки» — из списка задач или напоминания
    func reveal(_ id: Note.ID) {
        selectedNoteID = id
        select(.notes)
    }
}

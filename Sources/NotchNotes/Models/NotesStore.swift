import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers

/// Быстрые срезы списка заметок
enum NoteFilter: String, CaseIterable, Identifiable {
    case all, tasks, today, overdue, pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:     return "Все"
        case .tasks:   return "Задачи"
        case .today:   return "Сегодня"
        case .overdue: return "Просрочено"
        case .pinned:  return "Закреплённые"
        }
    }

    var icon: String {
        switch self {
        case .all:     return "tray.full"
        case .tasks:   return "checklist"
        case .today:   return "sun.max"
        case .overdue: return "exclamationmark.triangle"
        case .pinned:  return "pin"
        }
    }
}

/// Срезы вкладки «Задачи» — считаются по задачам, а не по заметкам
enum TaskScope: String, CaseIterable, Identifiable {
    case open, today, overdue, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:    return "Открытые"
        case .today:   return "Сегодня"
        case .overdue: return "Просрочено"
        case .done:    return "Сделано"
        }
    }

    var icon: String {
        switch self {
        case .open:    return "circle"
        case .today:   return "sun.max"
        case .overdue: return "exclamationmark.triangle"
        case .done:    return "checkmark.circle"
        }
    }
}

/// Задача вместе с заметкой, в которой живёт, и всеми своими подзадачами
struct TaskEntry: Identifiable {
    let note: Note
    let item: ChecklistItem
    var children: [ChecklistItem] = []
    var id: String { "\(note.id)-\(item.line)" }

    private var open: [ChecklistItem] { ([item] + children).filter { !$0.isDone } }

    /// Горит сама задача или любая её открытая подзадача
    var isOverdue: Bool { open.contains(where: \.isOverdue) }
    /// Ближайший срок по открытым пунктам
    var nextDue: Date? { open.compactMap(\.due).min() }
    var progress: (done: Int, total: Int) { (children.filter(\.isDone).count, children.count) }
}

final class NotesStore: ObservableObject {

    @Published var notes: [Note] = []

    private var bag = Set<AnyCancellable>()
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("notes.json")

        load()

        // автосохранение с дебаунсом
        $notes
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] notes in self?.save(notes) }
            .store(in: &bag)
    }

    // MARK: - Выборки

    /// Закреплённые сверху, дальше по сроку и дате изменения
    func filtered(_ query: String, filter: NoteFilter = .all, tag: String? = nil) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let base = notes.filter { note in
            if !q.isEmpty, !note.text.lowercased().contains(q) { return false }
            if let tag, !note.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            switch filter {
            case .all:     return true
            case .tasks:   return note.todo.total > 0
            case .today:   return note.isDueToday || note.isOverdue
            case .overdue: return note.isOverdue
            case .pinned:  return note.isPinned
            }
        }

        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.updatedAt > b.updatedAt
            }
        }
    }

    func count(for filter: NoteFilter) -> Int {
        filtered("", filter: filter).count
    }

    /// Все метки по убыванию частоты — для быстрых фильтров
    var allTags: [String] {
        var freq: [String: (name: String, n: Int)] = [:]
        for note in notes {
            for tag in note.tags {
                let key = tag.lowercased()
                freq[key] = (freq[key]?.name ?? tag, (freq[key]?.n ?? 0) + 1)
            }
        }
        return freq.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.map(\.name)
    }

    /// Незакрытые задачи по всем заметкам — сводка для вкладки «Задачи»
    var openTaskCount: Int {
        notes.reduce(0) { $0 + $1.openTasks.count }
    }

    var overdueCount: Int { notes.filter(\.isOverdue).count }

    // MARK: - Учёт поручений

    /// Задачи верхнего уровня с подзадачами. Задача попадает в срез, если подходит
    /// она сама или любая её подзадача. Открытые: просроченные → по сроку → без срока,
    /// внутри — по приоритету. Сделанные: свежие сверху, без даты сдачи — в конце.
    func tasks(_ scope: TaskScope, kind: TaskKind? = nil,
               from: String? = nil, query: String = "") -> [TaskEntry] {
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30,
                                             to: Calendar.current.startOfDay(for: Date()))!
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        let fits: (ChecklistItem) -> Bool = { t in
            switch scope {
            case .open:    return !t.isDone
            case .today:   return !t.isDone && (t.isDueToday || t.isOverdue)
            case .overdue: return t.isOverdue
            case .done:    return t.isDone && (t.doneAt.map { $0 >= monthAgo } ?? true)
            }
        }

        let picked = taskTree().filter { e in
            let all = [e.item] + e.children
            if let kind, e.item.kind != kind { return false }
            if let from, !all.contains(where: { $0.from?.caseInsensitiveCompare(from) == .orderedSame }) {
                return false
            }
            if !q.isEmpty, !e.note.title.lowercased().contains(q),
               !all.contains(where: { ($0.text + " " + ($0.from ?? "")).lowercased().contains(q) }) {
                return false
            }
            // сделанное считаем по самой задаче: открытая подзадача её не «раскрывает»
            return scope == .done ? fits(e.item) : all.contains(where: fits)
        }

        if scope == .done {
            return picked.sorted { ($0.item.doneAt ?? .distantPast) > ($1.item.doneAt ?? .distantPast) }
        }
        return picked.sorted { a, b in
            if a.isOverdue != b.isOverdue { return a.isOverdue }
            switch (a.nextDue, b.nextDue) {
            case let (p?, q?) where p != q: return p < q
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.item.priority.rank < b.item.priority.rank
            }
        }
    }

    /// Все задачи верхнего уровня; подзадачи собраны под своим корнем
    private func taskTree() -> [TaskEntry] {
        notes.flatMap { note -> [TaskEntry] in
            var out: [TaskEntry] = []
            for item in note.checklist {
                if item.parent == nil || out.isEmpty {
                    out.append(TaskEntry(note: note, item: item))
                } else {
                    out[out.count - 1].children.append(item)
                }
            }
            return out
        }
    }

    /// Все пункты плоско — для экспорта
    var allTaskItems: [TaskEntry] {
        notes.flatMap { n in n.checklist.map { TaskEntry(note: n, item: $0) } }
    }

    /// «Активных 5 · просрочено 1 · сдано за неделю 7 · в срок 86%»
    func taskSummary(kind: TaskKind? = nil, from: String? = nil) -> String {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -6,
                                            to: Calendar.current.startOfDay(for: Date()))!
        let open = tasks(.open, kind: kind, from: from)
        let week = tasks(.done, kind: kind, from: from).filter { ($0.item.doneAt ?? .distantPast) >= weekAgo }
        var parts = ["Активных \(open.count)",
                     "просрочено \(open.filter(\.isOverdue).count)",
                     "сдано за неделю \(week.count)"]
        let timed = week.filter { $0.item.due != nil }
        if !timed.isEmpty {
            let onTime = timed.filter { !$0.item.isLate }.count
            parts.append("в срок \(Int((Double(onTime) / Double(timed.count) * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// Имена из `@` по частоте — для фильтра и подсказок при вводе
    var taskAuthors: [String] {
        var freq: [String: (name: String, n: Int)] = [:]
        for note in notes {
            for name in note.checklist.compactMap(\.from) {
                let key = name.lowercased()
                freq[key] = (freq[key]?.name ?? name, (freq[key]?.n ?? 0) + 1)
            }
        }
        return freq.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }.map(\.name)
    }

    // MARK: - Мутации

    @discardableResult
    func addNote(_ text: String = "", color: NoteColor = .none) -> Note {
        let note = Note(text: text, color: color)
        notes.insert(note, at: 0)
        return note
    }

    func text(for id: Note.ID) -> String {
        notes.first(where: { $0.id == id })?.text ?? ""
    }

    func note(_ id: Note.ID) -> Note? { notes.first(where: { $0.id == id }) }

    func setText(_ newText: String, for id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].text != newText else { return }
        notes[i].text = newText
        notes[i].updatedAt = Date()
    }

    func togglePin(_ id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isPinned.toggle()
    }

    func setColor(_ color: NoteColor, for id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = color
    }

    func setDue(_ date: Date?, for id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].dueDate = date.map { Calendar.current.startOfDay(for: $0) }
    }

    func setReminder(_ date: Date?, for id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].reminderAt = date
    }

    /// Удалить заметку; вернуть можно через `undoRemove()`
    func delete(_ id: Note.ID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes.remove(at: i)
        lastRemoved = Removed(title: note.title, what: .note(note, at: i))
    }

    @discardableResult
    func duplicate(_ id: Note.ID) -> Note? {
        guard let src = notes.first(where: { $0.id == id }) else { return nil }
        return addNote(src.text, color: src.color)
    }

    // MARK: - Задачи внутри текста

    /// Переключить чекбокс на конкретной строке. Сделано — дописываем `✅ сегодня`,
    /// сняли отметку — убираем дату сдачи. У повторяющейся задачи над сданной
    /// появляется следующая — как в Obsidian Tasks, подзадачи остаются у сданной.
    func toggleItem(line: Int, in id: Note.ID, today: Date = Date()) {
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            let l = lines[line]
            if let r = l.range(of: "[ ]") {
                lines[line] = Self.stripDone(l.replacingCharacters(in: r, with: "[x]"))
                    + " ✅ " + Note.isoDay.string(from: today)
                if let s = ChecklistItem.split(l),
                   let next = Self.nextOccurrence(TaskFields(parsing: s.body), today: today) {
                    lines.insert(s.prefix + next.line, at: line)
                }
            } else if let r = l.range(of: "[x]") ?? l.range(of: "[X]") {
                lines[line] = Self.stripDone(l.replacingCharacters(in: r, with: "[ ]"))
            } else {
                return false
            }
            return true
        }
    }

    /// Следующий экземпляр повторяющейся задачи. Срок считаем от прежнего срока
    /// (или от сегодня, если его не было) и не оставляем в прошлом:
    /// пропущенную ежедневную задачу незачем сразу заводить просроченной.
    static func nextOccurrence(_ f: TaskFields, today: Date) -> TaskFields? {
        guard let recur = f.recur else { return nil }
        let start = Calendar.current.startOfDay(for: today)
        var due = recur.next(after: f.due ?? start)
        while due < start { due = recur.next(after: due) }
        var next = f
        next.created = start
        next.due = due
        next.done = nil
        return next
    }

    private static func stripDone(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s*✅\x{FE0F}?\s+\d{4}-\d{2}-\d{2}"#, with: "",
                                  options: .regularExpression)
    }

    /// Подзадача — та же строка markdown, но с отступом на два пробела глубже.
    /// Встаёт в конец уже существующих подзадач, текст разбирается как быстрый ввод.
    func addSubtask(after line: Int, in id: Note.ID, text: String = "") {
        let body = text.isEmpty ? "" : Self.normalizeTask(text)
        guard text.isEmpty || !body.isEmpty else { return }
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            let indent = String(lines[line].prefix { $0 == " " || $0 == "\t" })
            lines.insert(indent + "  - [ ] " + body, at: Self.blockEnd(lines, line) + 1)
            return true
        }
    }

    func removeItem(line: Int, in id: Note.ID) {
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            lines.remove(at: line)
            return true
        }
    }

    /// Последнее удалённое — заметка целиком или задача с подзадачами — для «Отменить»
    struct Removed: Equatable {
        enum What: Equatable {
            case lines(note: Note.ID, at: Int, [String])
            case note(Note, at: Int)
        }
        let title: String
        let what: What
    }

    @Published var lastRemoved: Removed?

    /// Удалить задачу вместе с подзадачами; вернуть можно через `undoRemove()`
    func removeTask(line: Int, in id: Note.ID) {
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            let range = line...Self.blockEnd(lines, line)
            let title = ChecklistItem.split(lines[line]).map { TaskFields(parsing: $0.body).text } ?? ""
            lastRemoved = Removed(title: title, what: .lines(note: id, at: line, Array(lines[range])))
            lines.removeSubrange(range)
            return true
        }
    }

    /// Вернуть последнее удалённое. Возвращает заметку, в которую оно вернулось.
    @discardableResult
    func undoRemove() -> Note.ID? {
        guard let r = lastRemoved else { return nil }
        lastRemoved = nil
        switch r.what {
        case let .lines(id, at, removed):
            editLines(id) { lines in
                lines.insert(contentsOf: removed, at: min(at, lines.count))
                return true
            }
            return id
        case let .note(note, at):
            guard !notes.contains(where: { $0.id == note.id }) else { return note.id }
            notes.insert(note, at: min(at, notes.count))
            return note.id
        }
    }

    /// Поменять поля задачи и собрать строку заново — отступ и галочка сохраняются
    func updateTask(line: Int, in id: Note.ID, _ change: (inout TaskFields) -> Void) {
        editLines(id) { lines in
            guard lines.indices.contains(line), let s = ChecklistItem.split(lines[line]) else { return false }
            var f = TaskFields(parsing: s.body)
            let before = f
            change(&f)
            f.from = f.from?.split(whereSeparator: \.isWhitespace).joined(separator: "_")
            if f.from?.isEmpty == true { f.from = nil }
            guard f != before else { return false }
            lines[line] = s.prefix + f.line
            return true
        }
    }

    /// Перенести срок на `days` дней. Просроченное — считаем от сегодня,
    /// иначе «+1 день» оставил бы задачу просроченной.
    func shiftDue(line: Int, in id: Note.ID, days: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        let item = note(id)?.checklist.first { $0.line == line }
        let base = max(item?.due ?? today, today)
        updateTask(line: line, in: id) {
            $0.due = Calendar.current.date(byAdding: .day, value: days, to: base)
        }
    }

    /// Последняя строка блока: сама строка и всё, что под ней с отступом глубже
    private static func blockEnd(_ lines: [String], _ line: Int) -> Int {
        let width = { (l: String) in l.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }
        let base = width(lines[line])
        var end = line
        while end + 1 < lines.count,
              !lines[end + 1].trimmingCharacters(in: .whitespaces).isEmpty,
              width(lines[end + 1]) > base {
            end += 1
        }
        return end
    }

    /// Добавить задачу в конец заметки. Метки из быстрого ввода приводятся
    /// к виду Obsidian Tasks, дата получения `➕` проставляется сама.
    func addTask(_ text: String, to id: Note.ID) {
        let line = Self.normalizeTask(text)
        guard !line.isEmpty else { return }
        let current = self.text(for: id)
        let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        setText(current + prefix + "- [ ] " + line, for: id)
    }

    /// `Отчёт #осн @руководитель 📅 20.10 !пт` → `Отчёт #осн @руководитель ➕ 2026-10-15 📅 2026-10-17`.
    /// Короткие сроки: `📅 20.10`, `📅 20.10.2026`, `!сегодня`, `!завтра`, `!пн`…`!вс`, `!20.10`.
    /// Повтор: `!ежедневно`, `!еженедельно`, `!ежемесячно`, `!ежегодно` → `🔁 every week`.
    /// Поля с эмодзи уходят в конец — так их читает плагин Obsidian Tasks.
    static func normalizeTask(_ raw: String, today: Date = Date()) -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return "" }

        // короткие сроки → 📅 ГГГГ-ММ-ДД, прямо на месте
        var i = 0
        while i < tokens.count {
            if tokens[i].hasPrefix("!"), let d = shortDate(String(tokens[i].dropFirst()), from: start) {
                tokens[i...i] = ["📅", Note.isoDay.string(from: d)]
            } else if tokens[i].hasPrefix("!"), let r = Recurrence(russian: String(tokens[i].dropFirst())) {
                tokens[i...i] = ["🔁"] + r.text.split(separator: " ").map(String.init)
            } else if tokens[i] == "📅", i + 1 < tokens.count,
                      Note.isoDay.date(from: tokens[i + 1]) == nil,
                      let d = shortDate(tokens[i + 1], from: start) {
                tokens[i + 1] = Note.isoDay.string(from: d)
            }
            i += 1
        }

        var f = TaskFields(parsing: tokens.joined(separator: " "))
        guard !f.text.isEmpty else { return "" }
        f.created = f.created ?? start
        return f.line
    }

    /// `завтра`, `пт`, `20.10`, `20.10.2026` → день. Дата без года, которая
    /// в этом году уже прошла, — это следующий год.
    private static func shortDate(_ s: String, from start: Date) -> Date? {
        let cal = Calendar.current
        let words = ["сегодня": 0, "завтра": 1, "послезавтра": 2]
        if let shift = words[s.lowercased()] { return cal.date(byAdding: .day, value: shift, to: start) }

        // ближайший такой день недели, сегодня включительно
        let weekdays = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
        if let wd = weekdays.firstIndex(of: s.lowercased()) {
            let delta = (wd + 1 - cal.component(.weekday, from: start) + 7) % 7
            return cal.date(byAdding: .day, value: delta, to: start)
        }

        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3,
              s.split(separator: ".").count == parts.count else { return nil }
        var c = DateComponents(year: parts.count == 3 ? parts[2] : cal.component(.year, from: start),
                               month: parts[1], day: parts[0])
        if let y = c.year, y < 100 { c.year = 2000 + y }
        guard let d = cal.date(from: c), cal.component(.day, from: d) == parts[0],
              cal.component(.month, from: d) == parts[1] else { return nil }
        if parts.count == 2, d < start { return cal.date(byAdding: .year, value: 1, to: d) }
        return d
    }

    /// Заметка-инбокс для быстрых задач без разбора, куда их класть
    @discardableResult
    func inbox() -> Note {
        if let existing = notes.first(where: { $0.title == "Входящие" }) { return existing }
        var note = Note(text: "Входящие", color: .blue)
        note.isPinned = true
        notes.insert(note, at: 0)
        return note
    }

    private func editLines(_ id: Note.ID, _ transform: (inout [String]) -> Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var lines = notes[i].text.components(separatedBy: "\n")
        guard transform(&lines) else { return }
        notes[i].text = lines.joined(separator: "\n")
        notes[i].updatedAt = Date()
    }

    // MARK: - Наружу

    func share(_ id: Note.ID) {
        let text = text(for: id)
        guard !text.isEmpty else { return }
        SharePresenter.shared.share([text])
    }

    /// Сохранить заметку как .md — чтобы отдать в Obsidian, репозиторий или преподу
    func exportMarkdown(_ id: Note.ID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeFileName(note.title) + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? note.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Все задачи в CSV для Excel: `;`, UTF-8 с BOM, даты `ДД.ММ.ГГГГ` —
    /// русский Excel открывает двойным кликом и сам распознаёт даты.
    func exportTasksCSV() {
        let csv = Self.tasksCSV(allTaskItems)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Задачи " + Note.isoDay.string(from: Date()) + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, options: .atomic)
        }
    }

    static func tasksCSV(_ entries: [TaskEntry]) -> Data {
        let day: (Date?) -> String = { $0.map { csvDay.string(from: $0) } ?? "" }
        let sorted = entries.sorted { ($0.item.createdAt ?? .distantPast) < ($1.item.createdAt ?? .distantPast) }

        var rows = [["Получено", "Задача", "Тип", "От кого", "Приоритет", "Срок", "Статус", "Сдано", "Заметка"]]
        for e in sorted {
            let t = e.item
            let status = t.isDone ? (t.isLate ? "сдано с опозданием" : "сдано")
                       : t.isOverdue ? "просрочено" : "в работе"
            rows.append([day(t.createdAt), t.text, t.kind.title, t.from ?? "", t.priority.title,
                         day(t.due), status, day(t.doneAt), e.note.title])
        }
        let body = rows.map { $0.map(csvField).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
    }

    private static let csvDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// Кавычки — если внутри разделитель/перевод строки; апостроф перед `= + - @`,
    /// чтобы Excel не принял текст задачи за формулу.
    private static func csvField(_ raw: String) -> String {
        var s = raw
        if let c = s.first, "=+-@".contains(c) { s = "'" + s }
        guard s.contains(where: { ";\"\n\r".contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func safeFileName(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Заметка" : String(cleaned.prefix(60))
    }

    // MARK: - Диск

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: data)
        } catch {
            // Нечитаемый файл нельзя молча затереть пустым списком при первом
            // же сохранении — откладываем его в сторону, его ещё можно спасти.
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("notes.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("[NotchNotes] notes.json не прочитан (\(error)), отложен в \(aside.lastPathComponent)")
        }
    }

    private func save(_ notes: [Note]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        backupIfNeeded()
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Резервные копии

    var backupDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    /// Раз в день, перед первой записью, — копия того, что было на диске.
    /// Храним неделю: хватает, чтобы откатить неудачную правку или случайное удаление.
    private func backupIfNeeded() {
        let fm = FileManager.default
        let today = backupDirectory.appendingPathComponent("notes-\(Note.isoDay.string(from: Date())).json")
        guard fm.fileExists(atPath: fileURL.path), !fm.fileExists(atPath: today.path) else { return }
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try? fm.copyItem(at: fileURL, to: today)
        let names = (try? fm.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        for name in Self.expiredBackups(names) {
            try? fm.removeItem(at: backupDirectory.appendingPathComponent(name))
        }
    }

    /// Ежедневные копии сверх `keep` самых свежих. Имена `notes-ГГГГ-ММ-ДД.json`
    /// сортируются по алфавиту ровно как по дате.
    static func expiredBackups(_ names: [String], keep: Int = 7) -> [String] {
        let daily = names.filter { $0.hasPrefix("notes-") && $0.hasSuffix(".json") }.sorted(by: >)
        return Array(daily.dropFirst(keep))
    }

    /// Заменить заметки копией. Текущие сначала откладываем рядом —
    /// восстановление тоже должно быть обратимым.
    @discardableResult
    func restore(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Note].self, from: data) else { return false }
        if let current = try? JSONEncoder().encode(notes) {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            try? current.write(to: backupDirectory.appendingPathComponent("before-restore-\(stamp).json"))
        }
        notes = decoded
        return true
    }
}

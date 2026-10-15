import Foundation
import SwiftUI

/// Цветная метка заметки: быстрый визуальный разбор «учёба / работа / срочное»
enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .none:   return .white.opacity(0.3)
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        case .gray:   return .gray
        }
    }

    var title: String {
        switch self {
        case .none:   return "Без цвета"
        case .red:    return "Срочное"
        case .orange: return "Важное"
        case .yellow: return "Ждёт"
        case .green:  return "Готово"
        case .blue:   return "Работа"
        case .purple: return "Учёба"
        case .gray:   return "Архив"
        }
    }
}

/// Тип поручения: `#осн` / `#доп`, без метки — «прочее»
enum TaskKind: String, CaseIterable, Identifiable {
    case main, extra, other

    var id: String { rawValue }

    var tag: String? {
        switch self {
        case .main:  return "#осн"
        case .extra: return "#доп"
        case .other: return nil
        }
    }

    var title: String {
        switch self {
        case .main:  return "Основная"
        case .extra: return "Дополнительная"
        case .other: return "Прочее"
        }
    }
}

/// Приоритет в нотации Obsidian Tasks. `rank` — для сортировки: меньше = важнее.
enum TaskPriority: String, CaseIterable {
    case high = "⏫", medium = "🔼", low = "🔽", none = ""

    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .none: return 2
        case .low: return 3
        }
    }

    var title: String {
        switch self {
        case .high: return "высокий"
        case .medium: return "средний"
        case .low: return "низкий"
        case .none: return ""
        }
    }
}

/// Поля задачи из строки markdown. `line` собирает их обратно —
/// название, потом метки в порядке, который читает плагин Obsidian Tasks.
struct TaskFields: Hashable {
    var text = ""                       // название без служебных меток
    var kind = TaskKind.other
    var from: String?                   // от кого поручение, без «@»
    var priority = TaskPriority.none
    var created: Date?                  // ➕
    var due: Date?                      // 📅 — только свой, без срока заметки
    var done: Date?                     // ✅

    var line: String {
        var out = [text]
        if let tag = kind.tag { out.append(tag) }
        if let from, !from.isEmpty { out.append("@" + from) }
        if priority != .none { out.append(priority.rawValue) }
        if let created { out.append("➕ " + Note.isoDay.string(from: created)) }
        if let due { out.append("📅 " + Note.isoDay.string(from: due)) }
        if let done { out.append("✅ " + Note.isoDay.string(from: done)) }
        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Разбор хвоста строки после `- [ ]`. Нераспознанное остаётся в названии,
    /// поэтому строки без меток выглядят как раньше.
    init(parsing body: String) {
        var kept: [Substring] = []
        let tokens = body.split(whereSeparator: \.isWhitespace)
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            // ✅ и ✅︎ — один и тот же значок, вариационный селектор не в счёт
            let bare = tok.unicodeScalars.filter { $0 != "\u{FE0F}" }.map(String.init).joined()
            let next = i + 1 < tokens.count ? Note.isoDay.date(from: String(tokens[i + 1])) : nil

            switch bare {
            case "➕" where next != nil: created = next; i += 2; continue
            case "📅" where next != nil: due = next; i += 2; continue
            case "✅" where next != nil: done = next; i += 2; continue
            case "⏫": priority = .high
            case "🔼": priority = .medium
            case "🔽": priority = .low
            default:
                let lower = tok.lowercased()
                if lower == "#осн" { kind = .main }
                else if lower == "#доп" { kind = .extra }
                else if tok.hasPrefix("@"), tok.dropFirst().first?.isLetter == true {
                    from = String(tok.dropFirst())
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                } else {
                    kept.append(tok)
                }
            }
            i += 1
        }
        text = kept.joined(separator: " ")
    }

    init() {}
}

/// Пункт чек-листа. Живёт прямо в тексте заметки — отдельной модели нет,
/// поэтому заметка остаётся обычным markdown и без потерь уезжает в Obsidian.
/// Служебные метки (формат Obsidian Tasks) разбираются из той же строки:
/// `- [ ] Отчёт #осн @руководитель 🔼 ➕ 2026-10-15 📅 2026-10-20`
struct ChecklistItem: Identifiable, Hashable {
    let line: Int          // индекс строки в тексте заметки
    let isDone: Bool
    let depth: Int         // 0 — задача, 1+ — подзадача (по отступу)
    var fields = TaskFields()
    var inheritedDue: Date? = nil   // срок заметки
    var parent: Int? = nil          // строка родительской задачи

    var id: Int { line }

    var text: String { fields.text }
    var kind: TaskKind { fields.kind }
    var from: String? { fields.from }
    var priority: TaskPriority { fields.priority }
    var createdAt: Date? { fields.created }
    var doneAt: Date? { fields.done }
    /// Свой 📅, иначе срок заметки
    var due: Date? { fields.due ?? inheritedDue }

    var isOverdue: Bool {
        guard let due, !isDone else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let due else { return false }
        return Calendar.current.isDateInToday(due)
    }

    /// Сдано позже срока
    var isLate: Bool {
        guard let due, let doneAt else { return false }
        return doneAt > due
    }

    /// `  - [x] хвост` → («  - [x] », «хвост»). nil — строка не чекбокс.
    static func split(_ raw: String) -> (prefix: String, body: String, isDone: Bool, width: Int)? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }
        let body = raw.dropFirst(indent.count)
        guard body.hasPrefix("- [") || body.hasPrefix("* [") else { return nil }

        let rest = body.dropFirst(3)                      // после "- ["
        guard let mark = rest.first, rest.dropFirst().first == "]" else { return nil }
        let done = mark == "x" || mark == "X"
        guard done || mark == " " else { return nil }

        let tail = rest.dropFirst(2)
        let prefix = String(raw[..<tail.startIndex]) + " "
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (prefix, tail.trimmingCharacters(in: .whitespaces), done, width)
    }
}

struct Note: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    var color: NoteColor = .none
    /// Срок выполнения (день). Задачи внутри заметки наследуют его.
    var dueDate: Date?
    /// Одноразовое напоминание: сработает и очистится
    var reminderAt: Date?

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(),
         updatedAt: Date = Date(), isPinned: Bool = false, color: NoteColor = .none,
         dueDate: Date? = nil, reminderAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.color = color
        self.dueDate = dueDate
        self.reminderAt = reminderAt
    }

    /// Старые notes.json не знают про цвет и сроки — читаем мягко, чтобы не потерять заметки
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        color = try c.decodeIfPresent(NoteColor.self, forKey: .color) ?? .none
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
    }

    // MARK: - Текст

    var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Без названия" : trimmed
    }

    var preview: String {
        text.split(separator: "\n")
            .dropFirst()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// `#метки` из текста — по ним же работает поиск
    var tags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            guard token.hasPrefix("#") else { continue }
            let body = token.dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'«»"))
            guard let head = body.first, head.isLetter else { continue }
            let key = body.lowercased()
            if seen.insert(key).inserted { out.append(body) }
        }
        return out
    }

    // MARK: - Задачи

    /// Разбор markdown-чекбоксов с учётом отступов: `- [ ]`, `* [x]`, вложенные подзадачи
    var checklist: [ChecklistItem] {
        var chain: [ChecklistItem] = []          // открытые предки текущей строки
        return text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            guard let s = ChecklistItem.split(raw) else { return nil }
            let depth = min(s.width / 2, 3)
            while let last = chain.last, last.depth >= depth { chain.removeLast() }
            let item = ChecklistItem(line: index, isDone: s.isDone, depth: depth,
                                     fields: TaskFields(parsing: s.body),
                                     inheritedDue: dueDate, parent: chain.last?.line)
            chain.append(item)
            return item
        }
    }

    var todo: (done: Int, total: Int) {
        let items = checklist
        return (items.filter(\.isDone).count, items.count)
    }

    var openTasks: [ChecklistItem] { checklist.filter { !$0.isDone } }

    /// Все задачи закрыты — заметка считается завершённой и не «горит» просрочкой
    var isComplete: Bool {
        let t = todo
        return t.total > 0 && t.done == t.total
    }

    var progress: Double {
        let t = todo
        return t.total > 0 ? Double(t.done) / Double(t.total) : 0
    }

    // MARK: - Сроки

    /// Горит сама заметка или любая её открытая задача со своим сроком
    var isOverdue: Bool {
        if let due = dueDate, !isComplete, due < Calendar.current.startOfDay(for: Date()) {
            return true
        }
        return openTasks.contains(where: \.isOverdue)
    }

    var isDueToday: Bool {
        guard let due = dueDate else { return false }
        return Calendar.current.isDateInToday(due)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// Даты в строке задачи: `2026-10-20`, как пишет Obsidian Tasks
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    var dueLabel: String? { dueDate.map(Note.dayLabel) }

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "сегодня" }
        if cal.isDateInTomorrow(date) { return "завтра" }
        if cal.isDateInYesterday(date) { return "вчера" }
        return dayFormatter.string(from: date)
    }

    var reminderLabel: String? {
        guard let at = reminderAt else { return nil }
        if Calendar.current.isDateInToday(at) {
            return "в " + at.formatted(date: .omitted, time: .shortened)
        }
        return Note.timeFormatter.string(from: at)
    }

    /// «124 сл. · ~1 мин чтения» — пригождается для конспектов и текстов
    var stats: String {
        let minutes = max(1, Int((Double(wordCount) / 200).rounded(.up)))
        var out = "\(wordCount) сл. · \(text.count) симв. · ~\(minutes) мин"
        let t = todo
        if t.total > 0 { out += " · задач \(t.done)/\(t.total)" }
        return out
    }
}

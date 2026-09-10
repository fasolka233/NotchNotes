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

/// Пункт чек-листа. Живёт прямо в тексте заметки — отдельной модели нет,
/// поэтому заметка остаётся обычным markdown и без потерь уезжает в Obsidian.
struct ChecklistItem: Identifiable, Hashable {
    let line: Int          // индекс строки в тексте заметки
    let text: String
    let isDone: Bool
    let depth: Int         // 0 — задача, 1+ — подзадача (по отступу)

    var id: Int { line }
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
        text.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
            let body = raw.dropFirst(indent.count)
            guard body.hasPrefix("- [") || body.hasPrefix("* [") else { return nil }

            let rest = body.dropFirst(3)                      // после "- ["
            guard let mark = rest.first, rest.dropFirst().first == "]" else { return nil }
            let done = mark == "x" || mark == "X"
            guard done || mark == " " else { return nil }

            let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            return ChecklistItem(line: index,
                                 text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces),
                                 isDone: done,
                                 depth: min(width / 2, 3))
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

    var isOverdue: Bool {
        guard let due = dueDate, !isComplete else { return false }
        return due < Calendar.current.startOfDay(for: Date())
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

    var dueLabel: String? {
        guard let due = dueDate else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(due) { return "сегодня" }
        if cal.isDateInTomorrow(due) { return "завтра" }
        if cal.isDateInYesterday(due) { return "вчера" }
        return Note.dayFormatter.string(from: due)
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

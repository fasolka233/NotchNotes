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

    func delete(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
    }

    @discardableResult
    func duplicate(_ id: Note.ID) -> Note? {
        guard let src = notes.first(where: { $0.id == id }) else { return nil }
        return addNote(src.text, color: src.color)
    }

    // MARK: - Задачи внутри текста

    /// Переключить чекбокс на конкретной строке
    func toggleItem(line: Int, in id: Note.ID) {
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            let l = lines[line]
            if let r = l.range(of: "[ ]") {
                lines[line] = l.replacingCharacters(in: r, with: "[x]")
            } else if let r = l.range(of: "[x]") ?? l.range(of: "[X]") {
                lines[line] = l.replacingCharacters(in: r, with: "[ ]")
            } else {
                return false
            }
            return true
        }
    }

    /// Подзадача — та же строка markdown, но с отступом на два пробела глубже
    func addSubtask(after line: Int, in id: Note.ID, text: String = "") {
        editLines(id) { lines in
            guard lines.indices.contains(line) else { return false }
            let indent = String(lines[line].prefix { $0 == " " || $0 == "\t" })
            lines.insert(indent + "  - [ ] " + text, at: line + 1)
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

    /// Добавить задачу в конец заметки
    func addTask(_ text: String, to id: Note.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = self.text(for: id)
        let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        setText(current + prefix + "- [ ] " + trimmed, for: id)
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

    private func safeFileName(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Заметка" : String(cleaned.prefix(60))
    }

    // MARK: - Диск

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else { return }
        notes = decoded
    }

    private func save(_ notes: [Note]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

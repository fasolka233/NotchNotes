import SwiftUI
import AppKit

/// Сводка задач по всем заметкам: одно место, где видно «что горит».
/// Своей модели нет — читаем те же markdown-чекбоксы, что и в заметках.
struct TasksPane: View {
    @ObservedObject var store: NotesStore
    var onReveal: (Note.ID) -> Void

    enum Scope: String, CaseIterable, Identifiable {
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

    @State private var scope: Scope = .open
    @State private var draft = ""

    /// Заметки с подходящими задачами, срочные сверху
    private var groups: [(note: Note, items: [ChecklistItem])] {
        store.notes.compactMap { note -> (Note, [ChecklistItem])? in
            switch scope {
            case .open where !note.openTasks.isEmpty:
                return (note, note.openTasks)
            case .done:
                let done = note.checklist.filter(\.isDone)
                return done.isEmpty ? nil : (note, done)
            case .today where (note.isDueToday || note.isOverdue) && !note.openTasks.isEmpty:
                return (note, note.openTasks)
            case .overdue where note.isOverdue && !note.openTasks.isEmpty:
                return (note, note.openTasks)
            default:
                return nil
            }
        }
        .sorted { a, b in
            if a.0.isOverdue != b.0.isOverdue { return a.0.isOverdue }
            switch (a.0.dueDate, b.0.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.0.updatedAt > b.0.updatedAt
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header

            if groups.isEmpty {
                EmptyState(icon: scope == .open ? "checkmark.seal" : "tray",
                           title: emptyTitle,
                           subtitle: scope == .open
                                ? "Новые задачи появятся здесь автоматически"
                                : nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(groups, id: \.note.id) { group in
                            section(group.note, group.items)
                        }
                    }
                    .padding(.bottom, Theme.Space.s)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(Theme.Ink.primary)
    }

    private var emptyTitle: String {
        switch scope {
        case .open:    return "Задач нет — можно выдохнуть"
        case .today:   return "На сегодня ничего не запланировано"
        case .overdue: return "Просроченного нет"
        case .done:    return "Пока ничего не сделано"
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 2) {
                ForEach(Scope.allCases) { s in
                    FilterChip(icon: s.icon,
                               title: s.title,
                               count: count(s),
                               isOn: scope == s,
                               tint: s == .overdue && store.overdueCount > 0
                                     ? Theme.Accent.danger : nil,
                               alwaysShowTitle: true) {
                        withAnimation(Theme.quick) { scope = s }
                    }
                }
            }

            Spacer(minLength: Theme.Space.xs)

            SearchField(placeholder: "Новая задача → Входящие",
                        text: $draft, icon: "plus.circle", onSubmit: quickAdd)
                .frame(width: 240)
        }
    }

    /// Счётчик на чипе — сразу видно, где что-то есть, без переключения
    private func count(_ s: Scope) -> Int {
        s == .overdue ? store.overdueCount : 0
    }

    private func section(_ note: Note, _ items: [ChecklistItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(note.color == .none ? Theme.Stroke.outline : note.color.tint)
                    .frame(width: 3, height: 14)

                Button { onReveal(note.id) } label: {
                    HStack(spacing: 4) {
                        Text(note.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Ink.primary)
                .help("Открыть заметку")

                if let due = note.dueLabel {
                    Label(due, systemImage: note.reminderAt == nil ? "calendar" : "bell.fill")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(note.isOverdue ? Theme.Accent.danger.opacity(0.22)
                                    : note.isDueToday ? Theme.Accent.warning.opacity(0.20)
                                    : Theme.Surface.field, in: Capsule())
                        .foregroundStyle(note.isOverdue ? Theme.Accent.danger
                                         : note.isDueToday ? Theme.Accent.warning
                                         : Theme.Ink.secondary)
                }

                Spacer(minLength: 0)

                Text("\(note.todo.done)/\(note.todo.total)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Ink.tertiary)
            }

            ForEach(items) { item in
                HStack(spacing: Theme.Space.s) {
                    Color.clear.frame(width: 4 + CGFloat(item.depth) * 14, height: 1)

                    Button { store.toggleItem(line: item.line, in: note.id) } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Icon.check)
                            .foregroundStyle(item.isDone ? Theme.Accent.success
                                                         : Theme.Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isDone ? "Снять отметку" : "Отметить сделанным")

                    Text(item.text.isEmpty ? "Без названия" : item.text)
                        .font(Theme.Font.caption)
                        .strikethrough(item.isDone, color: Theme.Ink.tertiary)
                        .foregroundStyle(item.isDone ? Theme.Ink.tertiary : Theme.Ink.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .rowHighlight(selected: false, radius: 6)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Подзадача") { store.addSubtask(after: item.line, in: note.id) }
                    Button("Открыть заметку") { onReveal(note.id) }
                    Divider()
                    Button("Удалить", role: .destructive) {
                        store.removeItem(line: item.line, in: note.id)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
        .background(Theme.Surface.base,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func quickAdd() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addTask(text, to: store.inbox().id)
        draft = ""
    }
}

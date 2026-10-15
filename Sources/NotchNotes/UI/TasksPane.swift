import SwiftUI
import AppKit

/// Учёт поручений по всем заметкам: что поручили → что в работе → что сдал и вовремя ли.
/// Своей модели нет — читаем те же markdown-чекбоксы с метками Obsidian Tasks.
struct TasksPane: View {
    @ObservedObject var store: NotesStore
    var onReveal: (Note.ID) -> Void

    @State private var scope: TaskScope = .open
    @State private var kind: TaskKind? = nil
    @State private var draft = ""

    private var entries: [TaskEntry] { store.tasks(scope, kind: kind) }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            toolbar

            if entries.isEmpty {
                EmptyState(icon: scope == .open ? "checkmark.seal" : "tray",
                           title: emptyTitle,
                           subtitle: scope == .open
                                ? "Пример: Отчёт #осн @руководитель 📅 20.10"
                                : nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { row($0) }
                    }
                    .padding(4)
                    .background(Theme.Surface.base,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card))
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
        case .done:    return "За 30 дней ничего не сдано"
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 2) {
                ForEach(TaskScope.allCases) { s in
                    let n = store.tasks(s, kind: kind).count
                    FilterChip(icon: s.icon,
                               title: s.title,
                               count: n,
                               isOn: scope == s,
                               tint: s == .overdue && n > 0 ? Theme.Accent.danger : nil,
                               alwaysShowTitle: true) {
                        withAnimation(Theme.quick) { scope = s }
                    }
                }
            }

            Spacer(minLength: Theme.Space.xs)

            SearchField(placeholder: "Задача #осн @кто !пт",
                        text: $draft, icon: "plus.circle", onSubmit: quickAdd)
                .frame(width: 220)
                .help("Попадёт во «Входящие». Метки: #осн / #доп, @от кого, ⏫ 🔼 🔽, срок: 📅 20.10, !завтра, !пт")

            IconButton(icon: "square.and.arrow.up", hint: "Экспорт задач в CSV") {
                store.exportTasksCSV()
            }
        }
    }

    /// Тип поручения слева, сводка справа — одной строкой
    private var toolbar: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 2) {
                kindButton(nil, "Все")
                kindButton(.main, "Основные")
                kindButton(.extra, "Дополнительные")
            }
            .padding(2)
            .background(Theme.Surface.field, in: Capsule())

            Spacer(minLength: Theme.Space.xs)

            Text(store.taskSummary(kind: kind))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
        }
    }

    private func kindButton(_ k: TaskKind?, _ title: String) -> some View {
        let on = kind == k
        return Button { withAnimation(Theme.quick) { kind = k } } label: {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(on ? Theme.Surface.active : .clear, in: Capsule())
                .foregroundStyle(on ? Theme.Ink.primary : Theme.Ink.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Строка задачи

    private func row(_ e: TaskEntry) -> some View {
        let t = e.item
        return HStack(spacing: Theme.Space.s) {
            Button { store.toggleItem(line: t.line, in: e.note.id) } label: {
                Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Icon.check)
                    .foregroundStyle(t.isDone ? Theme.Accent.success : Theme.Ink.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.isDone ? "Снять отметку" : "Отметить сделанным")
            .accessibilityLabel(t.isDone ? "Снять отметку" : "Отметить сделанным")

            // слот под приоритет есть всегда — названия стоят ровной колонкой
            ZStack {
                if let glyph = priorityGlyph(t.priority) {
                    Image(systemName: glyph.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(glyph.tint)
                        .help("Приоритет: \(t.priority.title)")
                }
            }
            .frame(width: 10, height: 12)

            Text(t.text.isEmpty ? "Без названия" : t.text)
                .font(Theme.Font.caption)
                .strikethrough(t.isDone, color: Theme.Ink.tertiary)
                .foregroundStyle(t.isDone ? Theme.Ink.tertiary : Theme.Ink.primary)
                .lineLimit(1)
                .help(t.text)

            if kind == nil, t.kind != .other {
                Text(t.kind == .main ? "осн" : "доп")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.Surface.field, in: Capsule())
                    .foregroundStyle(Theme.Ink.secondary)
                    .help(t.kind.title)
            }

            Spacer(minLength: Theme.Space.s)

            if let from = t.from {
                Text("@" + from)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                    .help("От кого")
            }

            if t.isDone {
                doneLabel(t)
            } else if let due = t.due {
                dueChip(due, t)
            }

            Button { onReveal(e.note.id) } label: {
                HStack(spacing: 2) {
                    Text(e.note.title).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.Ink.tertiary)
                .frame(maxWidth: 110, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Открыть заметку «\(e.note.title)»")
        }
        .padding(.leading, 4 + CGFloat(t.depth) * 14).padding(.trailing, 6)
        .padding(.vertical, 3)
        .rowHighlight(selected: false, radius: 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Подзадача") { store.addSubtask(after: t.line, in: e.note.id) }
            Button("Открыть заметку") { onReveal(e.note.id) }
            Divider()
            Button("Удалить", role: .destructive) {
                store.removeItem(line: t.line, in: e.note.id)
            }
        }
    }

    /// Срок: красный — просрочено, жёлтый — сегодня/завтра. Цвет дублируется иконкой.
    private func dueChip(_ due: Date, _ t: ChecklistItem) -> some View {
        let soon = t.isDueToday || Calendar.current.isDateInTomorrow(due)
        let tint = t.isOverdue ? Theme.Accent.danger : soon ? Theme.Accent.warning : Theme.Ink.secondary
        return Label(Note.dayLabel(due),
                     systemImage: t.isOverdue ? "exclamationmark.circle" : "calendar")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(t.isOverdue ? Theme.Accent.danger.opacity(0.22)
                        : soon ? Theme.Accent.warning.opacity(0.20)
                        : Theme.Surface.field, in: Capsule())
            .foregroundStyle(tint)
            .help(t.isOverdue ? "Просрочено" : "Срок")
    }

    @ViewBuilder
    private func doneLabel(_ t: ChecklistItem) -> some View {
        if let at = t.doneAt {
            HStack(spacing: 4) {
                Text("сдано " + Note.dayLabel(at))
                    .foregroundStyle(Theme.Ink.tertiary)
                if t.isLate {
                    Text("с опозданием")
                        .foregroundStyle(Theme.Accent.danger)
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private func priorityGlyph(_ p: TaskPriority) -> (icon: String, tint: Color)? {
        switch p {
        case .high:   return ("chevron.up.2", Theme.Accent.warning)
        case .medium: return ("chevron.up", Theme.Ink.secondary)
        case .low:    return ("chevron.down", Theme.Ink.tertiary)
        case .none:   return nil
        }
    }

    private func quickAdd() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addTask(text, to: store.inbox().id)
        draft = ""
    }
}

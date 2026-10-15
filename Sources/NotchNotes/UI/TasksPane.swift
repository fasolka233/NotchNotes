import SwiftUI
import AppKit

/// Учёт поручений по всем заметкам: что поручили → что в работе → что сдал и вовремя ли.
/// Своей модели нет — читаем те же markdown-чекбоксы с метками Obsidian Tasks.
struct TasksPane: View {
    @ObservedObject var store: NotesStore
    var onReveal: (Note.ID) -> Void
    /// Открыты быстрой записью — сразу курсор в поле новой задачи
    var autoFocusDraft = false
    /// Задачу добавили из поля быстрого ввода
    var onAdded: () -> Void = {}

    @State private var scope: TaskScope = .open
    @State private var kind: TaskKind? = nil
    @State private var author: String? = nil
    @State private var query = ""
    @State private var draft = ""
    @State private var collapsed: Set<String> = []
    @State private var editing: TaskRef?
    /// Строка под клавиатурой: ↑↓ двигают, пробел отмечает, ⏎ открывает
    @State private var selected: TaskRef?
    @FocusState private var draftFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        let entries = store.tasks(scope, kind: kind, from: author, query: query)
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty { assist }
                toolbar

                if entries.isEmpty {
                    EmptyState(icon: scope == .open ? "checkmark.seal" : "tray",
                               title: emptyTitle,
                               subtitle: scope == .open && query.isEmpty && author == nil
                                    ? "Пример: Отчёт #осн @руководитель !пт"
                                    : nil)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(entries) { group($0) }
                            }
                            .padding(4)
                            .background(Theme.Surface.base,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: selected) { _, ref in
                            guard let ref else { return }
                            withAnimation(Theme.quick) { proxy.scrollTo(rowID(ref)) }
                        }
                    }
                }

                Text(store.taskSummary(kind: kind, from: author))
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
            }

            if editing != nil {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = nil }
                    .transition(.opacity)
                TaskEditor(store: store, ref: $editing, onReveal: onReveal)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 2)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            if let r = store.lastRemoved {
                UndoToast(token: r, title: r.title.isEmpty ? "задача" : r.title,
                          onUndo: { store.undoRemove() },
                          onExpire: { if store.lastRemoved == r { store.lastRemoved = nil } })
            }
        }
        .animation(Theme.snap, value: editing)
        .animation(Theme.quick, value: store.lastRemoved)
        .foregroundStyle(Theme.Ink.primary)
        .onAppear {
            KeyCommand.handlers[.tasks] = handle
            // в только что появившейся панели фокус встаёт со следующего прохода
            if autoFocusDraft { DispatchQueue.main.async { draftFocused = true } }
        }
    }

    // MARK: - Клавиатура

    /// Строки ровно в том порядке, в каком их видно: свёрнутые подзадачи пропускаем
    private var visibleRows: [TaskRef] {
        store.tasks(scope, kind: kind, from: author, query: query).flatMap { e in
            ([e.item] + (collapsed.contains(e.id) ? [] : e.children))
                .map { TaskRef(note: e.note.id, line: $0.line) }
        }
    }

    private func handle(_ cmd: KeyCommand) -> Bool {
        guard editing == nil else { return false }   // в редакторе клавиши его
        switch cmd {
        case .find: searchFocused = true
        case .new:  draftFocused = true
        case .up, .down:
            let rows = visibleRows
            guard !rows.isEmpty else { return true }
            let i = selected.flatMap(rows.firstIndex(of:))
            let next = cmd == .down ? (i.map { $0 + 1 } ?? 0) : (i.map { $0 - 1 } ?? rows.count - 1)
            selected = rows[min(max(next, 0), rows.count - 1)]
            draftFocused = false; searchFocused = false
        case .open:
            guard let selected, visibleRows.contains(selected) else { return false }
            editing = selected
        case .toggle:
            guard let selected, visibleRows.contains(selected) else { return false }
            store.toggleItem(line: selected.line, in: selected.note)
        }
        return true
    }

    private func rowID(_ ref: TaskRef) -> String { "\(ref.note)-\(ref.line)" }

    private var emptyTitle: String {
        if !query.isEmpty || author != nil { return "Ничего не нашлось" }
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
                    let n = store.tasks(s, kind: kind, from: author, query: query).count
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

            SearchField(placeholder: "Новая задача #осн @кто !пт  ⌘N",
                        text: $draft, icon: "plus.circle", onSubmit: quickAdd, focus: $draftFocused)
                .frame(width: 230)
                .help("Попадёт во «Входящие». Метки: #осн / #доп, @от кого, ⏫ 🔼 🔽, срок: 📅 20.10, !завтра, !пт, повтор: !еженедельно")

            IconButton(icon: "square.and.arrow.up", hint: "Экспорт задач в CSV") {
                store.exportTasksCSV()
            }
        }
    }

    /// Пока печатаешь: как распознались метки + знакомые имена после «@»
    private var assist: some View {
        let parsed = TaskFields(parsing: NotesStore.normalizeTask(draft))
        let last = draft.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let typing = last.hasPrefix("@") && !draft.hasSuffix(" ") ? String(last.dropFirst()).lowercased() : nil
        let names = typing.map { t in
            Array(store.taskAuthors.filter { $0.lowercased().hasPrefix(t) && $0.lowercased() != t }.prefix(5))
        } ?? []

        return HStack(spacing: Theme.Space.s) {
            Image(systemName: "arrow.turn.down.right")
                .font(Theme.Icon.small)
                .foregroundStyle(Theme.Ink.tertiary)

            if !names.isEmpty {
                ForEach(names, id: \.self) { name in
                    Button { complete(name) } label: {
                        Text("@" + name)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.Surface.active, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Подставить")
                }
            } else if parsed.text.isEmpty {
                Text("Метки: #осн #доп · @кто · ⏫ 🔼 🔽 · 📅 20.10 · !завтра · !пт · !еженедельно")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            } else {
                Text(parsed.text).font(Theme.Font.label).lineLimit(1)
                if parsed.kind != .other { tag(parsed.kind.title) }
                if let from = parsed.from { tag("@" + from) }
                if parsed.priority != .none { tag("приоритет " + parsed.priority.title) }
                if let due = parsed.due { tag("срок " + Note.dayLabel(due)) }
                if let recur = parsed.recur { tag("повтор " + recur.title) }
                Text("Enter — добавить")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private func tag(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.Surface.field, in: Capsule())
            .foregroundStyle(Theme.Ink.secondary)
    }

    /// Тип, автор и поиск — одной строкой
    private var toolbar: some View {
        HStack(spacing: Theme.Space.m) {
            PillPicker(options: [(TaskKind?.none, "Все"), (.main, "Основные"), (.extra, "Дополнительные")],
                       selection: $kind)

            Menu {
                Button("Все") { author = nil }
                if !store.taskAuthors.isEmpty { Divider() }
                ForEach(store.taskAuthors, id: \.self) { name in
                    Button("@" + name) { author = name }
                }
            } label: {
                Label(author.map { "@" + $0 } ?? "От кого", systemImage: "person")
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11, weight: author == nil ? .medium : .semibold))
            .controlSize(.small)
            .fixedSize()
            .foregroundStyle(author == nil ? Theme.Ink.secondary : Theme.Ink.primary)
            .help("Фильтр по тому, от кого поручение")

            Spacer(minLength: Theme.Space.xs)

            SearchField(placeholder: "Поиск по задачам  ⌘F", text: $query, focus: $searchFocused) {
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(Theme.Icon.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .help("Очистить")
                }
            }
            .frame(width: 200)
        }
    }

    // MARK: - Список

    @ViewBuilder
    private func group(_ e: TaskEntry) -> some View {
        let open = !collapsed.contains(e.id)
        TaskRow(store: store, note: e.note, item: e.item,
                isSelected: selected == TaskRef(note: e.note.id, line: e.item.line),
                showKind: kind == nil,
                progress: e.children.isEmpty ? nil : e.progress,
                expanded: e.children.isEmpty ? nil : open,
                onToggleExpand: {
                    withAnimation(Theme.quick) {
                        if open { collapsed.insert(e.id) } else { collapsed.remove(e.id) }
                    }
                },
                onEdit: { editing = TaskRef(note: e.note.id, line: $0) },
                onReveal: onReveal)

        if open {
            ForEach(e.children) { child in
                TaskRow(store: store, note: e.note, item: child,
                        isSelected: selected == TaskRef(note: e.note.id, line: child.line),
                        indent: child.depth - e.item.depth,
                        showKind: false,
                        onEdit: { editing = TaskRef(note: e.note.id, line: $0) },
                        onReveal: onReveal)
            }
        }
    }

    private func complete(_ name: String) {
        var tokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return }
        tokens[tokens.count - 1] = "@" + name
        draft = tokens.joined(separator: " ") + " "
    }

    private func quickAdd() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addTask(text, to: store.inbox().id)
        draft = ""
        onAdded()
    }
}

/// Строка задачи. Клик — редактор; под курсором — быстрые действия
/// (они же продублированы в контекстном меню, чтобы не зависеть от наведения).
private struct TaskRow: View {
    @ObservedObject var store: NotesStore
    let note: Note
    let item: ChecklistItem
    var isSelected = false
    var indent = 0
    var showKind = true
    var progress: (done: Int, total: Int)? = nil
    var expanded: Bool? = nil
    var onToggleExpand: () -> Void = {}
    var onEdit: (Int) -> Void
    var onReveal: (Note.ID) -> Void

    @State private var hovering = false

    var body: some View {
        let t = item
        HStack(spacing: Theme.Space.s) {
            // слот под стрелку раскрытия есть у всех строк — колонка ровная
            ZStack {
                    if let expanded {
                        Button(action: onToggleExpand) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(Theme.Ink.tertiary)
                                .frame(width: 14, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Свернуть подзадачи" : "Показать подзадачи")
                }
            }
            .frame(width: 14)

            Button { store.toggleItem(line: t.line, in: note.id) } label: {
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

            if let progress {
                Text("\(progress.done)/\(progress.total)")
                    .font(Theme.Font.badge)
                    .foregroundStyle(progress.done == progress.total ? Theme.Accent.success
                                                                     : Theme.Ink.tertiary)
                    .help("Подзадачи")
            }

            if showKind, t.kind != .other {
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

            if let recur = t.fields.recur {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .help("Повтор: \(recur.title)")
                    .accessibilityLabel("Повтор: \(recur.title)")
            }

            if t.isDone {
                doneLabel(t)
            } else if let due = t.due {
                dueChip(due, t)
            }

            // под курсором ссылка на заметку уступает место действиям — ширина та же
            ZStack(alignment: .trailing) {
                if hovering { actions(t) } else if indent == 0 { noteLink }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.leading, 4 + CGFloat(indent) * 20).padding(.trailing, 6)
        .padding(.vertical, 3)
        .rowHighlight(selected: isSelected, radius: 6)
        .contentShape(Rectangle())
        .id("\(note.id)-\(t.line)")
        .onTapGesture { onEdit(t.line) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Изменить…") { onEdit(t.line) }
            Button("Подзадача") { store.addSubtask(after: t.line, in: note.id); onEdit(t.line) }
            if !t.isDone {
                Divider()
                Button("Срок +1 день") { store.shiftDue(line: t.line, in: note.id, days: 1) }
                Button("Срок +неделя") { store.shiftDue(line: t.line, in: note.id, days: 7) }
                Menu("Приоритет") {
                    ForEach([TaskPriority.high, .medium, .low, .none], id: \.self) { p in
                        Button(p == .none ? "Без приоритета" : p.title.capitalized) {
                            store.updateTask(line: t.line, in: note.id) { $0.priority = p }
                        }
                    }
                }
            }
            Divider()
            Button("Открыть заметку") { onReveal(note.id) }
            Button("Удалить", role: .destructive) { store.removeTask(line: t.line, in: note.id) }
        }
    }

    private var noteLink: some View {
        Button { onReveal(note.id) } label: {
            HStack(spacing: 2) {
                Text(note.title).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.Ink.tertiary)
        }
        .buttonStyle(.plain)
        .help("Открыть заметку «\(note.title)»")
    }

    private func actions(_ t: ChecklistItem) -> some View {
        HStack(spacing: 0) {
            if !t.isDone {
                textAction("+1д", "Перенести срок на день") {
                    store.shiftDue(line: t.line, in: note.id, days: 1)
                }
                textAction("+7д", "Перенести срок на неделю") {
                    store.shiftDue(line: t.line, in: note.id, days: 7)
                }
            }
            IconButton(icon: "pencil", hint: "Изменить") { onEdit(t.line) }
            IconButton(icon: "trash", tint: Theme.Ink.tertiary, hint: "Удалить") {
                store.removeTask(line: t.line, in: note.id)
            }
        }
    }

    private func textAction(_ title: String, _ hint: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 28, height: 22)
                .background(Theme.Surface.field, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Theme.Ink.secondary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 2)
        .help(hint)
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
            .help(t.isOverdue ? "Просрочено" : t.fields.due == nil ? "Срок заметки" : "Срок")
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
}

import SwiftUI

/// Какую задачу правим: заметка + строка
struct TaskRef: Equatable {
    let note: Note.ID
    let line: Int
}

/// Переключатель-«таблетки»: тип, приоритет, фильтры. Один вид во всех местах.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = selection == option.value
                Button { withAnimation(Theme.quick) { selection = option.value } } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(on ? Theme.Surface.active : .clear, in: Capsule())
                        .foregroundStyle(on ? Theme.Ink.primary : Theme.Ink.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.Surface.field, in: Capsule())
    }
}

/// Карточка редактирования задачи поверх списка. Не системный поповер:
/// он живёт в отдельном окне, и панель челки свернулась бы под курсором.
/// Всё пишется обратно в ту же строку markdown.
struct TaskEditor: View {
    @ObservedObject var store: NotesStore
    @Binding var ref: TaskRef?
    var onReveal: (Note.ID) -> Void

    @State private var title = ""
    @State private var from = ""
    @State private var newSubtask = ""
    @State private var removed = false

    private var noteID: Note.ID? { ref?.note }
    private var line: Int { ref?.line ?? -1 }
    private var note: Note? { noteID.flatMap(store.note) }
    private var item: ChecklistItem? { note?.checklist.first { $0.line == line } }

    /// Все подзадачи (и подподзадачи) сразу под задачей
    private var descendants: [ChecklistItem] {
        guard let item, let list = note?.checklist,
              let i = list.firstIndex(where: { $0.line == item.line }) else { return [] }
        return Array(list[(i + 1)...].prefix { $0.depth > item.depth })
    }

    var body: some View {
        if let item, let note {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header(item)
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    fields(item, note).frame(width: 390, alignment: .leading)
                    Rectangle().fill(Theme.Stroke.hairline).frame(width: 1)
                    subtasks(item)
                }
                footer(item, note)
            }
            .padding(Theme.Space.l)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.Stroke.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            .onAppear(perform: load)
            .onChange(of: ref) { old, _ in commit(old); load() }
            .onDisappear { commit(ref) }
            .onExitCommand(perform: close)
        }
    }

    // MARK: - Шапка

    private func header(_ item: ChecklistItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let parent = item.parent,
               let p = note?.checklist.first(where: { $0.line == parent }) {
                Button { go(parent) } label: {
                    Label("К задаче «\(p.text)»", systemImage: "chevron.left")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Space.s) {
                Button { store.toggleItem(line: item.line, in: noteID!) } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(item.isDone ? Theme.Accent.success : Theme.Ink.secondary)
                }
                .buttonStyle(.plain)
                .help(item.isDone ? "Снять отметку" : "Отметить сделанным")
                .accessibilityLabel(item.isDone ? "Снять отметку" : "Отметить сделанным")

                TextField("Название задачи", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .onSubmit { commit(ref) }

                IconButton(icon: "xmark", hint: "Закрыть (Esc)", action: close)
            }
        }
    }

    // MARK: - Поля

    private func fields(_ item: ChecklistItem, _ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            row("Тип") {
                PillPicker(options: [(TaskKind.other, "Прочее"), (.main, "Основная"), (.extra, "Доп.")],
                           selection: binding(\.kind, default: .other))
            }

            row("От кого") {
                HStack(spacing: 4) {
                    TextField("имя", text: $from)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.Surface.field, in: Capsule())
                        .frame(width: 150)
                        .onSubmit { commit(ref) }
                    let known = store.taskAuthors.filter { $0 != from }
                    if !known.isEmpty {
                        Menu {
                            ForEach(known, id: \.self) { name in
                                Button("@" + name) { from = name; commit(ref) }
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Выбрать из встречавшихся")
                    }
                }
            }

            row("Приоритет") {
                PillPicker(options: [(TaskPriority.none, "—"), (.high, "Высокий"),
                                     (.medium, "Средний"), (.low, "Низкий")],
                           selection: binding(\.priority, default: .none))
            }

            row("Срок") {
                HStack(spacing: 4) {
                    if item.fields.due != nil {
                        datePicker(\.due)
                        clearButton { $0.due = nil }
                    } else if let inherited = item.inheritedDue {
                        Text("из заметки: \(Note.dayLabel(inherited))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                    quick("Сегодня", 0); quick("Завтра", 1); quick("+7 дн", 7)
                }
            }

            row("Повтор") {
                PillPicker(options: [(Recurrence?.none, "—"), (.daily, "День"), (.weekly, "Неделя"),
                                     (.monthly, "Месяц"), (.yearly, "Год")],
                           selection: binding(\.recur, default: nil))
                    .help("Сделали — появится следующая с новым сроком")
            }

            row("Получено") {
                HStack(spacing: 4) {
                    if item.createdAt != nil {
                        datePicker(\.created)
                        clearButton { $0.created = nil }
                    } else {
                        setButton("Сегодня") { $0.created = Calendar.current.startOfDay(for: Date()) }
                    }
                }
            }

            if item.isDone {
                row("Сдано") {
                    HStack(spacing: 4) {
                        if item.doneAt != nil {
                            datePicker(\.done)
                            if item.isLate {
                                Text("с опозданием")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Accent.danger)
                            }
                        } else {
                            setButton("Сегодня") { $0.done = Calendar.current.startOfDay(for: Date()) }
                        }
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: 70, alignment: .leading)
            content()
        }
        .frame(minHeight: 22)
    }

    private func datePicker(_ kp: WritableKeyPath<TaskFields, Date?>) -> some View {
        DatePicker("", selection: Binding(
            get: { item?.fields[keyPath: kp] ?? Date() },
            set: { d in apply { $0[keyPath: kp] = Calendar.current.startOfDay(for: d) } }
        ), displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.field)
        .controlSize(.small)
        .fixedSize()
    }

    private func clearButton(_ change: @escaping (inout TaskFields) -> Void) -> some View {
        IconButton(icon: "xmark.circle", tint: Theme.Ink.tertiary, hint: "Убрать дату") { apply(change) }
    }

    private func setButton(_ title: String, _ change: @escaping (inout TaskFields) -> Void) -> some View {
        Button(title) { apply(change) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.Surface.field, in: Capsule())
            .foregroundStyle(Theme.Ink.secondary)
    }

    private func quick(_ title: String, _ days: Int) -> some View {
        setButton(title) {
            $0.due = Calendar.current.date(byAdding: .day, value: days,
                                           to: Calendar.current.startOfDay(for: Date()))
        }
    }

    // MARK: - Подзадачи

    private func subtasks(_ item: ChecklistItem) -> some View {
        let list = descendants
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Подзадачи").font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                if !list.isEmpty {
                    Text("\(list.filter(\.isDone).count)/\(list.count)")
                        .font(Theme.Font.badge)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(list) { sub in
                        SubtaskRow(store: store, noteID: noteID!, item: sub,
                                   indent: sub.depth - item.depth - 1,
                                   onOpen: { go(sub.line) })
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus").font(Theme.Icon.small).foregroundStyle(Theme.Ink.tertiary)
                TextField("Новая подзадача — Enter", text: $newSubtask)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.caption)
                    .onSubmit {
                        store.addSubtask(after: item.line, in: noteID!, text: newSubtask)
                        newSubtask = ""
                    }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.Surface.field, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Низ

    private func footer(_ item: ChecklistItem, _ note: Note) -> some View {
        HStack(spacing: Theme.Space.m) {
            Button { onReveal(note.id); close() } label: {
                Label("Открыть заметку «\(note.title)»", systemImage: "arrow.up.right")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Ink.tertiary)

            Spacer()

            Button(role: .destructive) {
                removed = true
                store.removeTask(line: item.line, in: note.id)
                ref = nil
            } label: {
                Label(descendants.isEmpty ? "Удалить" : "Удалить с подзадачами",
                      systemImage: "trash")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Accent.danger)

            Button("Готово", action: close)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Theme.Accent.tint, in: Capsule())
                .foregroundStyle(Theme.Ink.onAccent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Запись

    private func binding<T>(_ kp: WritableKeyPath<TaskFields, T>, default value: T) -> Binding<T> {
        Binding(get: { item?.fields[keyPath: kp] ?? value },
                set: { v in apply { $0[keyPath: kp] = v } })
    }

    private func apply(_ change: (inout TaskFields) -> Void) {
        guard let noteID else { return }
        store.updateTask(line: line, in: noteID, change)
    }

    private func load() {
        title = item?.text ?? ""
        from = item?.from ?? ""
        newSubtask = ""
    }

    /// Название и «от кого» пишем по Enter / при уходе — иначе метки в
    /// недопечатанном тексте разбирались бы на каждой букве
    private func commit(_ target: TaskRef?) {
        guard !removed, let target,
              let current = store.note(target.note)?.checklist.first(where: { $0.line == target.line })
        else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        let f = from.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard (!t.isEmpty && t != current.text) || f != (current.from ?? "") else { return }
        store.updateTask(line: target.line, in: target.note) {
            if !t.isEmpty { $0.text = t }
            $0.from = f.isEmpty ? nil : f
        }
    }

    private func go(_ line: Int) {
        guard let noteID else { return }
        ref = TaskRef(note: noteID, line: line)
    }

    private func close() {
        commit(ref)
        ref = nil
    }
}

/// Подзадача в редакторе: галочка, название правится на месте, переход к ней, удаление
private struct SubtaskRow: View {
    @ObservedObject var store: NotesStore
    let noteID: Note.ID
    let item: ChecklistItem
    let indent: Int
    var onOpen: () -> Void

    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button { store.toggleItem(line: item.line, in: noteID) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Icon.check)
                    .foregroundStyle(item.isDone ? Theme.Accent.success : Theme.Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Снять отметку" : "Отметить сделанным")

            TextField("Подзадача", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.caption)
                .strikethrough(item.isDone, color: Theme.Ink.tertiary)
                .foregroundStyle(item.isDone ? Theme.Ink.tertiary : Theme.Ink.primary)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }

            if let due = item.fields.due {
                Text(Note.dayLabel(due))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.isOverdue ? Theme.Accent.danger : Theme.Ink.tertiary)
            }

            IconButton(icon: "slider.horizontal.3", tint: Theme.Ink.tertiary,
                       hint: "Срок, приоритет, подзадачи", action: onOpen)
                .opacity(hovering ? 1 : 0.35)
            IconButton(icon: "xmark", tint: Theme.Ink.tertiary, hint: "Удалить подзадачу") {
                store.removeTask(line: item.line, in: noteID)
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.leading, 4 + CGFloat(indent) * 14).padding(.trailing, 2)
        .rowHighlight(selected: false, radius: 6)
        .onHover { hovering = $0 }
        .onAppear { text = item.text }
        .onChange(of: item.text) { _, new in text = new }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != item.text else { return }
        store.updateTask(line: item.line, in: noteID) { $0.text = t }
    }
}

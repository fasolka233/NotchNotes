import SwiftUI
import AppKit

struct NotesPane: View {
    @ObservedObject var store: NotesStore
    @Binding var selectedID: Note.ID?

    @State private var query = ""
    @State private var filter: NoteFilter = .all
    @State private var tag: String?

    private var list: [Note] { store.filtered(query, filter: filter, tag: tag) }
    private var selected: Note? { selectedID.flatMap(store.note) }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            listColumn
            Divider().overlay(Theme.Stroke.hairline)
            editor
        }
        .foregroundStyle(Theme.Ink.primary)
        .onAppear { if selectedID == nil { selectedID = list.first?.id } }
    }

    // MARK: - Список

    private var listColumn: some View {
        VStack(spacing: Theme.Space.s) {
            SearchField(placeholder: "Поиск  ·  ⏎ создаст заметку",
                        text: $query, onSubmit: createFromQuery) {
                IconButton(icon: "plus", hint: "Новая заметка") {
                    selectedID = store.addNote("").id
                }
            }

            filterChips
            if !store.allTags.isEmpty { tagChips }

            if list.isEmpty {
                EmptyState(icon: "tray",
                           title: query.isEmpty ? "Здесь пока пусто" : "Ничего не найдено",
                           subtitle: query.isEmpty ? nil : "Нажмите ⏎, чтобы создать заметку",
                           actionTitle: query.isEmpty ? "Новая заметка" : nil,
                           action: query.isEmpty ? { selectedID = store.addNote("").id } : nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(list) { row($0) }
                    }
                    .padding(.bottom, Theme.Space.xs)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 248)
    }

    /// Пять фильтров в колонке 248pt: подпись только у активного, счётчик — только
    /// у просроченных, иначе строка не помещается и чипы схлопываются в кашу.
    private var filterChips: some View {
        HStack(spacing: 1) {
            ForEach(NoteFilter.allCases) { f in
                FilterChip(icon: f.icon,
                           title: f.title,
                           count: f == .overdue ? store.overdueCount : nil,
                           isOn: filter == f,
                           tint: chipTint(f)) {
                    withAnimation(Theme.quick) { filter = f }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Просрочка красная даже когда фильтр не выбран — это единственный «горящий» статус
    private func chipTint(_ f: NoteFilter) -> Color? {
        guard f == .overdue, store.overdueCount > 0 else { return nil }
        return Theme.Accent.danger
    }

    private var tagChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(store.allTags.prefix(12), id: \.self) { t in
                    Button { tag = (tag == t) ? nil : t } label: {
                        Text("#" + t)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tag == t ? Theme.Accent.tint.opacity(0.4)
                                                 : Theme.Surface.field, in: Capsule())
                            .foregroundStyle(tag == t ? Theme.Ink.onAccent : Theme.Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tag == t ? "Снять фильтр по тегу" : "Показать только #\(t)")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 22)
    }

    private func row(_ note: Note) -> some View {
        HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(note.color == .none ? Color.clear : note.color.tint)
                .frame(width: 3, height: 28)

            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.Accent.pin)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)

                HStack(spacing: Theme.Space.s) {
                    if let due = note.dueLabel {
                        Label(due, systemImage: note.reminderAt == nil ? "calendar" : "bell.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(dueTint(note))
                    }
                    if !note.preview.isEmpty {
                        Text(note.preview)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Ink.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)

            if note.todo.total > 0 {
                Text("\(note.todo.done)/\(note.todo.total)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(note.isComplete ? Theme.Accent.success : Theme.Ink.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .rowHighlight(selected: selectedID == note.id)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = note.id }
        .onDrag { NSItemProvider(object: note.text as NSString) }
        .contextMenu {
            Button(note.isPinned ? "Открепить" : "Закрепить") { store.togglePin(note.id) }
            Menu("Цвет") {
                ForEach(NoteColor.allCases) { c in
                    Button(c.title) { store.setColor(c, for: note.id) }
                }
            }
            Menu("Срок") {
                Button("Сегодня") { store.setDue(Date(), for: note.id) }
                Button("Завтра") { store.setDue(shift(1), for: note.id) }
                Button("Через неделю") { store.setDue(shift(7), for: note.id) }
                Button("Убрать") { store.setDue(nil, for: note.id) }
            }
            Button("Скопировать") { copy(note.text) }
            Button("Поделиться…") { store.share(note.id) }
            Button("Сохранить как .md…") { store.exportMarkdown(note.id) }
            Button("Дублировать") { selectedID = store.duplicate(note.id)?.id }
            Divider()
            Button("Удалить", role: .destructive) { remove(note.id) }
        }
    }

    private func dueTint(_ note: Note) -> Color {
        note.isOverdue ? Theme.Accent.danger
        : note.isDueToday ? Theme.Accent.warning
        : Theme.Ink.secondary
    }

    // MARK: - Редактор

    @ViewBuilder
    private var editor: some View {
        if let id = selectedID, let note = selected {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                metaBar(note)

                TextEditor(text: Binding(
                    get: { store.text(for: id) },
                    set: { store.setText($0, for: id) }
                ))
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.Ink.primary)
                .tint(Theme.Accent.tint)
                .padding(8)
                .background(Theme.Surface.base, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Stroke.hairline, lineWidth: 1))

                if note.todo.total > 0 { checklist(note) }

                HStack(spacing: 2) {
                    Text(note.stats)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                    IconButton(icon: "checklist", hint: "Добавить пункт списка") {
                        appendCheckbox(id)
                    }
                    IconButton(icon: "doc.on.doc", hint: "Скопировать текст") {
                        copy(store.text(for: id))
                    }
                    IconButton(icon: "square.and.arrow.up", hint: "Поделиться…") {
                        store.share(id)
                    }
                    IconButton(icon: "arrow.down.doc", hint: "Сохранить как .md") {
                        store.exportMarkdown(id)
                    }
                    IconButton(icon: note.isPinned ? "pin.slash" : "pin",
                               tint: note.isPinned ? Theme.Accent.pin : Theme.Ink.secondary,
                               hint: note.isPinned ? "Открепить" : "Закрепить") {
                        store.togglePin(id)
                    }
                    IconButton(icon: "trash", tint: Theme.Accent.danger.opacity(0.85),
                               hint: "Удалить заметку") { remove(id) }
                }
            }
        } else {
            EmptyState(icon: "square.and.pencil",
                       title: "Заметка не выбрана",
                       subtitle: "Выберите её слева или создайте новую",
                       actionTitle: "Новая заметка") { selectedID = store.addNote("").id }
        }
    }

    /// Цвет, срок и напоминание одной строкой над текстом
    private func metaBar(_ note: Note) -> some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(NoteColor.allCases) { c in
                    Button { store.setColor(c, for: note.id) } label: {
                        Circle()
                            .fill(c == .none ? Theme.Surface.field : c.tint)
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle().strokeBorder(note.color == c ? Color.white : .clear,
                                                      lineWidth: 1.6)
                            }
                            .overlay {
                                // «Без цвета» иначе неотличим от тёмной точки
                                if c == .none && note.color != c {
                                    Circle().strokeBorder(Theme.Stroke.outline, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(c.title)
                }
            }

            Divider().frame(height: 14).overlay(Theme.Stroke.hairline)

            dateControl(icon: "calendar", value: note.dueDate,
                        components: .date,
                        label: note.dueLabel ?? "Срок",
                        tint: note.isOverdue ? Theme.Accent.danger
                              : note.isDueToday ? Theme.Accent.warning : nil,
                        set: { store.setDue($0, for: note.id) },
                        preset: Calendar.current.startOfDay(for: Date()))

            dateControl(icon: note.reminderAt == nil ? "bell" : "bell.fill",
                        value: note.reminderAt,
                        components: [.date, .hourAndMinute],
                        label: note.reminderLabel ?? "Напомнить",
                        tint: note.reminderAt == nil ? nil : Theme.Accent.pin,
                        set: { store.setReminder($0, for: note.id) },
                        preset: Date().addingTimeInterval(60 * 30))

            Spacer(minLength: 0)

            if note.todo.total > 0 {
                HStack(spacing: Theme.Space.s) {
                    Text("\(note.todo.done)/\(note.todo.total)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Ink.secondary)
                    ProgressView(value: note.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 58)
                        .tint(note.isComplete ? Theme.Accent.success : Theme.Accent.tint)
                }
            }
        }
    }

    /// Пока даты нет — кнопка; как только есть — нативный date field и крестик
    @ViewBuilder
    private func dateControl(icon: String, value: Date?, components: DatePicker.Components,
                             label: String, tint: Color?, set: @escaping (Date?) -> Void,
                             preset: Date) -> some View {
        if let value {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: icon).font(.system(size: 11))
                DatePicker("", selection: Binding(get: { value }, set: { set($0) }),
                           displayedComponents: components)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .font(.system(size: 11))
                    .frame(width: components == .date ? 86 : 138)
                Button { set(nil) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Ink.tertiary)
                .help("Убрать")
            }
            .foregroundStyle(tint ?? Theme.Ink.secondary)
        } else {
            Button { set(preset) } label: {
                Label(label, systemImage: icon)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.Surface.field, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// Кликабельный чек-лист прямо под текстом: подзадачи с отступом
    private func checklist(_ note: Note) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(note.checklist) { item in
                    HStack(spacing: Theme.Space.s) {
                        Color.clear.frame(width: CGFloat(item.depth) * 14, height: 1)

                        Button { store.toggleItem(line: item.line, in: note.id) } label: {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .font(Theme.Icon.check)
                                .foregroundStyle(item.isDone ? Theme.Accent.success
                                                             : Theme.Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(item.isDone ? "Снять отметку" : "Отметить сделанным")

                        Text(item.text.isEmpty ? "Новая задача" : item.text)
                            .font(Theme.Font.caption)
                            .strikethrough(item.isDone, color: Theme.Ink.tertiary)
                            .foregroundStyle(item.isDone ? Theme.Ink.tertiary : Theme.Ink.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        IconButton(icon: "arrow.turn.down.right",
                                   tint: Theme.Ink.tertiary,
                                   hint: "Добавить подзадачу") {
                            store.addSubtask(after: item.line, in: note.id)
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .rowHighlight(selected: false, radius: 6)
                    .contextMenu {
                        Button("Подзадача") { store.addSubtask(after: item.line, in: note.id) }
                        Button("Удалить строку", role: .destructive) {
                            store.removeItem(line: item.line, in: note.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 112)
        .background(Theme.Surface.base, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    // MARK: - Хелперы

    private func shift(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    private func appendCheckbox(_ id: Note.ID) {
        let current = store.text(for: id)
        let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        store.setText(current + prefix + "- [ ] ", for: id)
    }

    private func createFromQuery() {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        selectedID = store.addNote(t).id
        query = ""
    }

    private func remove(_ id: Note.ID) {
        if selectedID == id { selectedID = nil }
        store.delete(id)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

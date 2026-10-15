import AppKit

/// Проверка чистой логики без UI: `./NotchNotes --selfcheck`
/// Падает на первом же расхождении — этого достаточно, чтобы поймать регрессии
/// в разборе заметок, эвристике кода и цикле помодоро.
enum SelfCheck {

    static func run() {
        checkNoteStats()
        checkChecklist()
        checkLegacyDecoding()
        checkTaskEditing()
        checkFiltersAndDates()
        checkTaskMarks()
        checkTaskEditor()
        checkReminders()
        checkClipboardHeuristics()
        checkPomodoroCycle()
        checkHotZone()
        checkDropZone()
        checkDropTarget()
        checkAmbientWings()
        print("✅ selfcheck ok")
    }

    /// Стор пишет на диск дебаунсом по main runloop, а --selfcheck выходит
    /// не запуская его — поэтому заметки пользователя проверки не трогают.
    private static func scratchStore() -> NotesStore {
        let store = NotesStore()
        store.notes = []
        return store
    }

    /// Вьюмодель без пользовательских заметок: иначе размер свёрнутой челки
    /// зависит от того, сколько задач у запустившего проверку.
    private static func scratchViewModel() -> NotchViewModel {
        let vm = NotchViewModel()
        vm.notes.notes = []
        vm.clipboard.isEnabled = false
        return vm
    }

    /// Разбор чекбоксов: отступ = вложенность, мусорные строки не считаются задачами
    private static func checkChecklist() {
        let note = Note(text: """
        Курсовая
        - [ ] собрать источники
          - [x] найти статьи
          - [ ] выписать цитаты
            - [ ] оформить сноски
        * [x] отправить научруку
        - [не чекбокс]
        """)

        let items = note.checklist
        assert(items.count == 5, "пунктов: \(items.count)")
        assert(items.map(\.depth) == [0, 1, 1, 2, 0], "вложенность: \(items.map(\.depth))")
        assert(items[0].line == 1 && items[4].line == 5, "строки: \(items.map(\.line))")
        assert(items[1].isDone && !items[2].isDone, "галочки разобраны неверно")
        assert(items[3].text == "оформить сноски", "текст: \(items[3].text)")
        assert(note.todo == (done: 2, total: 5), "счётчик: \(note.todo)")
        assert(note.openTasks.count == 3)
        assert(!note.isComplete)

        let done = Note(text: "- [x] раз\n- [x] два")
        assert(done.isComplete && done.progress == 1)

        let tagged = Note(text: "Лекция #матан, повторить #формулы. #1 не метка")
        assert(tagged.tags == ["матан", "формулы"], "метки: \(tagged.tags)")
    }

    /// Старые notes.json без цвета и сроков должны читаться, а не терять заметки
    private static func checkLegacyDecoding() {
        let legacy = """
        [{"id":"\(UUID().uuidString)","text":"старая заметка",
          "createdAt":700000000,"updatedAt":700000000,"isPinned":true}]
        """
        let notes = try? JSONDecoder().decode([Note].self, from: Data(legacy.utf8))
        assert(notes?.count == 1, "старый формат не прочитался")
        assert(notes?.first?.color == NoteColor.none && notes?.first?.dueDate == nil)
        assert(notes?.first?.isPinned == true)
    }

    /// Правки задач идут по номеру строки — важно, чтобы они не съезжали
    private static func checkTaskEditing() {
        let store = scratchStore()
        let note = store.addNote("План\n- [ ] прочитать\n- [ ] законспектировать")

        store.toggleItem(line: 1, in: note.id)
        assert(store.note(note.id)?.todo.done == 1 && store.note(note.id)?.todo.total == 2,
               "переключение чекбокса")
        store.toggleItem(line: 1, in: note.id)
        assert(store.note(note.id)?.todo.done == 0, "повторный клик снимает галочку")

        store.addSubtask(after: 1, in: note.id, text: "глава 3")
        let items = store.note(note.id)?.checklist ?? []
        assert(items.count == 3, "подзадача не добавилась: \(items.count)")
        assert(items[1].depth == 1 && items[1].text == "глава 3",
               "подзадача должна быть на уровень глубже: \(items[1])")
        assert(items[2].depth == 0, "соседняя задача не должна менять уровень")

        store.removeItem(line: 2, in: note.id)
        assert(store.note(note.id)?.checklist.count == 2)

        store.addTask("сдать работу", to: note.id)
        assert(store.note(note.id)?.checklist.last?.text == "сдать работу")

        let inbox = store.inbox()
        assert(store.inbox().id == inbox.id, "инбокс должен быть один")
        assert(store.openTaskCount == store.notes.reduce(0) { $0 + $1.openTasks.count })
    }

    private static func checkFiltersAndDates() {
        let store = scratchStore()
        let cal = Calendar.current

        let overdue = store.addNote("Долг #учёба\n- [ ] сдать лабу")
        store.setDue(cal.date(byAdding: .day, value: -2, to: Date()), for: overdue.id)

        let today = store.addNote("Созвон\n- [ ] подготовить тезисы")
        store.setDue(Date(), for: today.id)

        let plain = store.addNote("Просто мысль")
        store.setColor(.purple, for: plain.id)

        assert(store.note(overdue.id)?.isOverdue == true, "просрочка не поймана")
        assert(store.note(today.id)?.isDueToday == true)
        assert(store.note(today.id)?.isOverdue == false, "сегодняшний срок ещё не просрочен")
        assert(store.overdueCount == 1, "просроченных: \(store.overdueCount)")

        assert(store.filtered("", filter: .tasks).count == 2, "в «Задачах» только заметки с чекбоксами")
        assert(store.filtered("", filter: .overdue).map(\.id) == [overdue.id])
        assert(store.filtered("", filter: .today).count == 2, "сегодня = сроки на сегодня + долги")
        assert(store.filtered("", filter: .all).first?.id == overdue.id,
               "ближний срок должен быть выше")
        assert(store.filtered("", tag: "учёба").map(\.id) == [overdue.id], "фильтр по метке")
        assert(store.allTags.contains("учёба"))
        assert(store.note(plain.id)?.color == .purple)

        // закрытые задачи гасят просрочку — заметка перестаёт «гореть»
        store.toggleItem(line: 1, in: overdue.id)
        assert(store.note(overdue.id)?.isOverdue == false, "выполненная заметка не просрочена")
    }

    /// Учёт поручений: метки Obsidian Tasks в строке, автодаты, сроки по задаче, CSV
    private static func checkTaskMarks() {
        let cal = Calendar.current
        let day = { (s: String) in Note.isoDay.date(from: s)! }
        let iso = { (d: Date) in Note.isoDay.string(from: d) }
        let today = cal.startOfDay(for: Date())

        // разбор меток: название чистое, всё служебное — в полях
        let parsed = Note(text: "- [ ] X #осн @Анна 🔼 ➕ 2026-10-15 📅 2026-10-20 #отчёты").checklist[0]
        assert(parsed.text == "X #отчёты", "название: \(parsed.text)")
        assert(parsed.kind == .main && parsed.from == "Анна" && parsed.priority == .medium)
        assert(parsed.createdAt == day("2026-10-15") && parsed.due == day("2026-10-20"))
        let done = Note(text: "- [x] SOP #доп ✅️ 2026-10-13 📅 2026-10-12").checklist[0]
        assert(done.kind == .extra && done.doneAt == day("2026-10-13") && done.isLate,
               "сдано позже срока — с опозданием")
        let plain = Note(text: "- [ ] просто 📅 не дата @ #осн,").checklist[0]
        assert(plain.text == "просто 📅 не дата @ #осн," && plain.kind == .other && plain.due == nil,
               "старые строки без меток не меняются: \(plain.text)")

        // срок: свой 📅 важнее срока заметки, без своего — наследуется
        var note = Note(text: "- [ ] своё 📅 2030-01-01\n- [ ] общее")
        note.dueDate = day("2029-05-05")
        assert(note.checklist[0].due == day("2030-01-01") && note.checklist[1].due == day("2029-05-05"))

        // просрочка по задаче, даже если у заметки срока нет
        let store = scratchStore()
        let yesterday = iso(cal.date(byAdding: .day, value: -1, to: today)!)
        let tomorrow = iso(cal.date(byAdding: .day, value: 1, to: today)!)
        let n = store.addNote("""
        Работа
        - [ ] горит 🔽 📅 \(yesterday)
        - [ ] важное ⏫ 📅 \(tomorrow) #осн
        - [ ] сегодня 📅 \(iso(today))
        - [ ] когда-нибудь
        - [x] старое без даты
        - [x] давно ✅ 2000-01-01
        """)
        assert(store.note(n.id)?.dueDate == nil && store.note(n.id)?.isOverdue == true)
        assert(store.tasks(.overdue).map(\.item.text) == ["горит"])
        assert(store.tasks(.open).map(\.item.text) == ["горит", "сегодня", "важное", "когда-нибудь"],
               "сортировка: \(store.tasks(.open).map(\.item.text))")
        assert(store.tasks(.today).count == 2, "сегодня = срок сегодня + просрочка")
        assert(store.tasks(.done).map(\.item.text) == ["старое без даты"], "сделано — за 30 дней")
        assert(store.tasks(.open, kind: .main).map(\.item.text) == ["важное"])

        // автодаты: ✅ при отметке, пропадает при снятии
        store.toggleItem(line: 4, in: n.id)
        let line = { store.text(for: n.id).components(separatedBy: "\n")[4] }
        assert(line() == "- [x] когда-нибудь ✅ \(iso(today))", "строка: \(line())")
        assert(store.taskSummary() == "Активных 3 · просрочено 1 · сдано за неделю 1",
               "сводка: \(store.taskSummary())")
        store.toggleItem(line: 4, in: n.id)
        assert(line() == "- [ ] когда-нибудь", "дата сдачи не снялась: \(line())")

        store.toggleItem(line: 2, in: n.id)   // важное — сдано до срока
        assert(store.taskSummary().hasSuffix("в срок 100%"), store.taskSummary())

        // быстрый ввод: короткие сроки → 📅 ГГГГ-ММ-ДД, ➕ сегодня, поля в конце
        let wed = day("2026-10-14")
        assert(NotesStore.normalizeTask("Отчёт 📅 20.10 #осн @руководитель", today: wed)
               == "Отчёт #осн @руководитель ➕ 2026-10-14 📅 2026-10-20")
        assert(NotesStore.normalizeTask("!пт звонок 🔼", today: wed)
               == "звонок 🔼 ➕ 2026-10-14 📅 2026-10-16")
        assert(NotesStore.normalizeTask("сдать !завтра", today: wed).hasSuffix("📅 2026-10-15"))
        assert(NotesStore.normalizeTask("сдать !ср", today: wed).hasSuffix("📅 2026-10-14"))
        assert(NotesStore.normalizeTask("сдать 📅 01.02", today: wed).hasSuffix("📅 2027-02-01"),
               "прошедшая дата без года — следующий год")
        assert(NotesStore.normalizeTask("!важно 31.02", today: wed) == "!важно 31.02 ➕ 2026-10-14")
        store.addTask("из инбокса @Олег", to: n.id)
        let added = store.note(n.id)!.checklist.last!
        assert(added.text == "из инбокса" && added.from == "Олег" && added.createdAt == today)

        // CSV: BOM, «;», даты ДД.ММ.ГГГГ, защита от формул и кавычки
        let csvNote = Note(text: "Отдел\n- [x] =SUM; \"итог\" #осн @Анна ➕ 2026-10-10 📅 2026-10-12 ✅ 2026-10-13")
        let csv = NotesStore.tasksCSV(csvNote.checklist.map { TaskEntry(note: csvNote, item: $0) })
        assert(csv.starts(with: [0xEF, 0xBB, 0xBF]), "нет BOM")
        let rows = String(decoding: csv.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
        assert(rows[0] == "Получено;Задача;Тип;От кого;Приоритет;Срок;Статус;Сдано;Заметка")
        assert(rows[1] == "10.10.2026;\"'=SUM; \"\"итог\"\"\";Основная;Анна;;12.10.2026;сдано с опозданием;13.10.2026;Отдел",
               "строка CSV: \(rows[1])")
    }

    /// Редактор: правка полей, подзадачи под родителем, удаление с отменой, перенос срока
    private static func checkTaskEditor() {
        let cal = Calendar.current
        let iso = { (d: Date) in Note.isoDay.string(from: d) }
        let today = cal.startOfDay(for: Date())
        let store = scratchStore()
        let n = store.addNote("""
        Проект
        - [ ] Отчёт @Анна
          - [ ] собрать цифры
            - [x] выгрузка
          - [ ] свести таблицу @Олег
        - [ ] Второе
        """)
        let lines = { store.text(for: n.id).components(separatedBy: "\n") }

        // иерархия: подзадачи собраны под корнем, родитель знает прогресс
        let tree = store.tasks(.open)
        assert(tree.map(\.item.text) == ["Отчёт", "Второе"], "корни: \(tree.map(\.item.text))")
        assert(tree[0].children.map(\.text) == ["собрать цифры", "выгрузка", "свести таблицу"])
        assert(tree[0].progress == (1, 3))
        assert(store.note(n.id)!.checklist[2].parent == 2, "родитель подподзадачи")

        // фильтры: автор подзадачи находит корень, поиск — по названию
        assert(store.tasks(.open, from: "олег").map(\.item.text) == ["Отчёт"])
        assert(store.tasks(.open, query: "втор").map(\.item.text) == ["Второе"])
        assert(store.taskAuthors.sorted() == ["Анна", "Олег"])

        // правка полей пересобирает строку, отступ и галочка на месте
        store.updateTask(line: 2, in: n.id) {
            $0.kind = .main; $0.priority = .high; $0.from = "Иван Петров"
            $0.due = cal.date(byAdding: .day, value: -1, to: today)
        }
        assert(lines()[2] == "  - [ ] собрать цифры #осн @Иван_Петров ⏫ 📅 \(iso(cal.date(byAdding: .day, value: -1, to: today)!))",
               "строка: \(lines()[2])")
        assert(store.tasks(.overdue).map(\.item.text) == ["Отчёт"], "просрочка подзадачи поднимает корень")

        // перенос просроченного считаем от сегодня
        store.shiftDue(line: 2, in: n.id, days: 1)
        assert(store.note(n.id)!.checklist[1].fields.due == cal.date(byAdding: .day, value: 1, to: today))

        // новая подзадача встаёт в конец блока и разбирается как быстрый ввод
        store.addSubtask(after: 1, in: n.id, text: "сверить !завтра")
        assert(lines()[5].hasPrefix("  - [ ] сверить ➕ \(iso(today)) 📅"), "подзадача: \(lines()[5])")
        assert(lines()[6] == "- [ ] Второе")

        // удаление уносит подзадачи, отмена возвращает всё как было
        let before = store.text(for: n.id)
        store.removeTask(line: 1, in: n.id)
        assert(lines() == ["Проект", "- [ ] Второе"], "удаление блока: \(lines())")
        assert(store.lastRemoved?.title == "Отчёт")
        store.undoRemove()
        assert(store.text(for: n.id) == before && store.lastRemoved == nil, "отмена удаления")
    }

    private static func checkReminders() {
        let store = scratchStore()
        let note = store.addNote("Позвонить научруку")
        store.setReminder(Date().addingTimeInterval(-60), for: note.id)
        let future = store.addNote("Позже")
        store.setReminder(Date().addingTimeInterval(3600), for: future.id)

        let center = ReminderCenter(store: store)
        center.check()
        assert(store.note(note.id)?.reminderAt == nil, "сработавшее напоминание должно гаснуть")
        assert(store.note(future.id)?.reminderAt != nil, "будущее напоминание не трогаем")
        assert(center.fired?.id == note.id, "не сообщили, по какой заметке звенело")
    }

    /// Приём файлов: мишень должна вырастать заранее, а слой — принимать
    /// и прямые file-url, и «обещанные» файлы (Почта, Safari, Фото).
    /// Мишень для броска показываем только когда файл поднесли к челке
    private static func checkDropZone() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let zone = NotchGeometry.dropZone(screen: screen, notchWidth: 220)

        assert(zone.maxY == screen.maxY, "зона приёма прижата к верхней кромке")
        assert(zone.contains(CGPoint(x: screen.midX, y: screen.maxY - 10)),
               "прямо над челкой файл принимаем")
        assert(zone.contains(CGPoint(x: screen.midX - 140, y: screen.maxY - 40)),
               "и рядом с ней — попасть точно в вырез нереально")
        assert(!zone.contains(CGPoint(x: screen.midX, y: screen.midY)),
               "в середине экрана мишени быть не должно")
        assert(!zone.contains(CGPoint(x: 40, y: screen.maxY - 10)),
               "у левого края экрана — тоже не должно")
        assert(zone.width < screen.width, "зона не может съесть весь экран: \(zone.width)")

        // Зона срабатывания должна быть соразмерна тому, что вырастает на экране:
        // если она намного шире мишени, та раскрывается, когда курсор ещё далеко.
        let vm = scratchViewModel()
        vm.notchSize = CGSize(width: 220, height: 32)
        vm.isSystemDragging = true
        assert(zone.width <= vm.collapsedSize.width * 2,
               "зона \(zone.width) слишком широка для мишени \(vm.collapsedSize.width)")
    }

    private static func checkDropTarget() {
        let vm = scratchViewModel()
        vm.notchSize = CGSize(width: 220, height: 38)

        let idle = vm.collapsedSize
        assert(idle == CGSize(width: 220, height: 38), "в покое челка своего размера: \(idle)")

        vm.isSystemDragging = true
        let target = vm.collapsedSize
        assert(target.width > idle.width, "мишень шире челки — иначе не прицелиться: \(target)")
        assert(target.height == vm.notchSize.height,
               "мишень не может быть выше выреза, иначе она выезжает под челку: \(target)")

        vm.isSystemDragging = false
        vm.isDropTargeted = true
        assert(vm.collapsedSize == target, "наведение файла не должно менять размер окна — "
               + "ресайз под курсором роняет сессию перетаскивания")

        vm.isDropTargeted = false
        vm.droppedCount = 3
        let confirm = vm.collapsedSize
        assert(confirm.width > idle.width && confirm.width < target.width,
               "подтверждение броска — полоска между покоем и мишенью: \(confirm)")
        assert(confirm.height == vm.notchSize.height,
               "подтверждение тоже держится внутри выреза: \(confirm)")
        vm.droppedCount = 0
        assert(vm.collapsedSize == idle, "после подтверждения челка возвращается в покой")

        // Ни одно свёрнутое состояние не должно расти вниз: всё, что ниже выреза,
        // читается как чёрная плашка на обоях.
        for (drag, targeted, dropped) in [(true, false, 0), (false, true, 0),
                                          (true, true, 0), (false, false, 3)] {
            vm.isSystemDragging = drag
            vm.isDropTargeted = targeted
            vm.droppedCount = dropped
            assert(vm.collapsedSize.height == vm.notchSize.height,
                   "состояние drag=\(drag) targeted=\(targeted) dropped=\(dropped) "
                   + "выше выреза: \(vm.collapsedSize)")
        }
        vm.isSystemDragging = false
        vm.isDropTargeted = false
        vm.droppedCount = 0

        for (n, word) in [(1, "файл"), (2, "файла"), (5, "файлов"), (11, "файлов"),
                          (21, "файл"), (114, "файлов"), (102, "файла")] {
            assert(filesWord(n) == word, "\(n) \(filesWord(n)) — ожидали «\(word)»")
        }

        let types = DropCatcher(frame: .zero).registeredDraggedTypes.map(\.rawValue)
        assert(types.contains("public.file-url"), "нет приёма файлов: \(types)")
        assert(types.contains(where: { $0.contains("promise") }), "нет приёма обещанных файлов: \(types)")

        vm.clipboard.isEnabled = false
        vm.timer.pause()
    }

    /// Мини-состояния свёрнутой челки: приоритет значков, ширина крыльев,
    /// и главное — что ни одно из них не вылезает за пределы выреза по высоте.
    private static func checkAmbientWings() {
        let vm = scratchViewModel()
        vm.notchSize = CGSize(width: 220, height: 32)

        assert(vm.leftBadge == nil && vm.rightBadge == nil,
               "на пустом сторе крылья пустые")
        assert(vm.collapsedSize == vm.notchSize,
               "без значков челка ровно по вырезу: \(vm.collapsedSize)")

        // Левое крыло: просрочка важнее счётчика задач — она требует действия
        let due = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        vm.notes.notes = [Note(text: "- [ ] сдать отчёт", dueDate: due),
                          Note(text: "- [ ] купить кофе")]
        assert(vm.notes.openTaskCount == 2, "две открытые задачи")
        assert(vm.leftBadge == .overdue(1),
               "при просрочке слева горит она, а не счётчик задач: \(String(describing: vm.leftBadge))")

        vm.notes.notes = [Note(text: "- [ ] купить кофе")]
        assert(vm.leftBadge == .tasks(1),
               "без просрочки слева счётчик открытых задач: \(String(describing: vm.leftBadge))")

        // Правое крыло: вспышка перебивает таймер, пока висит
        vm.timer.setMinutes(5)
        vm.timer.start()
        assert(vm.rightBadge == .timer, "идущий таймер занимает правое крыло")
        vm.flash = .copied
        assert(vm.rightBadge == .flash(.copied),
               "вспышка о копировании перебивает таймер: \(String(describing: vm.rightBadge))")
        assert(vm.tab(for: .right) == .clipboard, "клик по вспышке ведёт в буфер")
        vm.flash = nil
        assert(vm.tab(for: .right) == .timer, "клик по таймеру ведёт во вкладку таймера")
        assert(vm.tab(for: .left) == .tasks, "клик по левому крылу ведёт в задачи")

        // Крылья симметричны: ширину задаёт большее содержимое, но занимают
        // её оба. Иначе HStack сдвинет резерв под вырез и нарисованная челка
        // уедет вбок от физической — ровно то, что ломалось в одностороннем виде.
        let timerWidth = vm.wingWidth
        vm.hoveredWing = .left
        assert(vm.wingWidth > timerWidth, "под курсором крыло раскрывается подписью")
        vm.hoveredWing = nil
        assert(vm.wingWidth == timerWidth, "курсор ушёл — крыло вернулось к прежней ширине")
        assert(vm.collapsedSize.width == 220 + 2 * timerWidth,
               "растём на удвоенное крыло: \(vm.collapsedSize)")

        // Главное: при значке ТОЛЬКО с одной стороны крылья всё равно равны,
        // поэтому вырез остаётся ровно по центру окна.
        vm.timer.pause()
        vm.timer.reset()
        vm.flash = nil
        vm.notes.notes = [Note(text: "- [ ] одно дело")]
        assert(vm.leftBadge != nil && vm.rightBadge == nil, "значок только слева")
        let counterWidth = vm.wingWidth
        assert(counterWidth > 0, "одинокий счётчик задаёт ширину обоим крыльям")
        assert(vm.collapsedSize.width == 220 + 2 * counterWidth,
               "при одном значке челка симметрична: \(vm.collapsedSize)")
        assert(!vm.hasBadge(.right), "пустое крыло не ловит курсор и клик")
        assert(vm.hasBadge(.left), "крыло со значком интерактивно")

        vm.notes.notes = []
        vm.flash = .copied
        assert(vm.leftBadge == nil && vm.rightBadge != nil, "значок только справа")
        assert(vm.collapsedSize.width == 220 + 2 * vm.wingWidth,
               "зеркальный случай тоже симметричен: \(vm.collapsedSize)")
        assert(!vm.hasBadge(.left), "пустое левое крыло неинтерактивно")

        // Регрессия: вспышка рисуется развёрнутой ВСЕГДА, без наведения. Раньше
        // крыло всё равно брало ширину голого счётчика, и «скопировано» резало
        // посреди буквы. Ширина обязана вмещать подпись целиком.
        assert(vm.wingWidth > counterWidth,
               "крыло вспышки шире счётчика — иначе подпись обрежется: \(vm.wingWidth)")
        // Иконки в значке больше нет — под текст остаются только отступы крыла.
        assert(vm.wingWidth >= 55 + NotchViewModel.wingInnerPadding,
               "в крыло вспышки не помещается слово «скопировано»: \(vm.wingWidth)")

        // Потолок: даже самая длинная подпись не превращает челку в плашку
        vm.flash = .taskDone(0)          // «всё готово», самая длинная строка
        assert(vm.wingWidth <= vm.maxExpandedWingWidth,
               "раскрытое крыло пробило потолок: \(vm.wingWidth)")
        vm.flash = nil

        // Пассивное крыло — узкая кайма: подписи нет, потолок ниже.
        vm.notes.notes = [Note(text: "- [ ] дело")]
        vm.hoveredWing = nil
        assert(vm.wingWidth <= vm.maxWingWidth,
               "пассивное крыло шире каймы: \(vm.wingWidth)")

        // Часовой таймер («1:00:00») шире обычного mm:ss. Значение обрезать
        // нельзя — оно и есть весь смысл значка, поэтому потолок обязан его
        // вместить, а не упереться в себя.
        vm.notes.notes = []
        vm.timer.setMinutes(90)
        vm.timer.start()
        assert(vm.timer.formatted.count == 7, "ожидали h:mm:ss: \(vm.timer.formatted)")
        assert(vm.wingWidth < vm.maxWingWidth,
               "часовой таймер упёрся в потолок и обрежется: \(vm.wingWidth)")
        vm.timer.pause()
        vm.timer.reset()
        vm.hoveredWing = .left
        assert(vm.wingWidth <= vm.maxExpandedWingWidth,
               "раскрытое крыло пробило потолок: \(vm.wingWidth)")
        vm.hoveredWing = nil
        vm.notes.notes = []
        vm.flash = .copied

        // Ни одно ambient-состояние не растёт вниз — под вырезом только обои,
        // и ни одно не делает крылья разными.
        for (left, right, hover) in [(true, true, nil as NotchViewModel.Wing?),
                                     (true, false, .left), (false, true, .right),
                                     (true, false, .right), (false, false, nil),
                                     (true, true, .right)] {
            vm.notes.notes = left ? [Note(text: "- [ ] дело")] : []
            vm.flash = right ? .taskDone(2) : nil
            vm.hoveredWing = hover
            let size = vm.collapsedSize
            let state = "left=\(left) right=\(right) hover=\(String(describing: hover))"
            assert(size.height == vm.notchSize.height, "ambient \(state) выше выреза: \(size)")
            assert(size.width >= vm.notchSize.width, "ambient \(state) уже выреза: \(size)")
            // Симметрия = целое число крыльев с каждой стороны
            assert((size.width - vm.notchSize.width)
                       .truncatingRemainder(dividingBy: 2) == 0,
                   "ambient \(state) несимметричен, вырез съедет: \(size)")
        }

        vm.hoveredWing = nil
        vm.flash = nil
        vm.timer.pause()
    }

    private static func checkNoteStats() {
        let note = Note(text: "План\n- [x] прочитать главу\n- [ ] решить задачи\n- [ ] конспект")
        assert(note.title == "План", "заголовок берётся из первой строки")
        assert(note.todo == (done: 1, total: 3), "чекбоксы: \(note.todo)")
        assert(note.wordCount == 14, "слов: \(note.wordCount)")

        let empty = Note(text: "")
        assert(empty.todo.total == 0)
        assert(empty.title == "Без названия")
    }

    private static func checkClipboardHeuristics() {
        typealias Item = ClipboardStore.Item

        let code = Item(text: "func hi() {\n    return 1;\n}")
        assert(code.isCode, "многострочный Swift должен опознаваться как код")
        assert(code.icon == "chevron.left.forwardslash.chevron.right")

        let prose = Item(text: "Просто заметка\nвторая строка")
        assert(!prose.isCode, "обычный текст не код")

        let link = Item(text: " https://example.com ")
        assert(link.isLink && link.icon == "link")

        let image = Item(text: "Изображение 100×50", imageFile: "a.png")
        assert(image.isImage && image.icon == "photo")
        assert(!image.isCode, "картинка не может быть кодом")
    }

    private static func checkPomodoroCycle() {
        let t = TimerModel()
        t.pomodoroEnabled = true
        t.setMinutes(25)
        assert(t.phase == .work)

        // 4 рабочих отрезка: перерыв, перерыв, перерыв, длинный перерыв
        let expected: [TimerModel.Phase] = [.shortBreak, .work, .shortBreak, .work,
                                            .shortBreak, .work, .longBreak, .work]
        for want in expected {
            t.forceFinishForTesting()
            t.advancePhase()
            assert(t.phase == want, "ожидали \(want), получили \(t.phase)")
        }
        assert(t.completedCycles == 4, "циклов: \(t.completedCycles)")

        t.resetCycles()
        assert(t.completedCycles == 0 && t.phase == .work)
        assert(t.total == 25 * 60, "после сброса возвращаемся к рабочей длительности")
        t.pause()
    }

    private static func checkHotZone() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 220, height: 38)
        let zone = NSRect(x: screen.midX - size.width / 2,
                          y: screen.maxY - size.height,
                          width: size.width, height: size.height)
        assert(zone.maxY == screen.maxY, "зона наведения прижата к верхней кромке")
        assert(zone.midX == screen.midX, "и отцентрована")
        assert(!zone.contains(CGPoint(x: screen.midX, y: screen.maxY - size.height - 1)),
               "чуть ниже челки наведение уже не считается")
    }
}

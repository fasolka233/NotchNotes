import AppKit
import SwiftUI
import Combine
import CoreGraphics
import Carbon.HIToolbox

final class NotchController {

    let vm = NotchViewModel()
    /// Шестерёнка в панели: окно настроек живёт в AppDelegate
    var onSettings: (() -> Void)?

    private var panel: NotchPanel!
    private var hoverView: HoverView!
    private var dropCatcher: DropCatcher?
    private let dragWatcher = DragWatcher()
    private var isDragActive = false
    /// Защёлка от пере-входа в `applyFrame` из прохода раскладки (см. там же)
    private var isApplyingFrame = false
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var bag = Set<AnyCancellable>()

    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var confirmWork: DispatchWorkItem?

    /// Курсор должен «постоять» на челке — иначе раскрывается от случайного проезда мышью
    private let openDelay: TimeInterval = 0.35
    private let closeDelay: TimeInterval = 0.28
    private let animDuration: TimeInterval = 0.36

    init() {
        buildPanel()
        installMouseMonitor()
        installKeyMonitor()
        observeKeyState()
        observeAmbient()
        observeSystemDrag()
        observeReminders()
        observeFlashes()
        observeWingHover()
    }

    deinit {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Сборка

    private func buildPanel() {
        guard let screen = NotchGeometry.targetScreen else { return }
        vm.notchSize = NotchGeometry.notchSize(for: screen)

        panel = NotchPanel(
            contentRect: NotchGeometry.frame(for: screen, size: vm.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Окно с картинкой перетаскивания живёт на уровне 500. Всё, что выше
        // (.screenSaver = 1000, CGShieldingWindowLevel = 2147483628), для системы
        // перестаёт быть обычной целью броска. Держимся сразу над меню-баром (25):
        // челку рисуем поверх него, а перетаскивание идёт по штатному пути.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close(force: true) }

        hoverView = HoverView(frame: .zero)
        hoverView.onEnter = { [weak self] in self?.scheduleOpen() }
        hoverView.onExit  = { [weak self] in self?.scheduleClose() }
        hoverView.hotRect = { [weak self] in self?.hotRectInView ?? .zero }

        let host = NSHostingView(rootView: NotchView(
            vm: vm,
            onClose: { [weak self] in self?.close(force: true) },
            onOpenTab: { [weak self] tab in self?.open(activate: true, tab: tab) },
            onSettings: { [weak self] in self?.onSettings?() }
        ))
        // Размер окна задаёт только applyFrame. По умолчанию хост вешает на окно
        // min/max/intrinsic из SwiftUI: пока крыло таймера уже выросло, а окно
        // ещё нет, ограничения спорят с рамкой, и на macOS 26 каждый сдвиг хоста
        // (safe area corner insets) просит новый проход Update Constraints —
        // бесконечно, до исключения в `_postWindowNeedsUpdateConstraints`.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(host)

        // Слой приёма файлов кладём ПОВЕРХ хоста: иначе NSHostingView
        // забирает перетаскивание себе и до нас оно не доходит.
        let catcher = DropCatcher(frame: .zero)
        catcher.translatesAutoresizingMaskIntoConstraints = false
        catcher.promiseDirectory = NotchController.droppedFilesDirectory
        // принимаем только в нарисованную челку, а не в прозрачные поля окна
        catcher.dropRect = { [weak self] in self?.hotRectInView ?? .zero }
        hoverView.addSubview(catcher, positioned: .above, relativeTo: host)
        dropCatcher = catcher

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor),
            host.topAnchor.constraint(equalTo: hoverView.topAnchor),
            host.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor),

            catcher.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: hoverView.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor)
        ])

        catcher.onDragEnter = { [weak self] count in
            guard let self else { return }
            // draggingUpdated зовёт это на каждый тик — состояние меняем один раз,
            // иначе пружина перезапускается каждый кадр и мишень дрожит
            guard !self.vm.isDropTargeted else { return }
            self.isDragActive = true
            self.openWork?.cancel(); self.closeWork?.cancel()
            self.vm.dragItemCount = count
            self.vm.select(.shelf)
            // Панель НЕ раскрываем: смена размера окна прямо в draggingEntered
            // роняет сессию перетаскивания. Раскроемся уже после броска.
            withAnimation(Theme.motion(.spring(response: 0.28, dampingFraction: 0.85))) {
                self.vm.isDropTargeted = true
            }
        }
        catcher.onDragExit = { [weak self] in
            guard let self, self.vm.isDropTargeted || self.isDragActive else { return }
            self.isDragActive = false
            withAnimation(Theme.motion(.easeOut(duration: 0.16))) {
                self.vm.isDropTargeted = false
            }
            self.vm.dragItemCount = 0
            self.updateCatcher()
        }
        catcher.onFilesDropped = { [weak self] urls in self?.handleDrop(urls) }

        panel.contentView = hoverView
        applyFrame(animated: false)
        panel.orderFrontRegardless()
    }

    private func handleDrop(_ urls: [URL]) {
        isDragActive = false
        vm.isDropTargeted = false
        vm.dragItemCount = 0
        vm.shelf.add(urls: urls)
        vm.select(.shelf)   // откроют челку — сразу увидят полку
        confirmDrop(urls.count)
        updateCatcher()
    }

    /// Раскрывать панель 680×350 поверх чужого окна сразу после броска — грубо:
    /// файл кидают, не отрываясь от работы. Показываем секунду подтверждения,
    /// а полку открывают уже сами, когда она нужна.
    private func confirmDrop(_ count: Int) {
        confirmWork?.cancel()
        guard count > 0 else { return }

        withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.82))) {
            vm.droppedCount += count
        }
        resizeCollapsed()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(Theme.motion(.easeOut(duration: 0.22))) { self.vm.droppedCount = 0 }
            self.resizeCollapsed()
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: work)
    }

    /// Запасная мишень для броска: в иконку меню-бара попасть проще, чем в челку,
    /// и она не зависит ни от уровня окна, ни от определения перетаскивания.
    func attachDropTarget(to view: NSView, onClick: (() -> Void)? = nil) {
        let catcher = DropCatcher(frame: view.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.promiseDirectory = NotchController.droppedFilesDirectory
        catcher.onDragEnter = { [weak self] count in
            self?.vm.dragItemCount = count
            self?.vm.select(.shelf)
        }
        catcher.onFilesDropped = { [weak self] urls in self?.handleDrop(urls) }
        catcher.onMouseDown = onClick
        view.addSubview(catcher)
    }

    /// Файлы, перетащенные «обещанием» (из Почты, Safari, Фото), нужно куда-то записать
    static var droppedFilesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotes/dropped", isDirectory: true)
    }

    /// Поверх раскрытой панели слой мешал бы кликам, поэтому он живёт только
    /// на свёрнутой челке — и на всё время активного перетаскивания.
    private func updateCatcher() {
        dropCatcher?.isHidden = vm.isOpen && !isDragActive
    }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if !self.panel.isKeyWindow { self.panel.makeKeyAndOrderFront(nil) }
            return event
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel, self.vm.isOpen else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// ⌘1–5, ⌘F, ⌘N работают всегда. Стрелки — пока не пишут многострочный текст.
    /// Пробел и ⏎ — только когда фокуса в поле нет или поле пустое: в пустом поле
    /// они ничего не значат, а иначе пришлось бы сначала щёлкать мимо поля.
    /// Коды клавиш, а не символы: на русской раскладке ⌘F приходит как «⌘А».
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(e.keyCode)
        let send = { (c: KeyCommand) in KeyCommand.handlers[self.vm.tab]?(c) ?? false }

        if mods == .command {
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
            if let i = digits.firstIndex(of: code), NotchTab.allCases.indices.contains(i) {
                vm.select(NotchTab.allCases[i])
                return true
            }
            if code == kVK_ANSI_F { return send(.find) }
            if code == kVK_ANSI_N { return send(.new) }
            return false
        }
        guard mods.isEmpty || mods == .shift else { return false }

        let text = panel.firstResponder as? NSTextView
        let multiline = text.map { !$0.isFieldEditor } ?? false
        let idle = text == nil || (text!.isFieldEditor && text!.string.isEmpty)
        switch code {
        case kVK_UpArrow where !multiline && mods.isEmpty:   return send(.up)
        case kVK_DownArrow where !multiline && mods.isEmpty: return send(.down)
        case kVK_Return where idle, kVK_ANSI_KeypadEnter where idle: return send(.open)
        case kVK_Space where idle && mods.isEmpty:          return send(.toggle)
        default: return false
        }
    }

    private func observeKeyState() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.scheduleClose() }
    }

    /// Свёрнутая челка меняет размер при таймере, перетаскивании, наведении на
    /// крыло и вспышках. Слушать каждый из этих флагов по отдельности бесполезно:
    /// на окно влияет только итоговый `collapsedSize` — его и наблюдаем, а
    /// `removeDuplicates` гасит тики таймера, которые ширину не меняют.
    private func observeAmbient() {
        vm.objectWillChange
            // DispatchQueue, а не RunLoop: RunLoop.main доставляет в том числе
            // внутри коммита CATransaction, то есть прямо посреди прохода
            // раскладки — а именно оттуда setFrame и роняет AppKit.
            .receive(on: DispatchQueue.main)    // objectWillChange — размер ещё старый
            .map { [weak self] in self?.vm.collapsedSize ?? .zero }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.vm.isOpen else { return }
                self.resizeCollapsed()
            }
            .store(in: &bag)
    }

    /// Вспышки в правом крыле: подтверждаем то, что пользователь только что
    /// сделал в другом приложении, не раскрывая панель поверх его работы.
    private func observeFlashes() {
        vm.clipboard.$items
            .map(\.first?.id)
            .removeDuplicates()
            .dropFirst()                        // при старте не вспыхиваем историей
            .receive(on: RunLoop.main)
            .sink { [weak self] id in
                guard let self, id != nil, !self.vm.isOpen else { return }
                self.vm.showFlash(.copied)
            }
            .store(in: &bag)

        vm.notes.$notes
            .map { $0.reduce(0) { $0 + $1.openTasks.count } }
            .removeDuplicates()
            .scan((prev: Int?.none, now: 0)) { acc, now in (acc.now, now) }
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, let prev = change.prev, change.now < prev else { return }
                self.vm.showFlash(.taskDone(change.now))
            }
            .store(in: &bag)
    }

    /// Растём мгновенно и без анимации рамки: анимация окна расходится с пружиной
    /// SwiftUI внутри (отсюда «кривое» раскрытие), а пока рамка едет, бросок
    /// приходится на ещё не доехавший край окна и уходит мимо.
    /// Сжимаемся с задержкой — чтобы контент успел уехать до обрезки окна.
    private func resizeCollapsed() {
        shrinkWork?.cancel()
        guard let screen = NotchGeometry.targetScreen else { return }
        let target = NotchGeometry.frame(for: screen, size: vm.windowSize)

        if target.width >= panel.frame.width {
            applyFrame(animated: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.vm.isOpen else { return }
            self.applyFrame(animated: false)
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + animDuration, execute: work)
    }

    /// Сработавшее напоминание или клик по баннеру раскрывает панель там, куда звали.
    /// Ширину под просрочку менять здесь не нужно — за размер отвечает
    /// один общий наблюдатель `collapsedSize` в `observeAmbient()`.
    private func observeReminders() {
        vm.reminders.$target
            .dropFirst()                      // при старте не дёргаем панель ретроспективой
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] target in
                guard let self else { return }
                switch target {
                case .note(let id):
                    self.vm.selectedNoteID = id
                    self.open(activate: true, tab: .notes)
                case .tasks:
                    self.open(activate: true, tab: .tasks)
                }
            }
            .store(in: &bag)
    }

    /// Пока файл несут к челке — заранее подставляем крупную мишень
    /// Курсор ушёл с крыла на сам вырез — трекинг-область его уже «впустила»,
    /// второго mouseEntered не будет. Перезапускаем отсчёт раскрытия руками,
    /// иначе после чтения подписи челка перестаёт открываться по наведению.
    private func observeWingHover() {
        vm.$hoveredWing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] wing in
                guard let self, wing == nil, !self.vm.isOpen else { return }
                guard self.pointerInHotZone else { return }
                self.scheduleOpen()
            }
            .store(in: &bag)
    }

    private func observeSystemDrag() {
        dragWatcher.zone = { [weak self] in
            guard let self, let screen = NotchGeometry.targetScreen else { return .zero }
            return NotchGeometry.dropZone(screen: screen.frame, notchWidth: self.vm.notchSize.width)
        }
        dragWatcher.onChange = { [weak self] dragging in
            guard let self else { return }
            self.openWork?.cancel()
            withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.82))) {
                self.vm.isSystemDragging = dragging
            }
            if !dragging { self.vm.isDropTargeted = false }
        }
        dragWatcher.start()
    }

    // MARK: - Зона наведения

    /// Прямоугольник самой челки внутри окна (окно шире на поля под тень/«ушки»)
    private var hotRectInView: NSRect {
        let b = hoverView.bounds
        guard !vm.isOpen else { return b }
        let s = vm.collapsedSize
        return NSRect(x: ((b.width - s.width) / 2).rounded(),
                      y: b.maxY - s.height,
                      width: s.width,
                      height: s.height)
    }

    /// Та же зона в координатах экрана — для проверки «курсор ещё здесь?»
    private var pointerInHotZone: Bool {
        guard let screen = NotchGeometry.targetScreen else { return false }
        let s = vm.collapsedSize
        let zone = NSRect(x: screen.frame.midX - s.width / 2,
                          y: screen.frame.maxY - s.height,
                          width: s.width,
                          height: s.height)
        return zone.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func refreshTracking() {
        hoverView?.updateTrackingAreas()
    }

    // MARK: - Планировщик

    private func scheduleOpen() {
        closeWork?.cancel()
        guard !vm.isOpen else { return }
        // во время перетаскивания раскрытие только помешает: окно поменяет размер под курсором
        guard !vm.isSystemDragging else { return }
        let item = DispatchWorkItem { [weak self] in
            // курсор мог уже уехать — открываем только если он всё ещё на челке
            guard let self, self.pointerInHotZone else { return }
            // на крыле со значком раскрытие придержим: там курсор стоит,
            // чтобы прочитать подпись, а не чтобы открыть всю панель.
            // Раскрыть её оттуда можно кликом — он ведёт сразу в нужную вкладку.
            guard self.vm.hoveredWing == nil else { return }
            self.open()
        }
        openWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: item)
    }

    private func scheduleClose() {
        openWork?.cancel()
        guard vm.isOpen, !vm.isPinnedOpen, !vm.isDropTargeted else { return }
        let item = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: item)
    }

    // MARK: - Открыть / закрыть

    func open(activate: Bool = false, tab: NotchTab? = nil) {
        closeWork?.cancel()
        collapseWork?.cancel()
        shrinkWork?.cancel()
        if let tab { vm.tab = tab }

        vm.isOpen = true
        applyFrame(animated: false)
        panel.orderFrontRegardless()
        if activate { panel.makeKeyAndOrderFront(nil) }

        vm.isOpen = false
        withAnimation(Theme.motion(.spring(response: 0.34, dampingFraction: 0.84))) {
            vm.isOpen = true
        }
    }

    func close(force: Bool = false) {
        openWork?.cancel(); closeWork?.cancel()
        guard vm.isOpen else { return }
        // пока открыт системный шит «Поделиться» — панель не сворачиваем
        if SharePresenter.shared.isPresenting { return }
        if !force && (vm.isPinnedOpen || vm.isDropTargeted) { return }

        if panel.isKeyWindow {
            if !force { return }              // пользователь печатает
            relinquishKey()
        }
        if force { vm.isPinnedOpen = false }
        vm.isCapturing = false

        withAnimation(Theme.motion(.spring(response: 0.3, dampingFraction: 0.9))) {
            vm.isOpen = false
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.vm.isOpen else { return }
            self.applyFrame(animated: false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + animDuration, execute: work)
    }

    /// Быстрая запись: «Задачи» с курсором в поле ввода, Enter — и панель свернулась.
    /// Если вкладка уже на экране, фокус ставим отсюда; если только появляется —
    /// его поставит сама панель по `isCapturing`.
    func capture() {
        vm.isCapturing = true
        open(activate: true, tab: .tasks)
        DispatchQueue.main.async { _ = KeyCommand.handlers[.tasks]?(.new) }
    }

    func toggle(tab: NotchTab? = nil) {
        if vm.isOpen, tab == nil || tab == vm.tab {
            close(force: true)
        } else {
            open(activate: true, tab: tab)
        }
    }

    private func relinquishKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Геометрия

    private func applyFrame(animated: Bool) {
        guard let screen = NotchGeometry.targetScreen else { return }

        // Пере-вход убивает приложение. `setFrame(display: true)` синхронно гонит
        // проход раскладки: NSHostingView читает vm, публикует изменение,
        // `observeAmbient` зовёт resizeCollapsed → setFrame ПОВЕРХ незакрытого
        // прохода. AppKit ловит это в `_postWindowNeedsUpdateConstraints` и
        // бросает исключение, которое SwiftUI не ловит, — SIGTRAP.
        guard !isApplyingFrame else { return }
        isApplyingFrame = true
        defer { isApplyingFrame = false }

        // Записываем только при фактической смене: `notchSize` — @Published, и
        // безусловная запись публиковала объект на каждом кадре раскладки.
        let measured = NotchGeometry.notchSize(for: screen)
        if measured != vm.notchSize { vm.notchSize = measured }
        let target = NotchGeometry.frame(for: screen, size: vm.windowSize)

        // Кадр уже верный — незачем трогать окно и запускать ещё один проход.
        guard target != panel.frame else {
            refreshTracking()
            updateCatcher()
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        refreshTracking()
        updateCatcher()
    }

    func reposition() { applyFrame(animated: false) }
}

import AppKit

/// Замечает, что по системе тащат файлы — ещё до того, как курсор дошёл до челки.
///
/// Свёрнутая челка сама по себе мишень примерно 220×38 у самой кромки экрана,
/// попасть в неё файлом тяжело. Пока идёт перетаскивание, челка разворачивается
/// в широкую панель приёма — так делают Yoink и Dropzone.
///
/// Мониторы NSEvent для этого не годятся: во время сессии перетаскивания AppKit
/// крутит собственный цикл событий и глобальные мониторы не срабатывают вовсе.
/// Поэтому опрашиваем кнопку мыши и drag-пастборд по таймеру в режиме .common —
/// разрешений не требует, стоимость проверки нулевая.
///
/// Три условия, и все обязательны — иначе мишень выскакивала на каждый клик:
/// 1. пастборд перетаскивания сменился уже ПОСЛЕ нажатия кнопки (обычный клик его
///    не трогает, а старое содержимое живёт там до следующего переноса);
/// 2. курсор внутри зоны приёма у челки;
/// 3. и держится в ней `holdTicksRequired` тиков — защита от случайного пролёта.
final class DragWatcher {

    private(set) var isDragging = false
    var onChange: ((Bool) -> Void)?

    /// Зона приёма в координатах экрана. Пока курсор вне её — мишени нет.
    var zone: (() -> NSRect)?

    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)

    /// Счётчик пастборда, снятый при отпущенной кнопке: всё, что лежало там до
    /// нажатия, осталось от прошлого переноса и текущим кликом не является.
    private var idleChangeCount = -1
    private var sessionChangeCount = -1
    private var sessionHasFiles = false
    private var holdTicks = 0

    private let tickInterval: TimeInterval = 0.06
    /// ~0.24 с у челки до раскрытия мишени
    private let holdTicksRequired = 4

    func start() {
        stop()
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        // .common обязателен: в .default таймер замирает, пока система тащит файл
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        holdTicks = 0
        set(false)
    }

    deinit { timer?.invalidate() }

    private func tick() {
        // NSEvent.pressedMouseButtons — опрос состояния, работает и внутри drag-сессии
        let change = dragPasteboard.changeCount
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            idleChangeCount = change
            return reset()
        }
        // клик не создаёт сессию перетаскивания — пастборд остался прежним
        guard change != idleChangeCount, dragHasFiles(change) else { return reset() }
        guard zone?().contains(NSEvent.mouseLocation) ?? true else { return reset() }

        holdTicks += 1
        set(holdTicks >= holdTicksRequired)
    }

    private func reset() {
        holdTicks = 0
        set(false)
    }

    /// Содержимое пастборда разбираем только когда сессия сменилась
    private func dragHasFiles(_ change: Int) -> Bool {
        guard change != sessionChangeCount else { return sessionHasFiles }
        sessionChangeCount = change

        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        sessionHasFiles = dragPasteboard.canReadObject(forClasses: [NSURL.self], options: opts)
            || dragPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return sessionHasFiles
    }

    private func set(_ value: Bool) {
        guard isDragging != value else { return }
        isDragging = value
        dlog("watcher dragging=\(value)")
        onChange?(value)
    }
}

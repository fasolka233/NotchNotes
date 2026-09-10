import AppKit
import UniformTypeIdentifiers

/// Диагностика перетаскивания. Включается NOTCH_DEBUG=1 в окружении.
func dlog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[notch] " + message() + "\n").utf8))
}

final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Ловит наведение курсора. Перетаскивание живёт в DropCatcher —
/// NSHostingView лежит выше и перехватывал бы drag-события.
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// Зона, которая реально реагирует на курсор (в координатах вью).
    /// Без неё трекинг ловил всё окно, включая прозрачные поля вокруг челки,
    /// и панель раскрывалась от случайного проезда мышью.
    var hotRect: (() -> NSRect)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let rect = hotRect?() ?? bounds
        guard rect.width > 0, rect.height > 0 else { return }
        addTrackingArea(NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent)  { onExit?() }
}

/// Прозрачный слой поверх SwiftUI-хоста, принимающий файлы на свёрнутую челку.
///
/// AppKit ищет цель перетаскивания хит-тестом сверху вниз, поэтому
/// NSHostingView (он занимает всё окно) забирал drag себе и до нижележащего
/// HoverView события не доходили. Ловим на самом верхнем слое.
final class DropCatcher: NSView {
    /// Отдаёт количество файлов в переносе — его показываем в подсказке
    var onDragEnter: ((Int) -> Void)?
    var onDragExit: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    /// Слой закрывает собой кнопку меню-бара, поэтому клик надо вернуть ей
    var onMouseDown: (() -> Void)?

    /// Куда складывать файлы, которые перетащили «обещанием» (Почта, Safari, Фото)
    var promiseDirectory: URL?

    /// Нарисованная область челки внутри вью. Окно шире неё — под тень и «ушки», —
    /// и без этой границы слой принимал бросок в прозрачное поле сбоку от челки:
    /// файл исчезал в точке, где визуально ничего нет.
    var dropRect: (() -> NSRect)?

    /// Небольшой допуск: курсор во время броска обычно чуть за краем иконки
    private let dropSlack: CGFloat = 8

    private func accepts(point: NSPoint) -> Bool {
        guard let rect = dropRect?() else { return true }
        return rect.insetBy(dx: -dropSlack, dy: -dropSlack).contains(point)
    }

    /// Слой нужен только для перетаскивания: `registerForDraggedTypes` работает
    /// и на вью, которое не участвует в хит-тесте мыши. Раньше слой возвращал
    /// себя на всей челке и забирал наведение и клики у SwiftUI под ним —
    /// интерактивные значки на свёрнутой челке не получали событий вовсе.
    /// Исключение — кнопка меню-бара: там слой обрабатывает клик сам.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onMouseDown != nil else { return nil }
        guard let hit = super.hitTest(point) else { return nil }
        return accepts(point: convert(point, from: superview)) ? hit : nil
    }

    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "NotchNotes.filePromise"
        return q
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        register()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        register()
    }

    private func register() {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onMouseDown else { return super.mouseDown(with: event) }
        onMouseDown()
    }

    // MARK: - Разбор буфера перетаскивания

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                    options: opts) as? [URL]) ?? []
    }

    private func promises(from info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        (info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                             options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        !urls(from: info).isEmpty || !promises(from: info).isEmpty
    }

    // MARK: - Drag & Drop

    /// Точка броска в координатах вью
    private func location(_ sender: NSDraggingInfo) -> NSPoint {
        convert(sender.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dlog("entered types=\(sender.draggingPasteboard.types ?? []) accepts=\(accepts(sender)) frame=\(frame) hidden=\(isHidden) level=\(window?.level.rawValue ?? -1)")
        guard accepts(sender) else { return [] }
        guard accepts(point: location(sender)) else { return [] }
        let count = max(urls(from: sender).count + promises(from: sender).count,
                        sender.numberOfValidItemsForDrop)
        onDragEnter?(count)
        return .copy
    }

    /// Внутри окна курсор может съехать с самой челки в прозрачное поле —
    /// тогда мишень гасим, но окно продолжает следить за возвратом.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        guard accepts(point: location(sender)) else {
            onDragExit?()
            return []
        }
        let count = max(urls(from: sender).count + promises(from: sender).count,
                        sender.numberOfValidItemsForDrop)
        onDragEnter?(count)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dlog("exited")
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dlog("ended at \(sender.draggingLocation)")
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dlog("prepare accepts=\(accepts(sender))")
        return accepts(sender) && accepts(point: location(sender))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dlog("perform urls=\(urls(from: sender).count) promises=\(promises(from: sender).count)")
        let direct = urls(from: sender)
        if !direct.isEmpty {
            onFilesDropped?(direct)
            return true
        }

        let receivers = promises(from: sender)
        guard !receivers.isEmpty, let dir = promiseDirectory else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: dir,
                                          options: [:],
                                          operationQueue: promiseQueue) { [weak self] url, error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.onFilesDropped?([url]) }
            }
        }
        return true
    }
}

import AppKit

/// Системный шит «Поделиться» (AirDrop, Почта, Сообщения, Заметки…).
/// Живёт синглтоном, потому что NSSharingServicePicker нужно удерживать,
/// пока пользователь выбирает сервис — иначе меню закрывается сразу.
final class SharePresenter: NSObject, NSSharingServicePickerDelegate {

    static let shared = SharePresenter()

    /// Пока true — NotchController не сворачивает панель
    private(set) var isPresenting = false

    private var picker: NSSharingServicePicker?

    /// Панель челки: к ней и цепляем поповер
    private var anchorView: NSView? {
        NSApp.windows.first(where: { $0 is NotchPanel })?.contentView
    }

    func share(_ items: [Any], from view: NSView? = nil, rect: NSRect? = nil) {
        guard !items.isEmpty, let anchor = view ?? anchorView else { return }

        let p = NSSharingServicePicker(items: items)
        p.delegate = self
        picker = p
        isPresenting = true

        let anchorRect = rect ?? NSRect(x: anchor.bounds.midX - 1,
                                        y: anchor.bounds.minY,
                                        width: 2, height: 2)
        p.show(relativeTo: anchorRect, of: anchor, preferredEdge: .minY)

        // Пикер не сообщает о закрытии без выбора, поэтому снимаем блокировку по таймеру
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish() }
    }

    /// Файлы полки/буфера → шит. Пропускаем то, чего уже нет на диске.
    func shareFiles(_ urls: [URL]) {
        share(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func finish() {
        picker = nil
        isPresenting = false
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        // выбрали сервис или закрыли меню — снимаем блокировку с небольшой задержкой,
        // чтобы успел подняться UI самого сервиса
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish() }
    }
}

import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var launchItem: NSMenuItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installExceptionGuard()

        controller = NotchController()
        controller?.onSettings = { [weak self] in self?.openSettings() }
        setupStatusItem()

        Prefs.shared.install([
            .toggle:  { [weak self] in self?.controller?.toggle() },
            .capture: { [weak self] in self?.controller?.capture() }
        ])
        // Занятое сочетание молча не работает — тогда сразу показываем, где его поменять
        if !Prefs.shared.problems.isEmpty { openSettings() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.controller?.reposition()
        }
    }

    /// Фоновая утилита в меню-баре не имеет права молча исчезать с экрана.
    ///
    /// AppKit ловит исключение из прохода раскладки и по умолчанию зовёт
    /// `_crashOnException:` — это и был SIGTRAP. Логируем и живём дальше:
    /// кривой кадр челки пользователь переживёт, пропавшее приложение — нет.
    /// Настоящую причину чинит защёлка в `NotchController.applyFrame`, здесь
    /// только сетка безопасности на всё остальное.
    private func installExceptionGuard() {
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[NotchNotes] uncaught: %@ — %@\n%@",
                  exception.name.rawValue,
                  exception.reason ?? "",
                  exception.callStackSymbols.joined(separator: "\n"))
        }
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.grid.2x2",
                                     accessibilityDescription: "NotchNotes")

        let menu = NSMenu()

        for (index, tab) in NotchTab.allCases.enumerated() {
            let mi = NSMenuItem(title: tab.title,
                                action: #selector(openTab(_:)),
                                keyEquivalent: "\(index + 1)")
            mi.keyEquivalentModifierMask = [.command, .option]
            mi.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)
            mi.representedObject = tab.rawValue
            mi.target = self
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Открыть / закрыть",
                                    action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let captureItem = NSMenuItem(title: "Быстрая задача…",
                                     action: #selector(capture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let addFilesItem = NSMenuItem(title: "Добавить файлы на полку…",
                                      action: #selector(addFiles), keyEquivalent: "")
        addFilesItem.target = self
        menu.addItem(addFilesItem)

        let folderItem = NSMenuItem(title: "Папка с данными",
                                    action: #selector(revealData), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        launchItem = loginItem

        let settingsItem = NSMenuItem(title: "Настройки…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        item.menu = menu
        statusItem = item

        // на иконку тоже можно бросать файлы — клик при этом продолжает открывать меню
        if let button = item.button {
            controller?.attachDropTarget(to: button) { [weak button] in
                button?.performClick(nil)
            }
        }
    }

    // MARK: - Действия

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tab = NotchTab(rawValue: raw) else { return }
        controller?.open(activate: true, tab: tab)
    }

    @objc private func toggle() {
        controller?.toggle()
    }

    @objc private func capture() {
        controller?.capture()
    }

    @objc func openSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            let view = SettingsView(prefs: .shared, reminders: controller.vm.reminders,
                                    notes: controller.vm.notes)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Настройки NotchNotes"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        controller.close(force: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func addFiles() {
        controller?.open(activate: true, tab: .shelf)
        controller?.vm.shelf.addFromOpenPanel()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("launch at login: \(error.localizedDescription)")
        }
        launchItem?.state = service.status == .enabled ? .on : .off
    }

    @objc private func revealData() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotes")
        NSWorkspace.shared.open(url)
    }
}

import SwiftUI
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Обычное окно «Настройки…»: хоткеи, уведомления, резервные копии, справка по клавишам.
struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var reminders: ReminderCenter
    let notes: NotesStore

    @State private var restoreError = false

    var body: some View {
        Form {
            Section("Горячие клавиши") {
                ForEach(Prefs.Shortcut.allCases) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(s.title) {
                            HStack(spacing: 6) {
                                ShortcutRecorder(prefs: prefs, shortcut: s)
                                Button("Сбросить") { prefs.reset(s) }
                                    .disabled(prefs.combos[s] == s.fallback)
                            }
                        }
                        if let problem = prefs.problems[s] {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section("Уведомления") {
                Toggle("Утренняя сводка задач в \(ReminderCenter.digestHour):00", isOn: $prefs.morningDigest)
                if reminders.notificationsAllowed == false {
                    HStack {
                        Label("Уведомления выключены в системных настройках — напоминания будут только звуком",
                              systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть настройки") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }

            Section("Резервные копии") {
                Text("Раз в день заметки копируются в папку backups, хранится 7 последних копий.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Показать копии") {
                        try? FileManager.default.createDirectory(at: notes.backupDirectory,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(notes.backupDirectory)
                    }
                    Button("Восстановить из копии…", action: restore)
                }
            }

            Section("Клавиши в панели") {
                shortcutRow("⌘1 … ⌘5", "вкладки")
                shortcutRow("⌘N", "новая заметка / задача")
                shortcutRow("⌘F", "поиск")
                shortcutRow("↑ ↓", "по списку заметок и задач")
                shortcutRow("⏎", "открыть заметку или задачу")
                shortcutRow("Пробел", "отметить задачу · старт/пауза таймера")
                shortcutRow("⌘Z", "вернуть удалённое")
                shortcutRow("Esc", "свернуть панель")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { reminders.refreshPermission() }
        .alert("Не удалось прочитать копию", isPresented: $restoreError) {
            Button("OK", role: .cancel) {}
        }
    }

    private func shortcutRow(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) {
            Text(keys).font(.system(.body, design: .rounded).weight(.medium))
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.directoryURL = notes.backupDirectory
        panel.allowedContentTypes = [.json]
        panel.message = "Выберите копию — текущие заметки будут заменены"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Заменить заметки копией «\(url.lastPathComponent)»?"
        alert.informativeText = "Текущие заметки сохранятся в той же папке как before-restore — их тоже можно будет вернуть."
        alert.addButton(withTitle: "Восстановить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !notes.restore(from: url) { restoreError = true }
    }
}

/// Кнопка-записыватель: нажали — ждёт сочетание, Esc — отмена
private struct ShortcutRecorder: View {
    @ObservedObject var prefs: Prefs
    let shortcut: Prefs.Shortcut

    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? (prefs.combos[shortcut]?.display ?? "—") : "Нажмите сочетание…") {
            monitor == nil ? start() : stop()
        }
        .font(.system(.body, design: .rounded).weight(.medium))
        .frame(minWidth: 150)
        .help("Нажмите и введите новое сочетание с ⌘, ⌥ или ⌃")
        .onDisappear(perform: stop)
    }

    private func start() {
        prefs.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape { stop(); return nil }
            if let combo = HotKey.Combo(event: event) {
                stop()
                prefs.set(combo, for: shortcut)
            } else {
                NSSound.beep()          // без модификатора — это обычная буква, не хоткей
            }
            return nil
        }
    }

    private func stop() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        prefs.resume()
    }
}

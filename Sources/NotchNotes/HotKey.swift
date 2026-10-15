import AppKit
import Carbon.HIToolbox

/// Глобальное сочетание клавиш через Carbon. Сочетаний несколько, обработчик
/// событий один на всё приложение — какое нажато, узнаём по `id`.
final class HotKey {

    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        /// Carbon-маска: optionKey / cmdKey / shiftKey / controlKey
        var modifiers: UInt32
        /// Подпись клавиши как её видно на клавиатуре: «Space», «N»
        var key: String

        static let toggle  = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
        static let capture = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), key: "Space")

        var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0  { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0   { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0     { s += "⌘" }
            return s + key
        }

        /// Сочетание из нажатия в окне настроек. Без ⌘/⌥/⌃ глобальная клавиша
        /// перехватывала бы обычный набор текста — такие не принимаем.
        init?(event: NSEvent) {
            let flags = event.modifierFlags
            var m: UInt32 = 0
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            if flags.contains(.option)  { m |= UInt32(optionKey) }
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.shift)   { m |= UInt32(shiftKey) }
            guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
            let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
                                        kVK_Delete: "⌫", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                        kVK_LeftArrow: "←", kVK_RightArrow: "→"]
            let code = Int(event.keyCode)
            guard let key = names[code] ?? event.charactersIgnoringModifiers?.uppercased(),
                  !key.isEmpty, code != kVK_Escape else { return nil }
            self.init(keyCode: UInt32(code), modifiers: m, key: key)
        }

        init(keyCode: UInt32, modifiers: UInt32, key: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.key = key
        }
    }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(id: UInt32, action: @escaping () -> Void) {
        self.id = id
        HotKey.actions[id] = action
        HotKey.installHandler()
    }

    deinit {
        unregister()
        HotKey.actions[id] = nil
    }

    /// false — сочетание уже кем-то занято, нажатия до нас не дойдут
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        let hkID = EventHotKeyID(signature: OSType(0x4E4F5443), id: id)   // 'NOTC'
        return RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Системные сочетания (Spotlight ⌘Space, смена раскладки ⌃Space…) Carbon
    /// регистрирует без ошибки, но система забирает нажатие первой — проверяем сами.
    static func isTakenBySystem(_ combo: Combo) -> Bool {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let list = raw?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return list.contains { d in
            (d[kHISymbolicHotKeyEnabled] as? Bool) == true
                && (d[kHISymbolicHotKeyCode] as? Int) == Int(combo.keyCode)
                && (d[kHISymbolicHotKeyModifiers] as? Int).map { UInt32($0) & mask } == combo.modifiers
        }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

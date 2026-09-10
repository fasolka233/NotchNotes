import AppKit
import Carbon.HIToolbox

final class HotKey {
    static weak var current: HotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    /// keyCode: 49 = Space. modifiers: optionKey / cmdKey / shiftKey / controlKey
    init(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) {
        HotKey.current = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F5443), id: 1) // 'NOTC'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

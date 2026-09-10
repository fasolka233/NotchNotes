import AppKit

enum NotchGeometry {

    /// Ширина «виртуальной челки» на мониторах без выреза
    static let fallbackNotchWidth: CGFloat = 220

    /// Встроенный экран с челкой, иначе основной
    static var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    static func notchSize(for screen: NSScreen) -> CGSize {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = max(screen.safeAreaInsets.top, menuBarHeight, 32)

        var width = fallbackNotchWidth
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let w = screen.frame.width - left.width - right.width
            if w > 40 { width = w }
        }
        return CGSize(width: width, height: height)
    }

    /// Зона, в которой перетаскиваемый файл «замечают»: полоса у верхней кромки
    /// вокруг челки. Шире самой челки — иначе в неё не прицелиться, — но она
    /// должна оставаться соразмерной мишени: если зона намного шире того, что
    /// вырастает на экране, мишень раскрывается, когда курсор ещё далеко, и
    /// выглядит это как случайное срабатывание.
    static let dropZoneWing: CGFloat = 90
    static let dropZoneHeight: CGFloat = 64

    static func dropZone(screen: NSRect, notchWidth: CGFloat) -> NSRect {
        let width = notchWidth + 2 * dropZoneWing
        return NSRect(x: (screen.midX - width / 2).rounded(),
                      y: screen.maxY - dropZoneHeight,
                      width: width,
                      height: dropZoneHeight)
    }

    /// Окно всегда прижато к верхней кромке экрана и центрировано
    static func frame(for screen: NSScreen, size: CGSize) -> NSRect {
        let f = screen.frame
        return NSRect(x: (f.midX - size.width / 2).rounded(),
                      y: f.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }
}

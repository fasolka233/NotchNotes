import SwiftUI

/// Форма челки: сверху «вогнутые ушки», снизу обычное скругление
struct NotchShape: InsettableShape {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 22
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let tr = max(0, topRadius)
        let br = max(0, bottomRadius)

        var p = Path()
        p.move(to: CGPoint(x: r.minX - tr, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + tr),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + br, y: r.maxY),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - br),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX + tr, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

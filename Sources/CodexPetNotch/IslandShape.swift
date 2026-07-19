import SwiftUI

struct IslandShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 5)
        let r = min(bottomRadius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control1: CGPoint(x: rect.minX + s * 0.55, y: rect.minY),
            control2: CGPoint(x: rect.minX + s, y: rect.minY + s * 0.35)
        )
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - s, y: rect.minY + s * 0.35),
            control2: CGPoint(x: rect.maxX - s * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

import SwiftUI

/// The Orbit brand mark (ring, centre dot, moon) drawn in the 64-unit design grid of the dashboard's OrbitMark.
/// Ring and moon edge follow the appearance; the teal dots are fixed brand colour.
public struct OrbitMark: View {
    private let size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }

    public var body: some View {
        let ring = OC.markRing, teal = OC.brand, edge = OC.markEdge
        return Canvas { ctx, canvas in
            let k = min(canvas.width, canvas.height) / 64
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (cx - r) * k, y: (cy - r) * k, width: 2 * r * k, height: 2 * r * k))
            }
            ctx.stroke(circle(32, 32, 20), with: .color(ring), lineWidth: 6 * k)
            ctx.fill(circle(32, 32, 6), with: .color(teal))
            ctx.fill(circle(47, 17, 7), with: .color(teal))
            ctx.stroke(circle(47, 17, 7), with: .color(edge), lineWidth: 3 * k)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("orch")
        .accessibilityIdentifier("brand.mark")
    }
}

import SwiftUI

public struct WorkspaceRail: View {
    private let color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        Rectangle().fill(color).frame(width: OR.rail).accessibilityHidden(true)
    }
}

/// Inset this within a card; its label supplies the non-colour status cue.
public struct AttentionRail: View {
    public init() {}

    public var body: some View {
        Capsule().fill(OC.you).frame(width: OR.rail).accessibilityHidden(true)
    }
}

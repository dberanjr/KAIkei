import AppKit
import SwiftUI

/// Hover state lives in an object, not @State: that is a macro whose plugin only ships with Xcode.
final class HoverModel: ObservableObject {
    @Published var hovering = false
}

/// Makes a region open a drill-down: a soft highlight and a pointing hand on hover, and a button for VoiceOver.
/// Wrap non-interactive content only; real buttons nested inside would lose their own clicks.
struct Clickable<Content: View>: View {
    @StateObject private var hover = HoverModel()
    var help: String?
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover.hovering ? 0.08 : 0)).padding(-6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hover.hovering = $0 }
            .onContinuousHover { if case .active = $0 { NSCursor.pointingHand.set() } }
            .help(help ?? "")
            .accessibilityAddTraits(.isButton)
    }
}

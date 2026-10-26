import AppKit
import SwiftUI

/// A transparent layer over the chart stack that owns every pointer interaction there: hovering, dragging a zoom box,
/// double-clicking to zoom out, and scrolling sideways.
///
/// It is an AppKit view rather than SwiftUI gestures because the window can be dragged by its background. SwiftUI
/// gestures on a chart do not stop that, so a drag meant as a zoom box was claimed by the window instead. This view says it
/// cannot move the window, and accepts the first click even when the window is not focused (it is a floating widget).
///
/// Points are in the view's own space with the origin at the top left, the same as the chart stack.
struct PointerSurface: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void
    var onDrag: (_ start: CGPoint, _ current: CGPoint) -> Void
    var onDragEnd: (_ start: CGPoint, _ end: CGPoint) -> Void
    var onDoubleClick: () -> Void
    /// Horizontal scroll in points (positive moves the view later). Returns how many it used; the rest is kept for next time.
    var onScroll: (_ points: CGFloat) -> CGFloat

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onDoubleClick = onDoubleClick
        view.onScroll = onScroll
    }

    final class SurfaceView: NSView {
        var onMove: (CGPoint) -> Void = { _ in }
        var onExit: () -> Void = {}
        var onDrag: (CGPoint, CGPoint) -> Void = { _, _ in }
        var onDragEnd: (CGPoint, CGPoint) -> Void = { _, _ in }
        var onDoubleClick: () -> Void = {}
        var onScroll: (CGFloat) -> CGFloat = { _ in 0 }

        private var start: CGPoint?
        private var dragging = false
        private var pendingScroll: CGFloat = 0
        /// Movement under this many points is a click, not a drag.
        private let threshold: CGFloat = 5

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseMoved(with event: NSEvent) { onMove(point(event)) }
        override func mouseExited(with event: NSEvent) { if !dragging { onExit() } }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 { onDoubleClick(); start = nil; return }
            start = point(event)
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let p = point(event)
            if !dragging, hypot(p.x - start.x, p.y - start.y) < threshold { return }
            dragging = true
            onDrag(start, p)
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil; dragging = false }
            guard dragging, let start else { return }
            onDragEnd(start, point(event))
        }

        /// A sideways scroll pans the view. A mostly vertical one is passed up so the page still scrolls under the charts.
        override func scrollWheel(with event: NSEvent) {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let sideways = abs(dx) > abs(dy) || event.modifierFlags.contains(.shift)
            guard sideways else { super.scrollWheel(with: event); return }
            // Shift turns an ordinary mouse wheel (vertical only) into a sideways scroll. The sign makes content follow the fingers.
            let amount = abs(dx) > 0 ? dx : dy
            pendingScroll += -amount * (event.hasPreciseScrollingDeltas ? 1 : 10)
            pendingScroll -= onScroll(pendingScroll)
            if event.phase == .ended || event.momentumPhase == .ended { pendingScroll = 0 }
        }
    }
}

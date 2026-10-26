import SwiftUI
import UsageCore

/// Drives the timeline's crosshair and hover cards. It is deliberately not part of `UsageStore`: pointer movement fires
/// many times a second, and anything observing the store would redraw every chart each time. Only the small readout and
/// overlay views observe this object, so the charts stay still while the pointer moves.
@MainActor
final class TimelineHover: ObservableObject {
    /// Pointer position in the chart stack's own coordinates, nil when it is outside.
    @Published private(set) var pointer: CGPoint?
    /// The call nearest the pointer while it is over any panel, for the readout line and the crosshair snap.
    @Published private(set) var focusedCall: Int?
    @Published private(set) var shown: HoverTarget?
    @Published private(set) var shownLocation: CGPoint = .zero

    /// Horizontal extent of a drag-to-zoom selection, in the chart stack's coordinates. While it exists, hovering is paused.
    @Published private(set) var selection: ClosedRange<CGFloat>?

    /// How long a slice card waits, 0 to 1 s. Takes effect on the next wait.
    var sliceDelay: Double {
        get { tracker.sliceDelay }
        set { tracker.sliceDelay = newValue }
    }

    /// Size of the chart stack, set by the view. Plain property: changing it must not trigger a redraw.
    var containerSize: CGSize = .zero

    private var tracker = DwellTracker()
    private var timer: DispatchWorkItem?

    func pointerMoved(to location: CGPoint, target: HoverTarget?, focus: Int?) {
        guard selection == nil else { return }
        pointer = location
        if focusedCall != focus { focusedCall = focus }
        tracker.pointer(target: target, x: location.x, y: location.y, now: ProcessInfo.processInfo.systemUptime)
        publishShown()
        scheduleCheck()
    }

    func pointerLeft() {
        tracker.leave()
        timer?.cancel()
        pointer = nil
        focusedCall = nil
        publishShown()
    }

    /// Starts, grows or ends a drag selection. Beginning one hides any card, since the pointer is busy zooming.
    func select(_ range: ClosedRange<CGFloat>?) {
        if range != nil, selection == nil {
            tracker.leave()
            timer?.cancel()
            focusedCall = nil
            publishShown()
        }
        selection = range
    }

    /// Shows a card without a pointer: used by the headless snapshot renderer.
    func preview(_ target: HoverTarget, focus: Int?) {
        pointer = nil
        focusedCall = focus
        shown = target
        shownLocation = CGPoint(x: -1, y: -1)  // the overlay places it from the target itself
    }

    private func publishShown() {
        let now = tracker.shown
        if now != shown {
            shown = now
            if now != nil, let pointer { shownLocation = pointer }
        }
    }

    /// Wakes up when the wait for the pointer to rest is over.
    private func scheduleCheck() {
        timer?.cancel()
        guard let deadline = tracker.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        if tracker.sliceDelay == 0 {  // "immediate" means no timer at all
            if tracker.tick(now: ProcessInfo.processInfo.systemUptime) { publishShown() }
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.tracker.tick(now: ProcessInfo.processInfo.systemUptime) { self.publishShown() }
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.005, execute: item)
    }
}

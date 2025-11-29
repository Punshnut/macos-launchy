import AppKit

/// Wrapper that keeps an `NSEvent` monitor token alive until explicitly invalidated.
final class EventMonitorToken {
    private var token: Any?
    private let removalHandler: (Any) -> Void

    init(token: Any, removalHandler: @escaping (Any) -> Void) {
        self.token = token
        self.removalHandler = removalHandler
    }

    func invalidate() {
        guard let token else { return }
        removalHandler(token)
        self.token = nil
    }

    deinit {
        invalidate()
    }
}

import AppKit

extension NSView {
    /// Walks superviews to determine whether the hierarchy includes the target view type.
    func hasAncestor(ofType type: NSView.Type) -> Bool {
        var current: NSView? = self
        while let view = current {
            if view.isKind(of: type) {
                return true
            }
            current = view.superview
        }
        return false
    }
}

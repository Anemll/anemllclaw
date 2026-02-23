#if os(iOS)
import SwiftUI
import UIKit

struct IdleTouchPassthroughView: UIViewRepresentable {
    let tracker: UserIdleTracker

    func makeUIView(context: Context) -> TouchPassthroughUIView {
        let view = TouchPassthroughUIView()
        view.onTouch = { [weak tracker] in
            Task { @MainActor in
                tracker?.recordInteraction()
            }
        }
        return view
    }

    func updateUIView(_ uiView: TouchPassthroughUIView, context: Context) {}
}

final class TouchPassthroughUIView: UIView {
    var onTouch: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        self.onTouch?()
        return nil
    }
}
#endif

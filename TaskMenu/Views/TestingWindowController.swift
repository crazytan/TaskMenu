import AppKit

@MainActor
final class TestingWindowController: NSWindowController {
    init(appState: AppState) {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: TaskMenuMetrics.popoverWidth,
                height: TaskMenuMetrics.signedInPopoverHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TaskMenu Testing"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentViewController = TaskPopoverViewController(
            appState: appState,
            onRequestClose: {},
            onContentSizeChanged: { [weak self] size in
                self?.resizeWindowContent(to: size)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func resizeWindowContent(to size: NSSize) {
        guard let window, size.width > 0, size.height > 0 else { return }

        let currentFrame = window.frame
        let contentRect = NSRect(origin: .zero, size: size)
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = currentFrame.midX - frame.width / 2
        frame.origin.y = currentFrame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }
}

extension TestingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}

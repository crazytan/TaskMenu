import AppKit
import Observation

@MainActor
enum TaskMenuMetrics {
    static let popoverWidth: CGFloat = 320
    static let signedInPopoverHeight: CGFloat = 480
    static let signedOutPopoverHeight: CGFloat = 300
    static let loadingPopoverHeight: CGFloat = 180
    static let errorStripHeight: CGFloat = 34
    static let taskIndentWidth: CGFloat = 20
}

@MainActor
enum TaskMenuAppKit {
    static func symbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    static func pin(
        _ view: NSView,
        to container: NSView,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
    }

    static func label(
        _ text: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = .labelColor,
        lines: Int = 1
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    static func configureTaskListScrollIndicators(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
    }

    static func observeAppState(
        _ track: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        withObservationTracking {
            MainActor.assumeIsolated {
                track()
            }
        } onChange: {
            Task { @MainActor in
                onChange()
            }
        }
    }
}

@MainActor
final class TaskMenuAppStateObserver {
    private var observationToken = 0

    func observe(
        _ track: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        observationToken += 1
        let token = observationToken
        TaskMenuAppKit.observeAppState(track) { [weak self] in
            guard let self, self.observationToken == token else { return }
            onChange()
            self.observe(track, onChange: onChange)
        }
    }

    func invalidate() {
        observationToken += 1
    }
}

@MainActor
final class TaskMenuActionButton: NSButton {
    var onPress: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    init(
        title: String = "",
        symbolName: String? = nil,
        pointSize: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil,
        onPress: (() -> Void)? = nil
    ) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(press)
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.translatesAutoresizingMaskIntoConstraints = false
        if let symbolName {
            self.image = TaskMenuAppKit.symbol(
                symbolName,
                pointSize: pointSize,
                weight: weight,
                accessibilityDescription: accessibilityDescription
            )
            self.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        self.toolTip = accessibilityDescription
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func press() {
        onPress?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        guard onHoverChanged != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

@MainActor
final class TaskMenuTextField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onEndEditing: (() -> Void)?

    init(placeholder: String) {
        super.init(frame: .zero)
        placeholderString = placeholder
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: NSFont.systemFontSize)
        delegate = self
        target = self
        action = #selector(commit)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onChange?(stringValue)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onEndEditing?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    @objc private func commit() {
        onCommit?(stringValue)
    }
}

@MainActor
class TaskMenuHoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, symbolName: String? = nil, action: @escaping () -> Void) {
        self.closure = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbolName {
            image = TaskMenuAppKit.symbol(symbolName, pointSize: 13)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        closure()
    }
}

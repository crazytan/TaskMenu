import AppKit

@MainActor
final class TaskPopoverViewController: NSViewController {
    private enum Mode: Equatable {
        case initialLoading
        case signedOut
        /// `isDemo` is part of the mode so toggling it re-renders the banner.
        case signedIn(isDemo: Bool)
    }

    private let appState: AppState
    private let onRequestClose: () -> Void
    private let onContentSizeChanged: (NSSize) -> Void
    private let backgroundView = NSVisualEffectView()
    private let rootStack = NSStackView()
    private var currentMode: Mode?
    private var signedInContentHeightConstraint: NSLayoutConstraint?
    private var errorSeparator: NSView?
    private var errorStrip: NSView?
    private var signInButton: NSButton?
    private var signInErrorLabel: NSTextField?
    private let appStateObserver = TaskMenuAppStateObserver()

    init(
        appState: AppState,
        onRequestClose: @escaping () -> Void,
        onContentSizeChanged: @escaping (NSSize) -> Void = { _ in }
    ) {
        self.appState = appState
        self.onRequestClose = onRequestClose
        self.onContentSizeChanged = onContentSizeChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view = backgroundView

        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 0
        backgroundView.addSubview(rootStack)
        TaskMenuAppKit.pin(rootStack, to: backgroundView)
        NSLayoutConstraint.activate([
            backgroundView.widthAnchor.constraint(equalToConstant: TaskMenuMetrics.popoverWidth)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderIfNeeded(force: true)
        observeAppState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        MenuBarWindowChrome.applyLiquidGlassSupport(to: view.window)
    }

    private var desiredMode: Mode {
        if appState.isShowingInitialTaskLoad {
            return .initialLoading
        } else if !appState.isSignedIn {
            return .signedOut
        } else {
            return .signedIn(isDemo: appState.isDemoMode)
        }
    }

    private func renderIfNeeded(force: Bool = false) {
        let mode = desiredMode
        if force || currentMode != mode {
            render(mode)
        } else {
            updateSignedOutState()
            updateErrorStrip()
        }
        let contentSize = contentSize(for: mode)
        preferredContentSize = contentSize
        onContentSizeChanged(contentSize)
    }

    private func render(_ mode: Mode) {
        currentMode = mode
        signedInContentHeightConstraint = nil
        signInButton = nil
        signInErrorLabel = nil
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        rootStack.arrangedSubviews.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch mode {
        case .initialLoading:
            rootStack.addArrangedSubview(loadingView())
        case .signedOut:
            rootStack.addArrangedSubview(signInView())
        case let .signedIn(isDemo):
            if isDemo {
                rootStack.addArrangedSubview(demoBanner())
                rootStack.addArrangedSubview(TaskMenuAppKit.separator())
            }
            let listController = TaskListAppKitViewController(
                appState: appState,
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                },
                onRequestClose: { [weak self] in
                    self?.onRequestClose()
                }
            )
            addChild(listController)
            rootStack.addArrangedSubview(listController.view)
            let heightConstraint = listController.view.heightAnchor.constraint(equalToConstant: signedInContentHeight())
            heightConstraint.isActive = true
            signedInContentHeightConstraint = heightConstraint
            updateErrorStrip()
        }
    }

    private func loadingView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: TaskMenuMetrics.loadingPopoverHeight)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(TaskMenuAppKit.label(
            "Loading tasks…",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor
        ))
        return container
    }

    private func signInView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: TaskMenuMetrics.signedOutPopoverHeight)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        )

        let icon = NSImageView(image: TaskMenuAppKit.symbol("checklist", pointSize: 40, weight: .thin) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(TaskMenuAppKit.label(
            "TaskMenu",
            font: .boldSystemFont(ofSize: 18)
        ))

        let message = TaskMenuAppKit.label(
            "Sign in with Google to access your tasks, or explore the demo with sample data.",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor,
            lines: 3
        )
        message.alignment = .center
        stack.addArrangedSubview(message)

        let signInButton = NSButton(
            title: "Sign in with Google",
            target: self,
            action: #selector(signIn)
        )
        signInButton.bezelStyle = .rounded
        signInButton.controlSize = .large
        stack.addArrangedSubview(signInButton)
        signInButton.widthAnchor.constraint(equalToConstant: 250).isActive = true
        self.signInButton = signInButton

        let demoButton = NSButton(
            title: "Explore the Demo",
            target: self,
            action: #selector(enterDemoMode)
        )
        demoButton.bezelStyle = .rounded
        stack.addArrangedSubview(demoButton)
        demoButton.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let quitButton = NSButton(title: "Quit TaskMenu", target: self, action: #selector(quit))
        quitButton.isBordered = false
        quitButton.controlSize = .small
        stack.addArrangedSubview(quitButton)

        let error = TaskMenuAppKit.label(
            "",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .systemRed,
            lines: 3
        )
        stack.addArrangedSubview(error)
        signInErrorLabel = error

        updateSignedOutState()
        return container
    }

    /// Marks the sample data as such, and keeps a way back to sign-in visible.
    private func demoBanner() -> NSView {
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.heightAnchor.constraint(equalToConstant: TaskMenuMetrics.demoBannerHeight)
        ])

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        banner.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: banner,
            insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        )

        let icon = NSImageView(image: TaskMenuAppKit.symbol("wand.and.stars", pointSize: 11) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(TaskMenuAppKit.label(
            "Demo mode — sample data",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .secondaryLabelColor
        ))
        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        let exitButton = NSButton(title: "Exit Demo", target: self, action: #selector(exitDemoMode))
        exitButton.bezelStyle = .rounded
        exitButton.controlSize = .small
        stack.addArrangedSubview(exitButton)

        return banner
    }

    /// Refreshes the signed-out controls in place. Sign-in progress and
    /// failures happen while the mode stays `.signedOut`, so a full re-render
    /// never runs; the button and error label must update from state directly.
    private func updateSignedOutState() {
        guard currentMode == .signedOut else { return }
        signInButton?.title = appState.isLoading ? "Signing in…" : "Sign in with Google"
        signInButton?.isEnabled = !appState.isLoading
        if let errorMessage = appState.errorMessage {
            signInErrorLabel?.stringValue = errorMessage
            signInErrorLabel?.isHidden = false
        } else {
            signInErrorLabel?.stringValue = ""
            signInErrorLabel?.isHidden = true
        }
    }

    private func updateErrorStrip() {
        guard case .signedIn = currentMode else { return }

        signedInContentHeightConstraint?.constant = signedInContentHeight()

        if let errorStrip {
            rootStack.removeArrangedSubview(errorStrip)
            errorStrip.removeFromSuperview()
            self.errorStrip = nil
        }
        if let errorSeparator {
            rootStack.removeArrangedSubview(errorSeparator)
            errorSeparator.removeFromSuperview()
            self.errorSeparator = nil
        }

        guard let error = appState.errorMessage else { return }

        let separator = NSBox()
        separator.boxType = .separator
        rootStack.addArrangedSubview(separator)
        errorSeparator = separator

        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        strip.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: strip,
            insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        )

        let icon = NSImageView(image: TaskMenuAppKit.symbol("exclamationmark.triangle.fill", pointSize: 11) ?? NSImage())
        icon.contentTintColor = .systemRed
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(TaskMenuAppKit.label(
            error,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize),
            color: .systemRed
        ))
        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        let clearButton = TaskMenuActionButton(
            symbolName: "xmark.circle.fill",
            pointSize: 11,
            accessibilityDescription: "Dismiss error"
        ) { [weak self] in
            self?.appState.errorMessage = nil
        }
        clearButton.contentTintColor = .systemRed
        stack.addArrangedSubview(clearButton)

        rootStack.addArrangedSubview(strip)
        self.errorStrip = strip
    }

    /// The popover total is fixed, so each strip around the list takes its
    /// space out of the list.
    private func signedInContentHeight() -> CGFloat {
        var height = TaskMenuMetrics.signedInPopoverHeight
        if appState.errorMessage != nil {
            height -= TaskMenuMetrics.errorStripHeight
        }
        if appState.isDemoMode {
            height -= TaskMenuMetrics.demoBannerHeight
        }
        return height
    }

    private func contentSize(for mode: Mode) -> NSSize {
        switch mode {
        case .initialLoading:
            return NSSize(width: TaskMenuMetrics.popoverWidth, height: TaskMenuMetrics.loadingPopoverHeight)
        case .signedOut:
            return NSSize(width: TaskMenuMetrics.popoverWidth, height: TaskMenuMetrics.signedOutPopoverHeight)
        case .signedIn:
            return NSSize(width: TaskMenuMetrics.popoverWidth, height: TaskMenuMetrics.signedInPopoverHeight)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(TaskMenuAppDelegate.showSettingsWindow(_:)), to: NSApp.delegate, from: nil)
        onRequestClose()
    }

    private func observeAppState() {
        appStateObserver.observe { [appState] in
            _ = appState.isShowingInitialTaskLoad
            _ = appState.isSignedIn
            _ = appState.isDemoMode
            _ = appState.isLoading
            _ = appState.errorMessage
        } onChange: { [weak self] in
            self?.renderIfNeeded()
        }
    }

    @objc private func signIn() {
        appState.signIn()
    }

    @objc private func enterDemoMode() {
        appState.enterDemoMode()
    }

    @objc private func exitDemoMode() {
        appState.exitDemoMode()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

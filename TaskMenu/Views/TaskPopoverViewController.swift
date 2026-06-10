import AppKit

@MainActor
final class TaskPopoverViewController: NSViewController {
    private enum Mode: Equatable {
        case initialLoading
        case signedOut
        case signedIn
    }

    private let appState: AppState
    private let onRequestClose: () -> Void
    private let backgroundView = NSVisualEffectView()
    private let rootStack = NSStackView()
    private var currentMode: Mode?
    private var currentTaskListController: TaskListAppKitViewController?
    private var taskListContainerHeightConstraint: NSLayoutConstraint?
    private var errorSeparator: NSView?
    private var errorStrip: NSView?
    private let appStateObserver = TaskMenuAppStateObserver()

    init(appState: AppState, onRequestClose: @escaping () -> Void) {
        self.appState = appState
        self.onRequestClose = onRequestClose
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
        rootStack.alignment = .leading
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
            return .signedIn
        }
    }

    private func renderIfNeeded(force: Bool = false) {
        let mode = desiredMode
        if force || currentMode != mode {
            render(mode)
        } else {
            updateErrorStrip()
        }
        preferredContentSize = contentSize(for: mode)
    }

    private func render(_ mode: Mode) {
        currentMode = mode
        currentTaskListController = nil
        taskListContainerHeightConstraint = nil
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
        case .signedIn:
            let listController = TaskListAppKitViewController(appState: appState) { [weak self] in
                self?.openSettings()
            }
            currentTaskListController = listController
            addChild(listController)
            let container = taskListContainer(for: listController)
            rootStack.addArrangedSubview(container)
            updateErrorStrip()
        }
    }

    private func taskListContainer(for listController: TaskListAppKitViewController) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listController.view)
        TaskMenuAppKit.pin(listController.view, to: container)
        let heightConstraint = container.heightAnchor.constraint(equalToConstant: taskListHeightForCurrentErrorState())
        taskListContainerHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: TaskMenuMetrics.popoverWidth),
            heightConstraint
        ])
        return container
    }

    private func loadingView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: TaskMenuMetrics.popoverWidth),
            container.heightAnchor.constraint(equalToConstant: TaskMenuMetrics.loadingPopoverHeight)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
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
            "Loading tasks...",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor
        ))
        return container
    }

    private func signInView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: TaskMenuMetrics.popoverWidth),
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
            "Sign in with Google to access your tasks.",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor,
            lines: 2
        )
        message.alignment = .center
        stack.addArrangedSubview(message)

        let signInButton = NSButton(
            title: appState.isLoading ? "Signing in..." : "Sign in with Google",
            target: self,
            action: #selector(signIn)
        )
        signInButton.bezelStyle = .rounded
        signInButton.controlSize = .large
        signInButton.isEnabled = !appState.isLoading
        stack.addArrangedSubview(signInButton)
        signInButton.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let quitButton = NSButton(title: "Quit TaskMenu", target: self, action: #selector(quit))
        quitButton.isBordered = false
        quitButton.controlSize = .small
        stack.addArrangedSubview(quitButton)

        if let errorMessage = appState.errorMessage {
            let error = TaskMenuAppKit.label(
                errorMessage,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .systemRed,
                lines: 3
            )
            stack.addArrangedSubview(error)
        }

        return container
    }

    private func updateErrorStrip() {
        guard currentMode == .signedIn else { return }

        taskListContainerHeightConstraint?.constant = taskListHeightForCurrentErrorState()

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

        let strip = TaskMenuHoverView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onHoverChanged = { _ in }
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

    private func taskListHeightForCurrentErrorState() -> CGFloat {
        if appState.errorMessage == nil {
            return TaskMenuMetrics.signedInPopoverHeight
        }
        return TaskMenuMetrics.signedInPopoverHeight - TaskMenuMetrics.errorStripHeight
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        onRequestClose()
    }

    private func observeAppState() {
        appStateObserver.observe { [appState] in
            _ = appState.isShowingInitialTaskLoad
            _ = appState.isSignedIn
            _ = appState.isLoading
            _ = appState.errorMessage
        } onChange: { [weak self] in
            self?.renderIfNeeded()
        }
    }

    @objc private func signIn() {
        appState.signIn()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsViewController: SettingsViewController
    private var hasCenteredWindow = false

    init(appState: AppState) {
        settingsViewController = SettingsViewController(appState: appState)

        let window = NSWindow(contentViewController: settingsViewController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = NSSize(
            width: SettingsLayout.windowWidth,
            height: SettingsLayout.minimumWindowHeight
        )
        window.setContentSize(NSSize(
            width: SettingsLayout.windowWidth,
            height: SettingsLayout.windowHeight
        ))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        settingsViewController.prepareToShow()
        if !hasCenteredWindow {
            window?.center()
            hasCenteredWindow = true
        }
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private enum SettingsLayout {
    static let windowWidth: CGFloat = 360
    static let windowHeight: CGFloat = 650
    static let minimumWindowHeight: CGFloat = 460
    static let contentInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    static let contentWidth: CGFloat = windowWidth - contentInsets.left - contentInsets.right
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let appState: AppState
    private let observer = TaskMenuAppStateObserver()

    private let coffeeURL = URL(string: "https://buymeacoffee.com/crazytan")!
    private let discordURL = URL(string: "https://discord.gg/2QaR8xVJJm")!
    private let githubURL = URL(string: "https://github.com/crazytan/TaskMenu")!
    private let supportURL = URL(string: "https://taskmenu.crazytan.dev/support")!
    private let privacyURL = URL(string: "https://taskmenu.crazytan.dev/privacy")!

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        ))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        observeAppState()
        refreshAccountProfile()
    }

    func prepareToShow() {
        render()
        refreshAccountProfile()
    }

    private func observeAppState() {
        observer.observe { [appState] in
            _ = appState.isSignedIn
            _ = appState.googleAccountProfile?.displayEmail
            _ = appState.dueDateNotificationsEnabled
            _ = appState.automaticUpdateChecksEnabled
            _ = appState.isCheckingForUpdates
            _ = appState.updateCheckErrorMessage
            _ = appState.latestAvailableUpdate
            _ = appState.lastUpdateCheckDate
            _ = appState.currentAppVersion
        } onChange: { [weak self] in
            self?.render()
        }
    }

    private func refreshAccountProfile() {
        Task { [appState] in
            await appState.refreshGoogleAccountProfileIfNeeded()
        }
    }

    private func render() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        ))
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = rootStack()
        documentView.addSubview(stack)

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            stack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: SettingsLayout.contentInsets.left
            ),
            stack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -SettingsLayout.contentInsets.right
            ),
            stack.topAnchor.constraint(
                equalTo: documentView.topAnchor,
                constant: SettingsLayout.contentInsets.top
            ),
            stack.bottomAnchor.constraint(
                equalTo: documentView.bottomAnchor,
                constant: -SettingsLayout.contentInsets.bottom
            )
        ])
    }

    private func rootStack() -> NSStackView {
        let stack = verticalStack(spacing: 16)

        stack.addArrangedSubview(preferencesSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(accountSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(tipsSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(supportSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(aboutSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(centered(
            actionButton(
                title: "Quit TaskMenu",
                role: .destructive,
                onPress: { _ in
                    NSApplication.shared.terminate(nil)
                }
            )
        ))

        return stack
    }

    private func preferencesSection() -> NSView {
        section("General", views: [
            toggle(
                title: "Launch at login",
                isOn: SMAppService.mainApp.status == .enabled,
                onChange: { [weak self] isOn in
                    self?.setLaunchAtLogin(isOn)
                }
            ),
            toggle(
                title: "Due date notifications",
                isOn: appState.dueDateNotificationsEnabled,
                onChange: { [appState] isOn in
                    appState.dueDateNotificationsEnabled = isOn
                }
            ),
            toggle(
                title: "Automatically check for updates",
                isOn: appState.automaticUpdateChecksEnabled,
                onChange: { [appState] isOn in
                    appState.automaticUpdateChecksEnabled = isOn
                }
            ),
            currentVersionRow(),
            updateStatusLabel(),
            updateActions()
        ])
    }

    private func currentVersionRow() -> NSView {
        let row = horizontalStack(spacing: 8)
        row.addArrangedSubview(label("Current version", font: .callout, color: .secondaryLabelColor))
        row.addArrangedSubview(TaskMenuAppKit.spacer())
        row.addArrangedSubview(label("v\(appState.currentAppVersion)", font: .callout, color: .secondaryLabelColor))
        constrainToContentWidth(row)
        return row
    }

    private func updateStatusLabel() -> NSView {
        let status = label(
            updateStatusText,
            font: .callout,
            color: appState.updateCheckErrorMessage == nil ? .secondaryLabelColor : .systemRed,
            lines: 0
        )
        return status
    }

    private func updateActions() -> NSView {
        let stack = horizontalStack(spacing: 8)

        let checkButton = actionButton(
            title: appState.isCheckingForUpdates ? "Checking" : "Check Now",
            symbolName: "arrow.clockwise",
            onPress: { [appState] _ in
                Task {
                    await appState.checkForUpdatesManually()
                }
            }
        )
        checkButton.isEnabled = !appState.isCheckingForUpdates
        stack.addArrangedSubview(checkButton)

        if let update = appState.latestAvailableUpdate {
            stack.addArrangedSubview(actionButton(
                title: "Download Update",
                symbolName: "arrow.down.circle",
                role: .prominent,
                onPress: { [weak self] _ in
                    self?.openUpdateRelease(update)
                }
            ))
        }

        constrainToContentWidth(stack)
        return stack
    }

    private func accountSection() -> NSView {
        let row = horizontalStack(spacing: 12)
        let title = label(accountTitle, font: .mediumBody)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let disconnectButton = actionButton(
            title: "Disconnect",
            role: .destructive,
            onPress: { [weak self] _ in
                self?.confirmDisconnect()
            }
        )
        disconnectButton.isEnabled = appState.isSignedIn

        row.addArrangedSubview(title)
        row.addArrangedSubview(TaskMenuAppKit.spacer())
        row.addArrangedSubview(disconnectButton)
        constrainToContentWidth(row)

        return section("Account", views: [row])
    }

    private func tipsSection() -> NSView {
        section("Tips", views: [
            label(
                "TaskMenu will stay free forever and is developed by one person. If it saves you time, tips are deeply appreciated.",
                font: .callout,
                color: .secondaryLabelColor,
                lines: 0
            ),
            fullWidthButton(
                title: "Buy Me a Coffee",
                symbolName: "heart.fill",
                role: .prominent,
                onPress: { [coffeeURL] _ in
                    NSWorkspace.shared.open(coffeeURL)
                }
            )
        ])
    }

    private func supportSection() -> NSView {
        section("Support", views: [
            label(
                "Noticed a bug or have a feature request? Join our Discord server with the developer and other users!",
                font: .callout,
                color: .secondaryLabelColor,
                lines: 0
            ),
            fullWidthButton(
                title: "Join Discord",
                image: NSImage(named: "DiscordIcon"),
                role: .prominent,
                onPress: { [discordURL] _ in
                    NSWorkspace.shared.open(discordURL)
                }
            )
        ])
    }

    private func aboutSection() -> NSView {
        let links = horizontalStack(spacing: 12)
        links.addArrangedSubview(linkButton(title: "GitHub", symbolName: "link", url: githubURL))
        links.addArrangedSubview(linkButton(title: "Support", symbolName: "questionmark.circle", url: supportURL))
        links.addArrangedSubview(linkButton(title: "Privacy", symbolName: "lock", url: privacyURL))

        return section("About", views: [
            label("TaskMenu v\(appState.currentAppVersion)", font: .callout, color: .secondaryLabelColor),
            links
        ])
    }

    private var accountTitle: String {
        guard appState.isSignedIn else { return "Not signed in" }
        return appState.googleAccountProfile?.displayEmail ?? "Google Account"
    }

    private var updateStatusText: String {
        if appState.isCheckingForUpdates {
            return "Checking for updates…"
        }

        if let errorMessage = appState.updateCheckErrorMessage {
            return "Update check failed: \(errorMessage)"
        }

        if let update = appState.latestAvailableUpdate {
            return "\(update.displayVersion) is available."
        }

        if let lastUpdateCheckDate = appState.lastUpdateCheckDate {
            return "TaskMenu is up to date. Last checked \(relativeDateString(for: lastUpdateCheckDate))."
        }

        return "No update check yet."
    }

    private func confirmDisconnect() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disconnect Google Account?"
        alert.informativeText = "TaskMenu will clear its stored Google credentials and remove local task data from this Mac."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")

        let disconnect: () -> Void = { [appState] in
            Task {
                await appState.disconnectGoogleAccount()
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    disconnect()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            disconnect()
        }
    }

    private func openUpdateRelease(_ release: AppUpdateRelease) {
        appState.markUpdateAlertShown(for: release)
        NSWorkspace.shared.open(release.releaseURL)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Users can retry from Settings if macOS rejects the request.
        }

        render()
    }

    private func relativeDateString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func section(_ title: String, views: [NSView]) -> NSView {
        let stack = verticalStack(spacing: 10)
        let titleLabel = label(title, font: .sectionTitle, color: .secondaryLabelColor)
        stack.addArrangedSubview(titleLabel)

        for view in views {
            if view is NSTextField {
                constrainToContentWidth(view)
            }
            stack.addArrangedSubview(view)
        }

        constrainToContentWidth(stack)
        return stack
    }

    private func toggle(
        title: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> NSView {
        let button = SettingsButton(title: title, buttonType: .switch) { button in
            onChange(button.state == .on)
        }
        button.state = isOn ? .on : .off
        constrainToContentWidth(button)
        return button
    }

    private func linkButton(title: String, symbolName: String, url: URL) -> NSButton {
        actionButton(title: title, symbolName: symbolName) { _ in
            NSWorkspace.shared.open(url)
        }
    }

    private func fullWidthButton(
        title: String,
        symbolName: String? = nil,
        image: NSImage? = nil,
        role: SettingsButtonRole = .standard,
        onPress: @escaping (SettingsButton) -> Void
    ) -> NSButton {
        let button = actionButton(
            title: title,
            symbolName: symbolName,
            image: image,
            role: role,
            controlSize: .large,
            onPress: onPress
        )
        button.alignment = .center
        constrainToContentWidth(button)
        return button
    }

    private func actionButton(
        title: String,
        symbolName: String? = nil,
        image: NSImage? = nil,
        role: SettingsButtonRole = .standard,
        controlSize: NSControl.ControlSize = .regular,
        onPress: @escaping (SettingsButton) -> Void
    ) -> SettingsButton {
        let button = SettingsButton(title: title, onPress: onPress)
        button.bezelStyle = .rounded
        button.controlSize = controlSize
        button.imagePosition = .imageLeading

        if let symbolName {
            button.image = TaskMenuAppKit.symbol(symbolName, pointSize: 13)
        } else if let image {
            let buttonImage = image.copy() as? NSImage ?? image
            buttonImage.isTemplate = false
            buttonImage.size = NSSize(width: 16, height: 16)
            button.image = buttonImage
        }

        switch role {
        case .standard:
            break
        case .prominent:
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        case .destructive:
            button.bezelColor = .systemRed
            button.contentTintColor = .white
        }

        return button
    }

    private func centered(_ view: NSView) -> NSView {
        let stack = horizontalStack(spacing: 0)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        stack.addArrangedSubview(view)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        constrainToContentWidth(stack)
        return stack
    }

    private func separator() -> NSView {
        let separator = TaskMenuAppKit.separator()
        constrainToContentWidth(separator)
        return separator
    }

    private func label(
        _ text: String,
        font: NSFont = .body,
        color: NSColor = .labelColor,
        lines: Int = 1
    ) -> NSTextField {
        let label = TaskMenuAppKit.label(text, font: font, color: color, lines: lines)
        label.preferredMaxLayoutWidth = SettingsLayout.contentWidth
        return label
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func constrainToContentWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    }
}

@MainActor
private enum SettingsButtonRole {
    case standard
    case prominent
    case destructive
}

@MainActor
private final class SettingsButton: NSButton {
    private let onPress: (SettingsButton) -> Void

    init(
        title: String,
        buttonType: NSButton.ButtonType? = nil,
        onPress: @escaping (SettingsButton) -> Void
    ) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(press)
        translatesAutoresizingMaskIntoConstraints = false

        if let buttonType {
            setButtonType(buttonType)
            isBordered = false
        } else {
            setButtonType(.momentaryPushIn)
            isBordered = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func press() {
        onPress(self)
    }
}

@MainActor
private extension NSFont {
    static var body: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    static var mediumBody: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    static var callout: NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    static var sectionTitle: NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    }
}

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
    static let windowHeight: CGFloat = 570
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
            // Let the stack hug its natural height instead of stretching to
            // fill a taller window; the document still grows to contain it.
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: documentView.bottomAnchor,
                constant: -SettingsLayout.contentInsets.bottom
            )
        ])
    }

    private func rootStack() -> NSStackView {
        let stack = verticalStack(spacing: 18)

        stack.addArrangedSubview(preferencesSection())
        stack.addArrangedSubview(updatesSection())
        stack.addArrangedSubview(accountSection())
        stack.addArrangedSubview(communitySection())
        stack.addArrangedSubview(aboutSection())
        stack.addArrangedSubview(centered(
            actionButton(
                title: "Quit TaskMenu",
                onPress: { _ in
                    NSApplication.shared.terminate(nil)
                }
            )
        ))

        return stack
    }

    private func preferencesSection() -> NSView {
        section("General", views: [
            groupBox(rows: [
                switchRow(
                    title: "Launch at login",
                    isOn: SMAppService.mainApp.status == .enabled,
                    onChange: { [weak self] isOn in
                        self?.setLaunchAtLogin(isOn)
                    }
                ),
                switchRow(
                    title: "Due date notifications",
                    isOn: appState.dueDateNotificationsEnabled,
                    onChange: { [appState] isOn in
                        appState.dueDateNotificationsEnabled = isOn
                    }
                ),
                switchRow(
                    title: "Automatically check for updates",
                    isOn: appState.automaticUpdateChecksEnabled,
                    onChange: { [appState] isOn in
                        appState.automaticUpdateChecksEnabled = isOn
                    }
                )
            ])
        ])
    }

    private func updatesSection() -> NSView {
        let checkButton = actionButton(
            title: appState.isCheckingForUpdates ? "Checking…" : "Check Now",
            onPress: { [appState] _ in
                Task {
                    await appState.checkForUpdatesManually()
                }
            }
        )
        checkButton.controlSize = .small
        checkButton.isEnabled = !appState.isCheckingForUpdates

        var rows = [
            settingRow(
                title: "Version \(appState.currentAppVersion)",
                subtitle: updateStatusText,
                subtitleColor: appState.updateCheckErrorMessage == nil ? .secondaryLabelColor : .systemRed,
                control: checkButton
            )
        ]

        if let update = appState.latestAvailableUpdate {
            let downloadButton = actionButton(
                title: "Download",
                symbolName: "arrow.down.circle",
                role: .prominent,
                onPress: { [weak self] _ in
                    self?.openUpdateRelease(update)
                }
            )
            downloadButton.controlSize = .small
            rows.append(settingRow(
                title: "\(update.displayVersion) is available",
                control: downloadButton
            ))
        }

        return section("Updates", views: [groupBox(rows: rows)])
    }

    private func accountSection() -> NSView {
        let disconnectButton = actionButton(
            title: "Disconnect…",
            role: .destructive,
            onPress: { [weak self] _ in
                self?.confirmDisconnect()
            }
        )
        disconnectButton.controlSize = .small
        disconnectButton.isEnabled = appState.isSignedIn

        let title = label(accountTitle)
        title.lineBreakMode = .byTruncatingMiddle

        return section("Account", views: [
            groupBox(rows: [
                settingRow(titleView: title, control: disconnectButton)
            ])
        ])
    }

    private func communitySection() -> NSView {
        let coffeeButton = actionButton(
            title: "Buy Me a Coffee",
            symbolName: "heart.fill",
            role: .prominent,
            onPress: { [coffeeURL] _ in
                NSWorkspace.shared.open(coffeeURL)
            }
        )

        let discordButton = actionButton(
            title: "Join Discord",
            image: NSImage(named: "DiscordIcon"),
            onPress: { [discordURL] _ in
                NSWorkspace.shared.open(discordURL)
            }
        )

        let buttons = horizontalStack(spacing: 8)
        buttons.addArrangedSubview(coffeeButton)
        buttons.addArrangedSubview(discordButton)

        return section("Support TaskMenu", views: [
            label(
                "TaskMenu is free and developed by one person. Tips keep it going, and the Discord is the place for bugs and feature requests.",
                font: .callout,
                color: .secondaryLabelColor,
                lines: 0
            ),
            centered(buttons)
        ])
    }

    private func aboutSection() -> NSView {
        let links = horizontalStack(spacing: 16)
        links.addArrangedSubview(linkButton(title: "GitHub", url: githubURL))
        links.addArrangedSubview(linkButton(title: "Support", url: supportURL))
        links.addArrangedSubview(linkButton(title: "Privacy", url: privacyURL))
        return section("About", views: [links])
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
            return "Up to date · checked \(relativeDateString(for: lastUpdateCheckDate))"
        }

        return "Not checked yet"
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
        guard abs(date.timeIntervalSinceNow) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func section(_ title: String, views: [NSView]) -> NSView {
        let stack = verticalStack(spacing: 8)
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

    /// A rounded inset box holding setting rows separated by hairlines,
    /// matching the meta group styling in the task detail screen.
    private func groupBox(rows: [NSView]) -> NSView {
        let box = SettingsGroupBoxView()
        let stack = verticalStack(spacing: 0)
        stack.alignment = .width
        for (index, row) in rows.enumerated() {
            if index > 0 {
                stack.addArrangedSubview(TaskMenuAppKit.separator())
            }
            stack.addArrangedSubview(row)
        }
        box.addSubview(stack)
        TaskMenuAppKit.pin(stack, to: box)
        constrainToContentWidth(box)
        return box
    }

    private func settingRow(
        title: String,
        subtitle: String? = nil,
        subtitleColor: NSColor = .secondaryLabelColor,
        control: NSView
    ) -> NSView {
        settingRow(titleView: label(title), subtitle: subtitle, subtitleColor: subtitleColor, control: control)
    }

    private func settingRow(
        titleView: NSTextField,
        subtitle: String? = nil,
        subtitleColor: NSColor = .secondaryLabelColor,
        control: NSView
    ) -> NSView {
        let titles = verticalStack(spacing: 2)
        titleView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titles.addArrangedSubview(titleView)
        if let subtitle {
            let subtitleLabel = label(subtitle, font: .callout, color: subtitleColor, lines: 0)
            subtitleLabel.preferredMaxLayoutWidth = SettingsLayout.contentWidth - 120
            titles.addArrangedSubview(subtitleLabel)
        }

        let row = horizontalStack(spacing: 8)
        row.addArrangedSubview(titles)
        row.addArrangedSubview(TaskMenuAppKit.spacer())
        row.addArrangedSubview(control)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        TaskMenuAppKit.pin(
            row,
            to: container,
            insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        )
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        return container
    }

    private func switchRow(
        title: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> NSView {
        let toggle = SettingsSwitch(onChange: onChange)
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.setAccessibilityLabel(title)
        return settingRow(title: title, control: toggle)
    }

    private func linkButton(title: String, url: URL) -> NSButton {
        let button = SettingsButton(title: title) { _ in
            NSWorkspace.shared.open(url)
        }
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.callout
            ]
        )
        return button
    }

    private func actionButton(
        title: String,
        symbolName: String? = nil,
        image: NSImage? = nil,
        role: SettingsButtonRole = .standard,
        onPress: @escaping (SettingsButton) -> Void
    ) -> SettingsButton {
        let button = SettingsButton(title: title, onPress: onPress)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageLeading

        if let symbolName {
            button.image = TaskMenuAppKit.symbol(symbolName, pointSize: 12)
        } else if let image {
            let buttonImage = image.copy() as? NSImage ?? image
            // Single-color asset icons follow the title color as templates.
            buttonImage.isTemplate = true
            buttonImage.size = NSSize(width: 14, height: 14)
            button.image = buttonImage
        }

        switch role {
        case .standard:
            break
        case .prominent:
            button.bezelColor = .controlAccentColor
            // bezelColor does not recolor the title or template image; do both.
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.white]
            )
            if let symbolName {
                button.image = TaskMenuAppKit.symbol(symbolName, pointSize: 12)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
            }
        case .destructive:
            button.hasDestructiveAction = true
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }

        return button
    }

    private func centered(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        constrainToContentWidth(container)
        return container
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

/// Rounded inset background for a group of setting rows; reapplies its
/// layer colors on appearance changes so light/dark switches stay correct.
@MainActor
private final class SettingsGroupBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        applyBackgroundColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColors()
    }

    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.42).cgColor
        }
    }
}

@MainActor
private final class SettingsSwitch: NSSwitch {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange(state == .on)
    }
}

@MainActor
private final class SettingsButton: NSButton {
    private let onPress: (SettingsButton) -> Void

    init(
        title: String,
        onPress: @escaping (SettingsButton) -> Void
    ) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(press)
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryPushIn)
        isBordered = true
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

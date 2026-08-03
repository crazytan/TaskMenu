import AppKit

@MainActor
final class TaskListHeaderView: NSView {
    var onSelectList: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSignOut: (() -> Void)?

    private let listPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = TaskMenuActionButton(
        symbolName: "arrow.clockwise",
        pointSize: 14,
        weight: .medium,
        accessibilityDescription: "Refresh tasks"
    )
    private let overflowButton = TaskMenuActionButton(
        symbolName: "ellipsis",
        pointSize: 15,
        weight: .semibold,
        accessibilityDescription: "More actions"
    )
    private let refreshSpinner = NSProgressIndicator()
    private var refreshSpinnerStopTask: Task<Void, Never>?
    private var representedListIDs: [Int: String] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        listTitle: String,
        taskLists: [TaskList],
        selectedListID: String?,
        isLoading: Bool
    ) {
        rebuildListMenu(taskLists: taskLists, selectedListID: selectedListID)
        listPopup.attributedTitle = headerTitle(listTitle: listTitle)
        listPopup.isEnabled = taskLists.count > 1
        refreshButton.isEnabled = !isLoading
        if isLoading {
            showRefreshSpinner()
        } else {
            hideRefreshSpinnerAfterMinimumDelay()
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: self,
            insets: NSEdgeInsets(top: 9, left: 10, bottom: 8, right: 10)
        )

        listPopup.isBordered = false
        listPopup.font = .systemFont(ofSize: 15)
        listPopup.controlSize = .regular
        listPopup.target = self
        listPopup.action = #selector(listSelectionChanged(_:))
        listPopup.translatesAutoresizingMaskIntoConstraints = false
        listPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        listPopup.toolTip = "Switch task list"
        listPopup.setAccessibilityLabel("Task list")
        stack.addArrangedSubview(listPopup)

        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        stack.addArrangedSubview(refreshControlContainer())
        stack.addArrangedSubview(headerIconContainer(overflowButton))

        refreshButton.onPress = { [weak self] in
            self?.showRefreshSpinner()
            self?.onRefresh?()
        }
        overflowButton.onPress = { [weak self] in
            self?.showOverflowMenu()
        }
    }

    private func rebuildListMenu(
        taskLists: [TaskList],
        selectedListID: String?
    ) {
        representedListIDs = [:]
        let menu = NSMenu()
        menu.autoenablesItems = false

        for list in taskLists {
            let item = NSMenuItem(title: list.title, action: nil, keyEquivalent: "")
            item.target = self
            item.action = #selector(listMenuItemSelected(_:))
            item.state = list.id == selectedListID ? .on : .off
            item.representedObject = list.id
            menu.addItem(item)
        }

        if !taskLists.isEmpty {
            menu.addItem(.separator())
        }
        let newListItem = NSMenuItem(title: "New List…", action: nil, keyEquivalent: "")
        newListItem.isEnabled = false
        menu.addItem(newListItem)

        listPopup.menu = menu
        if let selectedIndex = taskLists.firstIndex(where: { $0.id == selectedListID }) {
            listPopup.selectItem(at: selectedIndex)
        }
    }

    private func headerTitle(listTitle: String) -> NSAttributedString {
        NSAttributedString(
            string: listTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func headerIconContainer(_ button: NSButton) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 26),
            container.heightAnchor.constraint(equalToConstant: 24),
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return container
    }

    private func refreshControlContainer() -> NSView {
        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.setAccessibilityLabel("Refreshing tasks")
        refreshSpinner.isDisplayedWhenStopped = false
        refreshSpinner.isHidden = true
        refreshSpinner.translatesAutoresizingMaskIntoConstraints = false

        let container = headerIconContainer(refreshButton)
        container.addSubview(refreshSpinner)
        NSLayoutConstraint.activate([
            refreshSpinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            refreshSpinner.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func showRefreshSpinner() {
        refreshSpinnerStopTask?.cancel()
        refreshSpinnerStopTask = nil
        refreshButton.isHidden = true
        refreshSpinner.isHidden = false
        refreshSpinner.startAnimation(nil)
    }

    private func hideRefreshSpinnerAfterMinimumDelay() {
        guard !refreshSpinner.isHidden else { return }
        refreshSpinnerStopTask?.cancel()
        refreshSpinnerStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.refreshSpinner.stopAnimation(nil)
            self.refreshSpinner.isHidden = true
            self.refreshButton.isHidden = false
            self.refreshSpinnerStopTask = nil
        }
    }

    private func showOverflowMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak self] in
            self?.onOpenSettings?()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Sign out") { [weak self] in
            self?.onSignOut?()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit") {
            NSApplication.shared.terminate(nil)
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 4), in: overflowButton)
    }

    @objc private func listSelectionChanged(_ sender: NSPopUpButton) {
        guard let listID = sender.selectedItem?.representedObject as? String else { return }
        onSelectList?(listID)
    }

    @objc private func listMenuItemSelected(_ sender: NSMenuItem) {
        guard let listID = sender.representedObject as? String else { return }
        onSelectList?(listID)
    }
}

@MainActor
final class TaskQuickAddView: NSView {
    var onCommit: ((String) -> Void)?
    var onEscapeWithEmptyField: (() -> Void)?

    private let container = NSView()
    private let field = TaskMenuTextField(placeholder: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(listTitle: String) {
        field.placeholderString = "Add a task to \(listTitle)"
    }

    func focusField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColors()
    }

    /// Layer colors are resolved CGColors; reapply them when the effective
    /// appearance changes so light/dark switches don't leave stale colors.
    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.28).cgColor
            container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
            container.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.62).cgColor
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false
        applyBackgroundColors()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 8)
        )

        let plus = NSImageView(image: TaskMenuAppKit.symbol("plus", pointSize: 12, weight: .medium) ?? NSImage())
        plus.contentTintColor = .tertiaryLabelColor
        plus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plus.widthAnchor.constraint(equalToConstant: 12),
            plus.heightAnchor.constraint(equalToConstant: 12)
        ])
        stack.addArrangedSubview(plus)

        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel("Add a task")
        field.onCommit = { [weak self] _ in
            self?.commit()
        }
        field.onEscape = { [weak self] in
            self?.handleEscape()
        }
        stack.addArrangedSubview(field)

        addSubview(container)
        TaskMenuAppKit.pin(
            container,
            to: self,
            insets: NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        )
    }

    private func commit() {
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        field.stringValue = ""
        onCommit?(title)
        focusField()
    }

    private func handleEscape() {
        if field.stringValue.isEmpty {
            onEscapeWithEmptyField?()
        } else {
            field.stringValue = ""
        }
    }
}

@MainActor
final class TaskSearchBarView: NSView {
    var onSearchTextChange: ((String) -> Void)?
    var onEscapeWithEmptyField: (() -> Void)?

    private let container = NSView()
    private let field = TaskMenuTextField(placeholder: "Filter tasks…")
    private let resultCountLabel = TaskMenuAppKit.label(
        "",
        font: .systemFont(ofSize: 11),
        color: .secondaryLabelColor
    )
    private let clearButton = TaskMenuActionButton(
        symbolName: "xmark.circle.fill",
        pointSize: 11,
        weight: .regular,
        accessibilityDescription: "Clear filter"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(searchText: String, isSearching: Bool, resultCount: Int) {
        if field.stringValue != searchText {
            field.stringValue = searchText
        }
        clearButton.isHidden = searchText.isEmpty
        resultCountLabel.isHidden = !isSearching
        resultCountLabel.stringValue = searchResultCountText(resultCount)
    }

    /// Mirrors `TaskQuickAddView.focusField()`. Making the field first responder
    /// selects any existing filter text, which is the expected ⌘F behavior.
    func focusField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColors()
    }

    /// Layer colors are resolved CGColors; reapply them when the effective
    /// appearance changes so light/dark switches don't leave stale colors.
    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
            container.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.62).cgColor
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false
        applyBackgroundColors()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 8)
        )

        let magnifier = NSImageView(
            image: TaskMenuAppKit.symbol("magnifyingglass", pointSize: 12, weight: .medium) ?? NSImage()
        )
        magnifier.contentTintColor = .tertiaryLabelColor
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            magnifier.widthAnchor.constraint(equalToConstant: 12),
            magnifier.heightAnchor.constraint(equalToConstant: 12)
        ])
        stack.addArrangedSubview(magnifier)

        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel("Filter tasks")
        field.onChange = { [weak self] text in
            self?.onSearchTextChange?(text)
        }
        field.onEscape = { [weak self] in
            self?.handleEscape()
        }
        stack.addArrangedSubview(field)

        resultCountLabel.isHidden = true
        stack.addArrangedSubview(resultCountLabel)

        clearButton.refusesFirstResponder = true
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isHidden = true
        clearButton.onPress = { [weak self] in
            self?.clear()
        }
        NSLayoutConstraint.activate([
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16)
        ])
        stack.addArrangedSubview(clearButton)

        addSubview(container)
        TaskMenuAppKit.pin(
            container,
            to: self,
            insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        )
    }

    private func clear() {
        field.stringValue = ""
        onSearchTextChange?("")
    }

    private func handleEscape() {
        if field.stringValue.isEmpty {
            onEscapeWithEmptyField?()
        } else {
            clear()
        }
    }
}

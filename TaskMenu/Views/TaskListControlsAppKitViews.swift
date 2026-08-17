import AppKit

@MainActor
final class TaskListHeaderView: NSView {
    var onSelectList: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onSelectSortOrder: ((TaskSortOrder) -> Void)?
    /// "New List…" was chosen from the list picker.
    var onBeginNewList: (() -> Void)?
    /// Enter in the inline new-list field with a trimmed, non-empty title.
    var onCommitNewList: ((String) -> Void)?
    /// Escape or an empty Enter in the inline new-list field.
    var onCancelNewList: (() -> Void)?
    /// Retitles the sign-out item, which leaves the demo instead.
    var isDemoMode = false
    /// Checkmark state of the "Show two lists side by side" overflow item.
    var isSideBySideEnabled = false
    /// The "Show two lists side by side" overflow item was chosen.
    var onToggleSideBySide: (() -> Void)?
    /// Current sort, reflected as the checkmark in the sort button's menu.
    private var sortOrder: TaskSortOrder = .myOrder

    private let listPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Hosts both the list picker and the inline new-list field so hiding one
    /// never detaches it from the layout (an `NSStackView` drops hidden
    /// arranged subviews, which would change the header height).
    private let listSwitcherContainer = NSView()
    private let newListContainer = NSView()
    private let newListField = TaskMenuTextField(placeholder: "List name")
    private weak var newListMenuItem: NSMenuItem?
    /// Active while composing: asks for more width than the header has at a
    /// priority just above the picker's hugging, so the field grows to fill
    /// what the buttons leave instead of hugging the hidden picker's title.
    private var newListExpandConstraint: NSLayoutConstraint?
    /// Last rendered composer state; visibility and the field's text only
    /// change on transitions so background re-renders never clear typing.
    private var isComposingNewList = false
    /// Selected list from the last render, restored after "New List…" moves
    /// the popup's selection onto itself.
    private var lastSelectedListID: String?
    private let refreshButton = TaskMenuActionButton(
        symbolName: "arrow.clockwise",
        pointSize: 14,
        weight: .medium,
        accessibilityDescription: "Refresh tasks"
    )
    private let sortButton = TaskMenuActionButton(
        symbolName: "arrow.up.arrow.down",
        pointSize: 13,
        weight: .medium,
        accessibilityDescription: "Sort tasks"
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
        sortOrder: TaskSortOrder,
        isLoading: Bool,
        isComposingNewList: Bool = false
    ) {
        self.sortOrder = sortOrder
        lastSelectedListID = selectedListID
        rebuildListMenu(taskLists: taskLists, selectedListID: selectedListID)
        listPopup.attributedTitle = headerTitle(listTitle: listTitle)
        // The menu always ends with "New List…", so the picker stays usable
        // with one list, or none.
        listPopup.isEnabled = true
        if isComposingNewList != self.isComposingNewList {
            self.isComposingNewList = isComposingNewList
            listPopup.isHidden = isComposingNewList
            newListContainer.isHidden = !isComposingNewList
            newListExpandConstraint?.isActive = isComposingNewList
            newListField.stringValue = ""
            if isComposingNewList {
                focusNewListField()
            }
        }
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

        listSwitcherContainer.translatesAutoresizingMaskIntoConstraints = false
        listSwitcherContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        listSwitcherContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        listSwitcherContainer.addSubview(listPopup)
        TaskMenuAppKit.pin(listPopup, to: listSwitcherContainer)
        let expand = listSwitcherContainer.widthAnchor.constraint(equalToConstant: 10_000)
        expand.priority = .defaultLow + 10
        newListExpandConstraint = expand
        setupNewListComposer()
        stack.addArrangedSubview(listSwitcherContainer)

        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        stack.addArrangedSubview(refreshControlContainer())
        stack.addArrangedSubview(headerIconContainer(sortButton))
        stack.addArrangedSubview(headerIconContainer(overflowButton))

        refreshButton.onPress = { [weak self] in
            self?.showRefreshSpinner()
            self?.onRefresh?()
        }
        sortButton.onPress = { [weak self] in
            self?.showSortMenu()
        }
        overflowButton.onPress = { [weak self] in
            self?.showOverflowMenu()
        }
    }

    /// The inline field that replaces the picker while a list is being named.
    /// It sits inside `listSwitcherContainer` at a fixed height so the header
    /// keeps the picker's height whichever of the two is showing.
    private func setupNewListComposer() {
        newListContainer.wantsLayer = true
        newListContainer.layer?.cornerRadius = 7
        newListContainer.layer?.borderWidth = 1
        newListContainer.translatesAutoresizingMaskIntoConstraints = false
        newListContainer.isHidden = true
        applyBackgroundColors()

        newListField.font = .systemFont(ofSize: 13)
        newListField.setAccessibilityLabel("New list name")
        newListField.onCommit = { [weak self] _ in
            self?.commitNewList()
        }
        newListField.onEscape = { [weak self] in
            self?.onCancelNewList?()
        }
        newListContainer.addSubview(newListField)
        TaskMenuAppKit.pin(
            newListField,
            to: newListContainer,
            insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        )

        listSwitcherContainer.addSubview(newListContainer)
        NSLayoutConstraint.activate([
            newListContainer.leadingAnchor.constraint(equalTo: listSwitcherContainer.leadingAnchor),
            newListContainer.trailingAnchor.constraint(equalTo: listSwitcherContainer.trailingAnchor),
            newListContainer.centerYAnchor.constraint(equalTo: listSwitcherContainer.centerYAnchor),
            newListContainer.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColors()
    }

    /// Layer colors are resolved CGColors; reapply them when the effective
    /// appearance changes so light/dark switches don't leave stale colors.
    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            newListContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
            newListContainer.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.62).cgColor
        }
    }

    /// Deferred so the field is in the window before it claims first responder.
    /// Re-entering an active editing session would select the existing text,
    /// and a composer closed again before this runs must not take focus while
    /// hidden.
    private func focusNewListField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isComposingNewList, let window = self.window else { return }
            if let editor = self.newListField.currentEditor(), window.firstResponder === editor {
                return
            }
            window.makeFirstResponder(self.newListField)
        }
    }

    private func commitNewList() {
        let title = newListField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            onCancelNewList?()
            return
        }
        onCommitNewList?(title)
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
        // `representedObject` stays nil so `listSelectionChanged(_:)` never
        // treats it as a list; it is matched by identity instead.
        let newListItem = NSMenuItem(title: "New List…", action: #selector(newListMenuItemSelected(_:)), keyEquivalent: "")
        newListItem.target = self
        newListItem.isEnabled = true
        menu.addItem(newListItem)
        newListMenuItem = newListItem

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

    /// Builds the sort button's menu. Kept separate from `showSortMenu()` so
    /// tests can inspect the items without popping a tracking menu.
    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for order in TaskSortOrder.allCases {
            let item = ClosureMenuItem(title: order.displayName) { [weak self] in
                self?.onSelectSortOrder?(order)
            }
            item.state = order == sortOrder ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func showSortMenu() {
        let menu = sortMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sortButton.bounds.height + 4), in: sortButton)
    }

    /// Builds the "…" menu. Kept separate from `showOverflowMenu()` so tests can
    /// inspect the items without popping a tracking menu.
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let sideBySideItem = ClosureMenuItem(title: "Show two lists side by side") { [weak self] in
            self?.onToggleSideBySide?()
        }
        sideBySideItem.state = isSideBySideEnabled ? .on : .off
        menu.addItem(sideBySideItem)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak self] in
            self?.onOpenSettings?()
        })
        menu.addItem(ClosureMenuItem(title: isDemoMode ? "Exit demo" : "Sign out") { [weak self] in
            self?.onSignOut?()
        })
        menu.addItem(ClosureMenuItem(title: "Quit") {
            NSApplication.shared.terminate(nil)
        })
        return menu
    }

    private func showOverflowMenu() {
        let menu = overflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 4), in: overflowButton)
    }

    @objc private func listSelectionChanged(_ sender: NSPopUpButton) {
        if let listID = sender.selectedItem?.representedObject as? String {
            onSelectList?(listID)
        } else if let selectedItem = sender.selectedItem, selectedItem === newListMenuItem {
            // AppKit may dispatch through the item's action, the popup's
            // action, or both; the controller side is idempotent.
            beginNewList()
        }
    }

    @objc private func listMenuItemSelected(_ sender: NSMenuItem) {
        guard let listID = sender.representedObject as? String else { return }
        onSelectList?(listID)
    }

    @objc private func newListMenuItemSelected(_ sender: NSMenuItem) {
        beginNewList()
    }

    private func beginNewList() {
        // The popup just moved its selection to "New List…"; put it back on
        // the current list so nothing flashes when the picker returns.
        if let lastSelectedListID,
           let index = listPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == lastSelectedListID }) {
            listPopup.selectItem(at: index)
        } else {
            listPopup.select(nil)
        }
        onBeginNewList?()
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

import AppKit

@MainActor
private enum TaskDetailViewMetrics {
    static let horizontalInset: CGFloat = 12
    static let subtaskRowHeight: CGFloat = 32
    static let maxVisibleSubtaskRows: CGFloat = 5
    static var subtaskScrollMaxHeight: CGFloat {
        subtaskRowHeight * maxVisibleSubtaskRows
    }
    static var contentWidth: CGFloat {
        TaskMenuMetrics.popoverWidth - horizontalInset * 2
    }
}

@MainActor
final class TaskDetailAppKitViewController: NSViewController, NSTextViewDelegate {
    private let appState: AppState
    private var task: TaskItem
    private var dueDateState: TaskDetailDueDateState
    private let onDismiss: () -> Void

    private let rootStack = NSStackView()
    /// Internal so tests can type into it before a save or move.
    let titleField = NSTextField()
    private let notesTextView = NSTextView()
    private let notesPlaceholderLabel = TaskMenuAppKit.label(
        "Notes",
        font: .systemFont(ofSize: 13),
        color: .tertiaryLabelColor
    )
    private let dueDateControls = NSStackView()
    /// Internal so tests can inspect the list picker's items and state.
    let listPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtaskScrollView = NSScrollView()
    private let subtaskDocumentView = TaskDetailFlippedDocumentView()
    let subtaskListStack = NSStackView()
    private var subtaskScrollHeightConstraint: NSLayoutConstraint?
    private(set) var addSubtaskField: TaskMenuTextField?
    private(set) var addSubtaskRowView: NSView?
    private var addSubtaskFieldNeedsInitialFocus = false
    private(set) weak var dueDatePicker: NSDatePicker?
    private(set) weak var dueDateCalendarPicker: NSDatePicker?
    private(set) weak var dueDateClearButton: NSButton?
    private weak var dueDateCalendarButton: NSButton?
    private var dueDateCalendarOverlay: NSView?
    private let appStateObserver = TaskMenuAppStateObserver()

    var isDueDateCalendarOpen: Bool { dueDateCalendarOverlay != nil }

    init(appState: AppState, task: TaskItem, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.task = task
        self.dueDateState = TaskDetailDueDateState(task: task)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view = rootStack

        rootStack.addArrangedSubview(header())
        rootStack.addArrangedSubview(TaskMenuAppKit.separator())
        rootStack.addArrangedSubview(content())
        rootStack.addArrangedSubview(footer())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderDueDateControls()
        renderSubtasks()
        observeAppState()
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape closes the calendar first so it does not also discard the edit.
        if isDueDateCalendarOpen {
            closeDueDateCalendar()
            return
        }
        onDismiss()
    }

    func textDidChange(_ notification: Notification) {
        notesPlaceholderLabel.isHidden = !notesTextView.string.isEmpty
    }

    private func header() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 9, left: 10, bottom: 8, right: 10)
        )

        let backButton = TaskMenuActionButton(title: appState.selectedList?.title ?? "Tasks", symbolName: "chevron.left", pointSize: 12, weight: .medium, accessibilityDescription: "Back") { [weak self] in
            self?.onDismiss()
        }
        backButton.imagePosition = .imageLeading
        backButton.contentTintColor = .controlAccentColor
        // Keep long list names from colliding with the centered title.
        backButton.cell?.lineBreakMode = .byTruncatingTail
        backButton.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        stack.addArrangedSubview(backButton)

        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        let doneButton = NSButton(title: "Done", target: self, action: #selector(saveTask))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        stack.addArrangedSubview(doneButton)

        let title = TaskMenuAppKit.label(
            "Edit Task",
            font: .boldSystemFont(ofSize: 13),
            color: .labelColor
        )
        container.addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: stack.centerYAnchor)
        ])

        return container
    }

    private func content() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(
                top: 12,
                left: TaskDetailViewMetrics.horizontalInset,
                bottom: 8,
                right: TaskDetailViewMetrics.horizontalInset
            )
        )

        configureTitleField()
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(notesFieldContainer())
        stack.addArrangedSubview(metaGroup())

        if task.parent == nil {
            stack.addArrangedSubview(TaskMenuAppKit.label(
                "Subtasks",
                font: .boldSystemFont(ofSize: 11),
                color: .secondaryLabelColor
            ))
            stack.addArrangedSubview(subtaskSection())
        }

        stack.addArrangedSubview(detailContentSpacer())

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 386)
        ])
        return container
    }

    private func configureTitleField() {
        titleField.stringValue = task.title
        titleField.placeholderString = "Title"
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.bezelStyle = .roundedBezel
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth).isActive = true
    }

    private func notesFieldContainer() -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        notesTextView.string = task.notes ?? ""
        notesTextView.font = .systemFont(ofSize: 13)
        notesTextView.textColor = .labelColor
        notesTextView.isRichText = false
        notesTextView.allowsUndo = true
        notesTextView.delegate = self
        notesTextView.textContainerInset = NSSize(width: 6, height: 5)
        notesTextView.backgroundColor = .textBackgroundColor
        notesTextView.setAccessibilityLabel("Notes")
        scrollView.documentView = notesTextView

        notesPlaceholderLabel.isHidden = !notesTextView.string.isEmpty
        notesTextView.addSubview(notesPlaceholderLabel)
        NSLayoutConstraint.activate([
            notesPlaceholderLabel.leadingAnchor.constraint(equalTo: notesTextView.leadingAnchor, constant: 11),
            notesPlaceholderLabel.topAnchor.constraint(equalTo: notesTextView.topAnchor, constant: 5)
        ])

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 62)
        ])
        return scrollView
    }

    private func metaGroup() -> NSView {
        let group = TaskDetailGroupBoxView()
        group.orientation = .vertical
        group.alignment = .width
        group.spacing = 0
        group.setContentHuggingPriority(.required, for: .vertical)
        group.setContentCompressionResistancePriority(.required, for: .vertical)
        group.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth).isActive = true

        group.addArrangedSubview(metaRow(label: "Due date", control: dueDateControls))
        group.addArrangedSubview(TaskMenuAppKit.separator())
        group.addArrangedSubview(metaRow(label: "List", control: configuredListPopup()))
        return group
    }

    private func metaRow(label: String, control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(TaskMenuAppKit.label(label, font: .systemFont(ofSize: 13)))
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        stack.addArrangedSubview(control)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        )
        container.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return container
    }

    private func detailContentSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth).isActive = true
        return spacer
    }

    /// The List row: every task list keyed by ID (two lists may share a
    /// title), built once at load like the rest of the meta rows. Enabled for
    /// top-level tasks when there is somewhere else to go; subtasks travel
    /// with their parent, so theirs stays disabled.
    private func configuredListPopup() -> NSPopUpButton {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for list in appState.taskLists {
            let item = NSMenuItem(title: list.title, action: nil, keyEquivalent: "")
            item.representedObject = list.id
            menu.addItem(item)
        }
        listPopup.menu = menu
        if let index = appState.taskLists.firstIndex(where: { $0.id == appState.selectedListId }) {
            listPopup.selectItem(at: index)
        }
        listPopup.controlSize = .small
        listPopup.target = self
        listPopup.action = #selector(listPopupChanged(_:))
        listPopup.setAccessibilityLabel("List")
        let isTopLevel = task.parent == nil
        listPopup.isEnabled = isTopLevel && appState.taskLists.count > 1
        listPopup.toolTip = isTopLevel ? "Move to another list" : "Subtasks move with their parent task"
        return listPopup
    }

    @objc private func listPopupChanged(_ sender: NSPopUpButton) {
        guard let listID = sender.selectedItem?.representedObject as? String,
              listID != appState.selectedListId
        else { return }
        moveTask(toList: listID)
    }

    /// Saves pending edits the way "Done" would, then moves the task and pops
    /// back to the list. Internal so tests can drive it without a menu.
    func moveTask(toList destinationListID: String) {
        closeDueDateCalendar()
        let edited = editedTaskFromFields()
        // Judge "unsaved" against what AppState holds, not the initial copy,
        // since background refreshes update `task` while the editor is open.
        let current = appState.tasks.first { $0.id == task.id } ?? task
        let hasUnsavedEdits = edited.title != current.title
            || edited.notes != current.notes
            || edited.due != current.due
        Task { [appState, onDismiss] in
            if hasUnsavedEdits {
                await appState.updateTask(edited)
            }
            await appState.moveTask(edited, toList: destinationListID)
            onDismiss()
        }
    }

    /// Rebuilt only at load and when the user enables or clears the due date.
    /// Task updates must not reach these controls so the picker instance,
    /// in-progress typing, and first-responder status survive background
    /// refreshes. The calendar overlay writes straight into the existing
    /// picker for the same reason.
    private func renderDueDateControls() {
        closeDueDateCalendar()
        dueDateControls.arrangedSubviews.forEach { view in
            dueDateControls.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        dueDateControls.orientation = .horizontal
        dueDateControls.alignment = .centerY
        dueDateControls.spacing = 6

        if dueDateState.isEnabled {
            let picker = NSDatePicker()
            picker.datePickerElements = .yearMonthDay
            picker.datePickerStyle = .textFieldAndStepper
            picker.controlSize = .small
            picker.dateValue = dueDateState.selection
            picker.target = self
            picker.action = #selector(dueDateChanged(_:))
            dueDateControls.addArrangedSubview(picker)
            dueDatePicker = picker

            let calendarButton = NSButton(
                image: NSImage(
                    systemSymbolName: "calendar",
                    accessibilityDescription: "Choose a due date"
                ) ?? NSImage(),
                target: self,
                action: #selector(toggleDueDateCalendar)
            )
            calendarButton.bezelStyle = .texturedRounded
            calendarButton.controlSize = .small
            calendarButton.imagePosition = .imageOnly
            calendarButton.setAccessibilityLabel("Choose a due date")
            calendarButton.toolTip = "Choose a due date"
            dueDateControls.addArrangedSubview(calendarButton)
            dueDateCalendarButton = calendarButton

            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearDueDate))
            clearButton.isBordered = false
            clearButton.controlSize = .small
            clearButton.contentTintColor = .controlAccentColor
            dueDateControls.addArrangedSubview(clearButton)
            dueDateClearButton = clearButton
        } else {
            dueDatePicker = nil
            dueDateCalendarButton = nil
            dueDateClearButton = nil
            let setButton = NSButton(title: "Set", target: self, action: #selector(enableDueDate))
            setButton.controlSize = .small
            setButton.bezelStyle = .rounded
            dueDateControls.addArrangedSubview(setButton)
        }
    }

    private func subtaskSection() -> NSView {
        subtaskScrollView.translatesAutoresizingMaskIntoConstraints = false
        subtaskScrollView.borderType = .noBorder
        subtaskScrollView.drawsBackground = false
        subtaskScrollView.hasHorizontalScroller = false
        TaskMenuAppKit.configureTaskListScrollIndicators(subtaskScrollView)

        subtaskDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: TaskDetailViewMetrics.contentWidth,
            height: TaskDetailViewMetrics.subtaskRowHeight
        )
        subtaskListStack.orientation = .vertical
        subtaskListStack.alignment = .leading
        subtaskListStack.spacing = 0
        subtaskDocumentView.addSubview(subtaskListStack)
        TaskMenuAppKit.pin(subtaskListStack, to: subtaskDocumentView)
        subtaskScrollView.documentView = subtaskDocumentView

        let heightConstraint = subtaskScrollView.heightAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskRowHeight)
        subtaskScrollHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            subtaskScrollView.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            heightConstraint
        ])
        return subtaskScrollView
    }

    func renderSubtasks() {
        // The add-subtask row is kept alive across renders so an open field's
        // typing and focus survive background task mutations.
        let addRow = currentAddSubtaskRow()
        for view in subtaskListStack.arrangedSubviews where view !== addRow {
            subtaskListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if addRow.superview == nil {
            subtaskListStack.insertArrangedSubview(addRow, at: 0)
        }

        // The add row leads the section, so existing subtasks start below it.
        var index = 1
        for child in subtasksWithCompletedLast(appState.subtasks(of: task.id)) {
            subtaskListStack.insertArrangedSubview(subtaskRow(for: child), at: index)
            index += 1
        }
        updateSubtaskScrollMetrics()
    }

    private func updateSubtaskScrollMetrics() {
        let rowCount = max(subtaskListStack.arrangedSubviews.count, 1)
        let documentHeight = CGFloat(rowCount) * TaskDetailViewMetrics.subtaskRowHeight
        let visibleHeight = min(documentHeight, TaskDetailViewMetrics.subtaskScrollMaxHeight)

        let previousOffset = subtaskScrollView.contentView.bounds.origin.y

        subtaskScrollHeightConstraint?.constant = visibleHeight
        subtaskDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: TaskDetailViewMetrics.contentWidth,
            height: documentHeight
        )
        subtaskScrollView.hasVerticalScroller = documentHeight > visibleHeight

        let restoredOffset = TaskDetailEditing.clampedScrollOffset(
            previousOffset,
            documentHeight: documentHeight,
            visibleHeight: visibleHeight
        )
        subtaskScrollView.contentView.scroll(to: NSPoint(x: 0, y: restoredOffset))
        subtaskScrollView.reflectScrolledClipView(subtaskScrollView.contentView)
    }

    private func subtaskRow(for child: TaskItem) -> NSView {
        let row = TaskDetailSubtaskRow(task: child) { [weak self] in
            Task {
                await self?.appState.toggleTask(child)
            }
        }
        return row
    }

    private func currentAddSubtaskRow() -> NSView {
        if let addSubtaskRowView {
            return addSubtaskRowView
        }
        let row = makeAddSubtaskRow()
        addSubtaskRowView = row
        return row
    }

    private func makeAddSubtaskRow() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        if let addSubtaskField {
            stack.addArrangedSubview(addSubtaskPlusIcon(onPress: nil))
            stack.addArrangedSubview(addSubtaskField)
            addSubtaskField.onCommit = { [weak self] _ in
                self?.addSubtask()
            }
            addSubtaskField.onEscape = { [weak self] in
                self?.closeAddSubtaskField()
            }
            focusAddSubtaskFieldIfNeeded()
            return paddedRow(stack)
        }

        let button = TaskMenuActionButton(title: "Add subtask") { [weak self] in
            self?.openAddSubtaskField()
        }
        button.alignment = .left
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "Add subtask"
        stack.addArrangedSubview(addSubtaskPlusIcon { [weak self] in
            self?.openAddSubtaskField()
        })
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        return paddedRow(stack)
    }

    /// Leading icon column for the add-subtask row. It matches the 22pt toggle
    /// slot in `TaskDetailSubtaskRow` so the plus lines up with the subtask
    /// circles and the title lines up with the subtask labels. The icon is
    /// hidden from accessibility because the row's button already carries the
    /// "Add subtask" label.
    private func addSubtaskPlusIcon(onPress: (() -> Void)?) -> NSView {
        let icon = TaskMenuActionButton(
            symbolName: "plus",
            pointSize: 13,
            weight: .medium,
            accessibilityDescription: "Add subtask",
            onPress: onPress
        )
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])
        return icon
    }

    func openAddSubtaskField() {
        addSubtaskField = TaskMenuTextField(placeholder: "Add subtask")
        addSubtaskField?.setAccessibilityLabel("Add subtask")
        addSubtaskFieldNeedsInitialFocus = true
        rebuildAddSubtaskRow()
    }

    private func closeAddSubtaskField() {
        addSubtaskField = nil
        addSubtaskFieldNeedsInitialFocus = false
        rebuildAddSubtaskRow()
    }

    private func rebuildAddSubtaskRow() {
        if let row = addSubtaskRowView {
            subtaskListStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        addSubtaskRowView = nil
        renderSubtasks()
    }

    /// Focus is requested only when the field was just opened, never from a
    /// re-render, so background task updates cannot steal first responder or
    /// restart (and select-all) an in-progress editing session.
    private func focusAddSubtaskFieldIfNeeded() {
        guard addSubtaskFieldNeedsInitialFocus, let field = addSubtaskField else { return }
        addSubtaskFieldNeedsInitialFocus = false
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            if let editor = field.currentEditor(), window.firstResponder === editor {
                return
            }
            window.makeFirstResponder(field)
        }
    }

    private func paddedRow(_ child: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        TaskMenuAppKit.pin(
            child,
            to: container,
            insets: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        )
        container.heightAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskRowHeight).isActive = true
        container.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth).isActive = true
        return container
    }

    private func footer() -> NSView {
        let container = TaskDetailFooterView()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        )

        let deleteButton = NSButton(title: "Delete Task", target: self, action: #selector(deleteTask))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.hasDestructiveAction = true
        // Bordered buttons ignore contentTintColor for titles; color it directly.
        deleteButton.attributedTitle = NSAttributedString(
            string: "Delete Task",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        stack.addArrangedSubview(deleteButton)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
        return container
    }

    private func observeAppState() {
        appStateObserver.observe { [appState, task] in
            _ = appState.tasks
            _ = appState.subtasks(of: task.id)
        } onChange: { [weak self] in
            self?.syncTaskFromAppState()
            self?.renderSubtasks()
        }
    }

    private func syncTaskFromAppState() {
        guard let updated = appState.tasks.first(where: { $0.id == task.id }) else { return }
        task = updated
    }

    @objc private func enableDueDate() {
        dueDateState.enable()
        renderDueDateControls()
    }

    @objc private func clearDueDate() {
        dueDateState.clear()
        renderDueDateControls()
    }

    @objc private func dueDateChanged(_ sender: NSDatePicker) {
        dueDateState.selection = sender.dateValue
    }

    @objc private func toggleDueDateCalendar() {
        if isDueDateCalendarOpen {
            closeDueDateCalendar()
        } else {
            openDueDateCalendar()
        }
    }

    /// Shows the graphical calendar inside the detail view rather than in an
    /// `NSPopover`. A nested popover would live in its own window, which both
    /// the status item's `.transient` popover and its outside-click monitors
    /// treat as a click elsewhere, closing the whole task detail mid-edit.
    func openDueDateCalendar() {
        guard !isDueDateCalendarOpen, dueDateState.isEnabled, let anchor = dueDateCalendarButton else { return }

        let scrim = TaskDetailCalendarScrimView()
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.onClickOutside = { [weak self] in
            self?.closeDueDateCalendar()
        }

        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false

        let calendar = NSDatePicker()
        calendar.datePickerElements = .yearMonthDay
        calendar.datePickerStyle = .clockAndCalendar
        calendar.drawsBackground = false
        calendar.isBordered = false
        calendar.dateValue = dueDatePicker?.dateValue ?? dueDateState.selection
        calendar.target = self
        calendar.action = #selector(dueDateCalendarChanged(_:))
        calendar.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(calendar)
        scrim.addSubview(panel)
        view.addSubview(scrim, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            calendar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            calendar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            calendar.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            calendar.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),

            panel.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 6),
            panel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -TaskDetailViewMetrics.horizontalInset
            ),
            panel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: TaskDetailViewMetrics.horizontalInset
            )
        ])

        // Prefer right-alignment with the calendar button, but let the
        // inset constraints above win if that would overflow the popover.
        let preferredTrailing = panel.trailingAnchor.constraint(equalTo: anchor.trailingAnchor)
        preferredTrailing.priority = .defaultHigh
        preferredTrailing.isActive = true

        dueDateCalendarOverlay = scrim
        dueDateCalendarPicker = calendar
        view.window?.makeFirstResponder(calendar)
    }

    func closeDueDateCalendar() {
        guard let overlay = dueDateCalendarOverlay else { return }
        overlay.removeFromSuperview()
        dueDateCalendarOverlay = nil
        dueDateCalendarPicker = nil
    }

    @objc private func dueDateCalendarChanged(_ sender: NSDatePicker) {
        dueDateState.selection = sender.dateValue
        // Write into the existing picker instead of rebuilding the row so the
        // picker instance and first-responder status survive.
        dueDatePicker?.dateValue = sender.dateValue
        closeDueDateCalendar()
    }

    /// Reads the title, notes, and due-date fields into `task` and returns
    /// the task as "Done" would save it. Shared by save and move so the two
    /// cannot drift.
    private func editedTaskFromFields() -> TaskItem {
        task.title = TaskDetailEditing.effectiveTitle(fieldText: titleField.stringValue, existingTitle: task.title)
        let notes = notesTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        task.notes = notes.isEmpty ? nil : notes
        if dueDateState.isEnabled, let dueDatePicker {
            dueDateState.selection = dueDatePicker.dateValue
        }
        return dueDateState.applying(to: task)
    }

    @objc private func saveTask() {
        let updatedTask = editedTaskFromFields()
        Task { [appState, onDismiss] in
            await appState.updateTask(updatedTask)
            onDismiss()
        }
    }

    @objc private func deleteTask() {
        let task = task
        Task { [appState, onDismiss] in
            await appState.deleteTask(task)
            onDismiss()
        }
    }

    private func addSubtask() {
        guard let field = addSubtaskField else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        field.stringValue = ""
        Task { [appState, task] in
            await appState.addSubtask(title: title, parentId: task.id)
        }
    }
}

/// Transparent full-bleed layer behind the due-date calendar. It stays inside
/// the detail view's own window so dismissing the calendar never reads as a
/// click outside the status item popover. Clicks that the calendar itself does
/// not consume land here and close it.
@MainActor
final class TaskDetailCalendarScrimView: NSView {
    var onClickOutside: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClickOutside?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClickOutside?()
    }
}

@MainActor
private final class TaskDetailSubtaskRow: NSView {
    init(task: TaskItem, onToggle: @escaping () -> Void) {
        super.init(frame: .zero)
        setup(task: task, onToggle: onToggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(task: TaskItem, onToggle: @escaping () -> Void) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            heightAnchor.constraint(equalToConstant: TaskDetailViewMetrics.subtaskRowHeight)
        ])

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: self,
            insets: NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        )

        let toggle = TaskMenuActionButton(
            symbolName: task.isCompleted ? "checkmark.circle.fill" : "circle",
            pointSize: 16,
            accessibilityDescription: task.isCompleted ? "Mark incomplete" : "Mark complete",
            onPress: onToggle
        )
        toggle.contentTintColor = task.isCompleted ? .controlAccentColor : .secondaryLabelColor
        toggle.usesPointingHandCursor = true
        NSLayoutConstraint.activate([
            toggle.widthAnchor.constraint(equalToConstant: 22),
            toggle.heightAnchor.constraint(equalToConstant: 22)
        ])
        stack.addArrangedSubview(toggle)

        let label = TaskMenuAppKit.label(
            task.title,
            font: .systemFont(ofSize: 12.5),
            color: task.isCompleted ? .tertiaryLabelColor : .labelColor
        )
        if task.isCompleted {
            let attributed = NSMutableAttributedString(string: task.title)
            attributed.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: attributed.length)
            )
            attributed.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: 0, length: attributed.length)
            )
            label.attributedStringValue = attributed
        }
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())
    }
}

@MainActor
private final class TaskDetailFlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// Rounded inset background for the detail meta rows; reapplies its
/// layer colors on appearance changes so light/dark switches stay correct.
@MainActor
final class TaskDetailGroupBoxView: NSStackView {
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

    /// Layer colors are resolved CGColors; reapply them when the effective
    /// appearance changes so light/dark switches don't leave stale colors.
    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.42).cgColor
        }
    }
}

/// Footer strip behind the delete action; reapplies its layer color on
/// appearance changes so light/dark switches stay correct.
@MainActor
final class TaskDetailFooterView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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

    /// Layer colors are resolved CGColors; reapply them when the effective
    /// appearance changes so light/dark switches don't leave stale colors.
    private func applyBackgroundColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.28).cgColor
        }
    }
}

enum TaskDetailEditing {
    /// Returns the title to save: the trimmed field text, or the existing title
    /// when the field trims to empty (matching the quick-add field's no-empty rule).
    static func effectiveTitle(fieldText: String, existingTitle: String) -> String {
        let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? existingTitle : trimmed
    }

    /// Clamps a scroll offset to the valid range for the current document,
    /// where the max offset is `documentHeight - visibleHeight` with a floor of 0.
    static func clampedScrollOffset(
        _ offset: CGFloat,
        documentHeight: CGFloat,
        visibleHeight: CGFloat
    ) -> CGFloat {
        let maxOffset = max(documentHeight - visibleHeight, 0)
        return min(max(offset, 0), maxOffset)
    }
}

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
    private let titleField = NSTextField()
    private let notesTextView = NSTextView()
    private let dueDateControls = NSStackView()
    private let listPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtaskScrollView = NSScrollView()
    private let subtaskDocumentView = TaskDetailFlippedDocumentView()
    private let subtaskListStack = NSStackView()
    private var subtaskScrollHeightConstraint: NSLayoutConstraint?
    private var addSubtaskField: TaskMenuTextField?
    private let appStateObserver = TaskMenuAppStateObserver()

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
        renderSubtasks()
        observeAppState()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss()
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
        scrollView.documentView = notesTextView

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: TaskDetailViewMetrics.contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 62)
        ])
        return scrollView
    }

    private func metaGroup() -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .width
        group.spacing = 0
        group.wantsLayer = true
        group.layer?.cornerRadius = 8
        group.layer?.borderWidth = 1
        group.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        group.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.42).cgColor
        group.translatesAutoresizingMaskIntoConstraints = false
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

    private func configuredListPopup() -> NSPopUpButton {
        listPopup.removeAllItems()
        listPopup.addItems(withTitles: appState.taskLists.map(\.title))
        if let selectedList = appState.selectedList {
            listPopup.selectItem(withTitle: selectedList.title)
        }
        listPopup.controlSize = .small
        listPopup.isEnabled = false
        listPopup.toolTip = "Moving tasks between lists is not wired yet."
        return listPopup
    }

    private func renderDueDateControls() {
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

            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearDueDate))
            clearButton.isBordered = false
            clearButton.controlSize = .small
            clearButton.contentTintColor = .controlAccentColor
            dueDateControls.addArrangedSubview(clearButton)
        } else {
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

    private func renderSubtasks() {
        renderDueDateControls()
        subtaskListStack.arrangedSubviews.forEach { view in
            subtaskListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for child in subtasksWithCompletedLast(appState.subtasks(of: task.id)) {
            subtaskListStack.addArrangedSubview(subtaskRow(for: child))
        }
        subtaskListStack.addArrangedSubview(addSubtaskGhostRow())
        updateSubtaskScrollMetrics()
    }

    private func updateSubtaskScrollMetrics() {
        let rowCount = max(subtaskListStack.arrangedSubviews.count, 1)
        let documentHeight = CGFloat(rowCount) * TaskDetailViewMetrics.subtaskRowHeight
        let visibleHeight = min(documentHeight, TaskDetailViewMetrics.subtaskScrollMaxHeight)

        subtaskScrollHeightConstraint?.constant = visibleHeight
        subtaskDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: TaskDetailViewMetrics.contentWidth,
            height: documentHeight
        )
        subtaskScrollView.hasVerticalScroller = documentHeight > visibleHeight
        subtaskScrollView.contentView.scroll(to: .zero)
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

    private func addSubtaskGhostRow() -> NSView {
        if let addSubtaskField {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.addArrangedSubview(TaskMenuAppKit.label("+", font: .systemFont(ofSize: 14), color: .tertiaryLabelColor))
            stack.addArrangedSubview(addSubtaskField)
            addSubtaskField.onCommit = { [weak self] _ in
                self?.addSubtask()
            }
            addSubtaskField.onEscape = { [weak self] in
                self?.addSubtaskField = nil
                self?.renderSubtasks()
            }
            DispatchQueue.main.async { [weak addSubtaskField] in
                addSubtaskField?.window?.makeFirstResponder(addSubtaskField)
            }
            return paddedRow(stack)
        }

        let button = TaskMenuActionButton(title: "Add subtask", symbolName: "plus", pointSize: 11, weight: .medium, accessibilityDescription: "Add subtask") { [weak self] in
            self?.addSubtaskField = TaskMenuTextField(placeholder: "Add subtask")
            self?.renderSubtasks()
        }
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.contentTintColor = .tertiaryLabelColor
        return paddedRow(button)
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
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.28).cgColor

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
        deleteButton.contentTintColor = .systemRed
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

    @objc private func saveTask() {
        task.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notesTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        task.notes = notes.isEmpty ? nil : notesTextView.string
        let updatedTask = dueDateState.applying(to: task)
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

import AppKit

@MainActor
final class TaskListHeaderView: NSView {
    var onShowListPicker: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?

    private let listTitleButton = TaskMenuActionButton()
    private let trailingStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(listTitle: String, listCount: Int, isLoading: Bool) {
        listTitleButton.title = listTitle
        listTitleButton.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        listTitleButton.image = listCount > 1
            ? TaskMenuAppKit.symbol("chevron.down", pointSize: 10, weight: .semibold)
            : nil
        listTitleButton.imagePosition = .imageTrailing
        listTitleButton.isEnabled = listCount > 1

        trailingStack.arrangedSubviews.forEach { view in
            trailingStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        trailingStack.addArrangedSubview(headerIconButton(
            symbolName: "gear",
            toolTip: "Settings"
        ) { [weak self] in
            self?.onOpenSettings?()
        })

        if isLoading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: 24),
                spinner.heightAnchor.constraint(equalToConstant: 24)
            ])
            trailingStack.addArrangedSubview(spinner)
        } else {
            trailingStack.addArrangedSubview(headerIconButton(
                symbolName: "arrow.clockwise",
                toolTip: "Refresh tasks"
            ) { [weak self] in
                self?.onRefresh?()
            })
        }
    }

    func showListPickerMenu(
        taskLists: [TaskList],
        selectedListID: String?,
        onSelect: @escaping (String) -> Void
    ) {
        guard taskLists.count > 1 else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        for list in taskLists {
            let item = ClosureMenuItem(title: list.title) {
                onSelect(list.id)
            }
            if list.id == selectedListID {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: listTitleButton.bounds.height), in: listTitleButton)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: self,
            insets: NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        )

        listTitleButton.onPress = { [weak self] in
            self?.onShowListPicker?()
        }
        stack.addArrangedSubview(listTitleButton)
        stack.addArrangedSubview(TaskMenuAppKit.spacer())

        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 4
        stack.addArrangedSubview(trailingStack)
    }

    private func headerIconButton(
        symbolName: String,
        toolTip: String,
        onPress: @escaping () -> Void
    ) -> NSButton {
        let button = TaskMenuActionButton(
            symbolName: symbolName,
            pointSize: 15,
            weight: .medium,
            accessibilityDescription: toolTip,
            onPress: onPress
        )
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }
}

@MainActor
final class TaskQuickAddView: NSView {
    var onCommit: ((String) -> Void)?

    private let field = TaskMenuTextField(placeholder: "Add a task...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let container = TaskMenuHoverView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        )

        let addButton = TaskMenuActionButton(
            symbolName: "plus.circle.fill",
            pointSize: 16,
            accessibilityDescription: "Add task"
        ) { [weak self] in
            self?.commit()
        }
        addButton.contentTintColor = .systemBlue
        stack.addArrangedSubview(addButton)

        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.onCommit = { [weak self] _ in
            self?.commit()
        }
        stack.addArrangedSubview(field)

        addSubview(container)
        TaskMenuAppKit.pin(
            container,
            to: self,
            insets: NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
        )
    }

    private func commit() {
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        field.stringValue = ""
        onCommit?(title)
    }
}

@MainActor
final class TaskSearchBarView: NSView {
    var onChange: ((String) -> Void)?

    private let field = TaskMenuTextField(placeholder: "Filter tasks...")
    private let clearButton = TaskMenuActionButton(
        symbolName: "xmark.circle.fill",
        pointSize: 11,
        accessibilityDescription: "Clear search"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(text: String) {
        if field.stringValue != text {
            field.stringValue = text
        }
        clearButton.isHidden = text.isEmpty
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let container = TaskMenuHoverView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        container.addSubview(stack)
        TaskMenuAppKit.pin(
            stack,
            to: container,
            insets: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        )

        let magnifier = NSImageView(image: TaskMenuAppKit.symbol("magnifyingglass", pointSize: 11) ?? NSImage())
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            magnifier.widthAnchor.constraint(equalToConstant: 14),
            magnifier.heightAnchor.constraint(equalToConstant: 14)
        ])
        stack.addArrangedSubview(magnifier)

        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.onChange = { [weak self] text in
            self?.clearButton.isHidden = text.isEmpty
            self?.onChange?(text)
        }
        stack.addArrangedSubview(field)

        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.onPress = { [weak self] in
            self?.field.stringValue = ""
            self?.clearButton.isHidden = true
            self?.onChange?("")
        }
        stack.addArrangedSubview(clearButton)

        addSubview(container)
        TaskMenuAppKit.pin(
            container,
            to: self,
            insets: NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
        )
    }
}

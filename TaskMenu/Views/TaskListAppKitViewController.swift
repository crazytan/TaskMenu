import AppKit

@MainActor
final class TaskListAppKitViewController: NSViewController {
    private let appState: AppState
    private let onOpenSettings: () -> Void
    private let appStateObserver = TaskMenuAppStateObserver()

    private var selectedTask: TaskItem?
    private var showCompleted = false
    private var inlineSubtaskParentID: String?
    private var revealedCompletedSubtaskParentIDs: Set<String> = []

    private let rootStack = NSStackView()
    private let headerView = TaskListHeaderView()
    private let quickAddView = TaskQuickAddView()
    private let searchView = TaskSearchBarView()
    private var contentView: TaskListContentView?

    init(appState: AppState, onOpenSettings: @escaping () -> Void) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(
            width: TaskMenuMetrics.popoverWidth,
            height: TaskMenuMetrics.signedInPopoverHeight
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            appStateObserver.invalidate()
        }
    }

    override func loadView() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view = rootStack

        NSLayoutConstraint.activate([
            rootStack.widthAnchor.constraint(equalToConstant: TaskMenuMetrics.popoverWidth)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        buildListScreen()
        observeAppState()
    }

    private func configureControls() {
        headerView.onShowListPicker = { [weak self] in
            self?.showListPicker()
        }
        headerView.onOpenSettings = onOpenSettings
        headerView.onRefresh = { [appState] in
            Task {
                await appState.refreshTasks()
            }
        }

        quickAddView.onCommit = { [appState] title in
            Task {
                await appState.addTask(title: title)
            }
        }

        searchView.onChange = { [weak self] text in
            self?.appState.searchText = text
            self?.renderListContent()
        }
    }

    private func buildListScreen() {
        contentView = nil
        children.forEach { child in
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        rootStack.arrangedSubviews.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let selectedTask {
            let detailController = TaskDetailAppKitViewController(appState: appState, task: selectedTask) { [weak self] in
                self?.selectedTask = nil
                self?.buildListScreen()
            }
            addChild(detailController)
            rootStack.addArrangedSubview(detailController.view)
            return
        }

        let contentView = TaskListContentView()
        self.contentView = contentView
        configureContentView(contentView)

        rootStack.addArrangedSubview(headerView)
        rootStack.addArrangedSubview(quickAddView)
        rootStack.addArrangedSubview(searchView)
        rootStack.addArrangedSubview(TaskMenuAppKit.separator())
        rootStack.addArrangedSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1)
        ])

        renderListScreen()
    }

    private func configureContentView(_ contentView: TaskListContentView) {
        contentView.onOpenTask = { [weak self] task in
            self?.selectedTask = task
            self?.buildListScreen()
        }
        contentView.onToggleTask = { [appState] task in
            Task {
                await appState.toggleTask(task)
            }
        }
        contentView.onDeleteTask = { [appState] task in
            Task {
                await appState.deleteTask(task)
            }
        }
        contentView.onToggleCollapsed = { [weak self] taskID in
            self?.appState.toggleCollapsed(taskID)
            self?.renderListContent()
        }
        contentView.onAddSubtaskRequested = { [weak self] task in
            self?.triggerInlineSubtask(for: task)
        }
        contentView.onIndentTask = { [appState] task in
            Task {
                await appState.indentTask(task)
            }
        }
        contentView.onOutdentTask = { [appState] task in
            Task {
                await appState.outdentTask(task)
            }
        }
        contentView.onToggleCompletedSection = { [weak self] in
            self?.showCompleted.toggle()
            self?.renderListContent()
        }
        contentView.onToggleCompletedSubtasksReveal = { [weak self] parentID in
            self?.toggleCompletedSubtasksReveal(for: parentID)
        }
        contentView.onInlineSubtaskCommit = { [appState] title, parentID in
            Task {
                await appState.addSubtask(title: title, parentId: parentID)
            }
        }
        contentView.onInlineSubtaskDismiss = { [weak self] in
            self?.inlineSubtaskParentID = nil
            self?.renderListContent()
        }
    }

    private func renderListScreen() {
        headerView.render(
            listTitle: appState.selectedList?.title ?? "Tasks",
            listCount: appState.taskLists.count,
            isLoading: appState.isLoading
        )
        searchView.render(text: appState.searchText)
        renderListContent()
    }

    private func renderListContent() {
        contentView?.render(
            appState: appState,
            showCompleted: showCompleted,
            inlineSubtaskParentID: inlineSubtaskParentID,
            revealedCompletedSubtaskParentIDs: revealedCompletedSubtaskParentIDs
        )
    }

    private func triggerInlineSubtask(for task: TaskItem) {
        if appState.collapsedTaskIDs.contains(task.id) {
            appState.toggleCollapsed(task.id)
        }
        inlineSubtaskParentID = task.id
        renderListContent()
    }

    private func toggleCompletedSubtasksReveal(for parentID: String) {
        if revealedCompletedSubtaskParentIDs.contains(parentID) {
            revealedCompletedSubtaskParentIDs.remove(parentID)
        } else {
            revealedCompletedSubtaskParentIDs.insert(parentID)
        }
        renderListContent()
    }

    private func showListPicker() {
        headerView.showListPickerMenu(
            taskLists: appState.taskLists,
            selectedListID: appState.selectedListId
        ) { [appState] listID in
            Task {
                await appState.selectList(listID)
            }
        }
    }

    private func observeAppState() {
        appStateObserver.observe { [appState] in
            _ = appState.isLoading
            _ = appState.taskLists
            _ = appState.selectedListId
            _ = appState.selectedList
            _ = appState.tasks
            _ = appState.collapsedTaskIDs
        } onChange: { [weak self] in
            self?.renderListScreen()
        }
    }
}

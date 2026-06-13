import AppKit

@MainActor
final class TaskListAppKitViewController: NSViewController {
    private let appState: AppState
    private let onOpenSettings: () -> Void
    private let onRequestClose: () -> Void
    private let appStateObserver = TaskMenuAppStateObserver()

    private var selectedTask: TaskItem?
    private var showCompleted = false
    private var expandedCompletedSubtaskParentIDs: Set<String> = []
    private var preservedListScrollOffset: NSPoint?

    private let rootStack = NSStackView()
    private let headerView = TaskListHeaderView()
    private let quickAddView = TaskQuickAddView()
    private var contentView: TaskListContentView?

    init(
        appState: AppState,
        onOpenSettings: @escaping () -> Void,
        onRequestClose: @escaping () -> Void
    ) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        self.onRequestClose = onRequestClose
        super.init(nibName: nil, bundle: nil)
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
        rootStack.alignment = .width
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view = rootStack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        buildListScreen()
        observeAppState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        quickAddView.focusField()
    }

    private func configureControls() {
        headerView.onSelectList = { [weak self] listID in
            self?.selectList(listID)
        }
        headerView.onOpenSettings = onOpenSettings
        headerView.onRefresh = { [appState] in
            Task {
                await appState.refreshTasks()
            }
        }
        headerView.onSignOut = { [appState] in
            appState.signOut()
        }

        quickAddView.onCommit = { [weak self] title in
            self?.contentView?.flashTask(title: title)
            Task {
                await self?.appState.addTask(title: title)
            }
        }
        quickAddView.onEscapeWithEmptyField = { [weak self] in
            self?.onRequestClose()
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
                self?.returnToList()
            }
            addChild(detailController)
            rootStack.addArrangedSubview(detailController.view)
            return
        }

        let contentView = TaskListContentView()
        self.contentView = contentView
        configureContentView(contentView)

        rootStack.addArrangedSubview(headerView)
        rootStack.addArrangedSubview(TaskMenuAppKit.separator())
        rootStack.addArrangedSubview(contentView)
        rootStack.addArrangedSubview(TaskMenuAppKit.separator())
        rootStack.addArrangedSubview(quickAddView)
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1)
        ])

        renderListScreen()
        if let preservedListScrollOffset {
            contentView.restoreScrollOffset(preservedListScrollOffset)
            self.preservedListScrollOffset = nil
        }
    }

    private func configureContentView(_ contentView: TaskListContentView) {
        contentView.onOpenTask = { [weak self] task in
            self?.preservedListScrollOffset = self?.contentView?.scrollOffset
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
            Task { @MainActor [weak self] in
                self?.appState.toggleCollapsed(taskID)
                self?.renderListContent()
            }
        }
        contentView.onToggleCompletedSection = { [weak self] in
            Task { @MainActor [weak self] in
                self?.showCompleted.toggle()
                self?.renderListContent()
            }
        }
        contentView.onToggleCompletedSubtasks = { [weak self] parentID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if expandedCompletedSubtaskParentIDs.contains(parentID) {
                    expandedCompletedSubtaskParentIDs.remove(parentID)
                } else {
                    expandedCompletedSubtaskParentIDs.insert(parentID)
                }
                renderListContent()
            }
        }
    }

    private func renderListScreen() {
        headerView.render(
            listTitle: appState.selectedList?.title ?? "Tasks",
            taskLists: appState.taskLists,
            selectedListID: appState.selectedListId,
            isLoading: appState.isLoading
        )
        quickAddView.render(listTitle: appState.selectedList?.title ?? "Tasks")
        renderListContent()
    }

    private func renderListContent() {
        contentView?.render(
            appState: appState,
            showCompleted: showCompleted,
            expandedCompletedSubtaskParentIDs: expandedCompletedSubtaskParentIDs
        )
    }

    private func selectList(_ listID: String) {
        guard listID != appState.selectedListId else { return }
        showCompleted = false
        expandedCompletedSubtaskParentIDs = []
        Task { [appState] in
            await appState.selectList(listID)
        }
    }

    private func returnToList() {
        selectedTask = nil
        buildListScreen()
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

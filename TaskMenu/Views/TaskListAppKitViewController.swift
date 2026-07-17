import AppKit

@MainActor
final class TaskListAppKitViewController: NSViewController {
    private let appState: AppState
    private let onOpenSettings: () -> Void
    private let onRequestClose: () -> Void
    private let appStateObserver = TaskMenuAppStateObserver()

    private var showCompleted = false
    private var expandedCompletedSubtaskParentIDs: Set<String> = []

    private let containerView = NSView()
    private let listPageView = NSStackView()
    private let headerView = TaskListHeaderView()
    private let searchBarView = TaskSearchBarView()
    private let quickAddView = TaskQuickAddView()
    private let contentView = TaskListContentView()

    private var detailController: TaskDetailAppKitViewController?
    private var detailPageView: NSView?
    private var listLeadingConstraint: NSLayoutConstraint?
    private var detailLeadingConstraint: NSLayoutConstraint?
    private var isTransitioningDetail = false

    /// How far the list page parallax-slides behind an incoming detail page.
    private static let listParallaxFactor: CGFloat = 0.3
    private static let detailTransitionDuration: TimeInterval = 0.28

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
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        buildListPage()
        renderListScreen()
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
            // Clear any active filter so the new task is visible and can flash.
            self?.appState.searchText = ""
            Task { [weak self] in
                guard let task = await self?.appState.addTask(title: title) else { return }
                self?.contentView.flashTask(taskID: task.id)
            }
        }
        quickAddView.onEscapeWithEmptyField = { [weak self] in
            self?.onRequestClose()
        }

        searchBarView.onSearchTextChange = { [weak self] text in
            self?.appState.searchText = text
        }
        searchBarView.onEscapeWithEmptyField = { [weak self] in
            self?.onRequestClose()
        }
    }

    private func buildListPage() {
        configureContentView(contentView)

        listPageView.orientation = .vertical
        listPageView.alignment = .width
        listPageView.spacing = 0
        listPageView.translatesAutoresizingMaskIntoConstraints = false

        listPageView.addArrangedSubview(headerView)
        listPageView.addArrangedSubview(TaskMenuAppKit.separator())
        listPageView.addArrangedSubview(searchBarView)
        listPageView.addArrangedSubview(TaskMenuAppKit.separator())
        listPageView.addArrangedSubview(contentView)
        listPageView.addArrangedSubview(TaskMenuAppKit.separator())
        listPageView.addArrangedSubview(quickAddView)

        containerView.addSubview(listPageView)
        let leading = listPageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
        listLeadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            listPageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            listPageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            listPageView.widthAnchor.constraint(equalTo: containerView.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1)
        ])
    }

    // MARK: - Detail Navigation

    /// Pushes the edit screen over the list with a navigation slide; the list
    /// page parallax-slides behind it. Skips motion when the user prefers
    /// reduced motion.
    private func presentTaskDetail(for task: TaskItem) {
        guard detailController == nil, !isTransitioningDetail else { return }

        let detail = TaskDetailAppKitViewController(appState: appState, task: task) { [weak self] in
            self?.dismissTaskDetail()
        }
        addChild(detail)
        detailController = detail

        // An opaque-ish backing occludes the list page while the detail page
        // slides over it, matching the popover material.
        let pageView = NSVisualEffectView()
        pageView.material = .popover
        pageView.blendingMode = .withinWindow
        pageView.state = .active
        pageView.translatesAutoresizingMaskIntoConstraints = false
        let detailView = detail.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        pageView.addSubview(detailView)
        TaskMenuAppKit.pin(detailView, to: pageView)

        containerView.addSubview(pageView)
        let leading = pageView.leadingAnchor.constraint(
            equalTo: containerView.leadingAnchor,
            constant: containerView.bounds.width
        )
        detailLeadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            pageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            pageView.widthAnchor.constraint(equalTo: containerView.widthAnchor)
        ])
        detailPageView = pageView

        guard shouldAnimateDetailTransition else {
            leading.constant = 0
            listPageView.isHidden = true
            return
        }

        containerView.layoutSubtreeIfNeeded()
        isTransitioningDetail = true
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            guard let self else { return }
            context.duration = Self.detailTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            leading.constant = 0
            listLeadingConstraint?.constant = -containerView.bounds.width * Self.listParallaxFactor
            containerView.layoutSubtreeIfNeeded()
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.listPageView.isHidden = true
                self.isTransitioningDetail = false
            }
        })
    }

    /// Pops the edit screen and slides the list page back into place.
    private func dismissTaskDetail() {
        guard let detail = detailController, !isTransitioningDetail else { return }

        listPageView.isHidden = false

        guard shouldAnimateDetailTransition else {
            listLeadingConstraint?.constant = 0
            removeDetail(detail)
            return
        }

        isTransitioningDetail = true
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            guard let self else { return }
            context.duration = Self.detailTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            detailLeadingConstraint?.constant = containerView.bounds.width
            listLeadingConstraint?.constant = 0
            containerView.layoutSubtreeIfNeeded()
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removeDetail(detail)
                self.isTransitioningDetail = false
            }
        })
    }

    private func removeDetail(_ detail: TaskDetailAppKitViewController) {
        detail.view.removeFromSuperview()
        detail.removeFromParent()
        detailPageView?.removeFromSuperview()
        detailPageView = nil
        detailController = nil
        detailLeadingConstraint = nil
    }

    private var shouldAnimateDetailTransition: Bool {
        view.window != nil
            && containerView.bounds.width > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func configureContentView(_ contentView: TaskListContentView) {
        contentView.onOpenTask = { [weak self] task in
            self?.presentTaskDetail(for: task)
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
        contentView.onMoveTask = { [appState] task, newParentID, previousTaskID in
            Task {
                await appState.moveTask(task, toParent: newParentID, after: previousTaskID)
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
        searchBarView.render(
            searchText: appState.searchText,
            isSearching: appState.isSearching,
            resultCount: appState.searchFilteredTasks.count
        )
        renderListContent()
    }

    private func renderListContent() {
        contentView.render(
            appState: appState,
            showCompleted: showCompleted,
            expandedCompletedSubtaskParentIDs: expandedCompletedSubtaskParentIDs
        )
    }

    private func selectList(_ listID: String) {
        guard listID != appState.selectedListId else { return }
        showCompleted = false
        expandedCompletedSubtaskParentIDs = []
        appState.searchText = ""
        Task { [appState] in
            await appState.selectList(listID)
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
            _ = appState.searchText
        } onChange: { [weak self] in
            self?.renderListScreen()
        }
    }
}

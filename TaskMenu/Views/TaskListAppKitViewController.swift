import AppKit

/// One task-list pane: list picker, filter, quick add, task list, and the
/// pushed task editor. The popover instantiates one per visible pane, each
/// rendering its own `TaskListPane` and passing that pane to every `AppState`
/// mutation, so two panes never touch each other's list.
@MainActor
final class TaskListAppKitViewController: NSViewController {
    private let appState: AppState
    private let pane: TaskListPane
    private let onOpenSettings: () -> Void
    private let onRequestClose: () -> Void
    private let appStateObserver = TaskMenuAppStateObserver()

    private var showCompleted = false
    private var expandedCompletedSubtaskParentIDs: Set<String> = []
    /// Task whose inline "add subtask" field is open, from the row context menu.
    private var addingSubtaskParentID: String?
    /// Whether the header shows the inline new-list field instead of the picker.
    private var isComposingNewList = false

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
    private var hasPresentedCaptureDetail = false

    /// How far the list page parallax-slides behind an incoming detail page.
    private static let listParallaxFactor: CGFloat = 0.3
    private static let detailTransitionDuration: TimeInterval = 0.28

    init(
        appState: AppState,
        pane: TaskListPane,
        onOpenSettings: @escaping () -> Void,
        onRequestClose: @escaping () -> Void
    ) {
        self.appState = appState
        self.pane = pane
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
        // The push/pop slide animates layer-backed frames; without an explicit
        // layer here the transition snaps instead of sliding.
        containerView.wantsLayer = true
        view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        buildListPage()
        renderListScreen()
        observeAppState()
    }

    /// Only the primary pane takes focus; otherwise the last pane to appear
    /// would steal it.
    override func viewDidAppear() {
        super.viewDidAppear()
        if pane.id == .primary {
            quickAddView.focusField()
        }
    }

    /// A closed-and-reopened popover shows the picker again, and the
    /// quick-add focus in `viewDidAppear` never competes with the field.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        closeNewListComposer()
    }

    private func configureControls() {
        headerView.onSelectList = { [weak self] listID in
            self?.selectList(listID)
        }
        headerView.onOpenSettings = onOpenSettings
        headerView.onRefresh = { [appState, pane] in
            Task {
                await appState.refreshTasks(in: pane)
            }
        }
        headerView.isDemoMode = appState.isDemoMode
        headerView.onSignOut = { [appState] in
            appState.signOut()
        }
        headerView.onToggleSideBySide = { [appState] in
            appState.sideBySideListsEnabled.toggle()
        }
        headerView.onBeginNewList = { [weak self] in
            self?.openNewListComposer()
        }
        headerView.onCommitNewList = { [weak self] title in
            self?.commitNewList(title: title)
        }
        headerView.onCancelNewList = { [weak self] in
            self?.closeNewListComposer()
            self?.quickAddView.focusField()
        }
        headerView.onSelectSortOrder = { [weak self] order in
            guard let self, order != pane.sortOrder else { return }
            // Re-sorting rebuilds the rows, which would drop the inline subtask
            // field and whatever was typed in it (same rule as list switches
            // and filtering).
            closeAddSubtaskField()
            appState.setSortOrder(order, in: pane)
        }

        quickAddView.onCommit = { [weak self] title in
            guard let self else { return }
            // Clear any active filter so the new task is visible and can flash.
            pane.searchText = ""
            Task { [weak self] in
                guard let self, let task = await appState.addTask(title: title, in: pane) else { return }
                contentView.flashTask(taskID: task.id)
            }
        }
        quickAddView.onEscapeWithEmptyField = { [weak self] in
            self?.onRequestClose()
        }

        searchBarView.onSearchTextChange = { [weak self] text in
            // Filtering rebuilds every row, which would discard the inline
            // subtask field along with anything typed into it.
            self?.closeAddSubtaskField()
            self?.pane.searchText = text
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

    // MARK: - Main Menu Actions

    /// ⌘N (File > New Task). Reached from the main menu through the responder
    /// chain, so it works from any field on the list page.
    @objc func focusQuickAdd(_ sender: Any?) {
        guard isShowingListPage else { return }
        quickAddView.focusField()
    }

    /// ⌘F (Edit > Filter Tasks).
    @objc func focusFilterField(_ sender: Any?) {
        guard isShowingListPage else { return }
        searchBarView.focusField()
    }

    /// The detail page is pushed over the list and stays non-nil for the
    /// duration of both slide transitions, so this is also false while animating.
    private var isShowingListPage: Bool { detailController == nil }

    // MARK: - Detail Navigation

    /// Pushes the edit screen over the list with a navigation slide; the list
    /// page parallax-slides behind it. Skips motion when the user prefers
    /// reduced motion.
    private func presentTaskDetail(for task: TaskItem) {
        guard detailController == nil, !isTransitioningDetail else { return }

        // The detail screen has its own add-subtask field; leaving the list's
        // inline one open would put a stale field behind the pushed page.
        if addingSubtaskParentID != nil {
            closeAddSubtaskField()
            renderListContent()
        }
        // Same for the header's new-list field.
        closeNewListComposer()

        let detail = TaskDetailAppKitViewController(appState: appState, pane: pane, task: task) { [weak self] in
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
        let parallaxOffset = -containerView.bounds.width * Self.listParallaxFactor
        NSAnimationContext.runAnimationGroup({ [listLeadingConstraint] context in
            context.duration = Self.detailTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            leading.animator().constant = 0
            listLeadingConstraint?.animator().constant = parallaxOffset
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
        let offscreenLeading = containerView.bounds.width
        NSAnimationContext.runAnimationGroup({ [detailLeadingConstraint, listLeadingConstraint] context in
            context.duration = Self.detailTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailLeadingConstraint?.animator().constant = offscreenLeading
            listLeadingConstraint?.animator().constant = 0
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
        contentView.onToggleTask = { [appState, pane] task in
            Task {
                await appState.toggleTask(task, in: pane)
            }
        }
        contentView.onDeleteTask = { [appState, pane] task in
            Task {
                await appState.deleteTask(task, in: pane)
            }
        }
        contentView.onMoveTaskToList = { [weak self] task, listID in
            guard let self else { return }
            // The composer row belongs to the row that is about to leave the list.
            if addingSubtaskParentID == task.id {
                closeAddSubtaskField()
            }
            Task { [appState, pane] in
                await appState.moveTask(task, toList: listID, from: pane)
            }
        }
        contentView.onMoveTask = { [appState, pane] task, newParentID, previousTaskID in
            Task {
                await appState.moveTask(task, toParent: newParentID, after: previousTaskID, in: pane)
            }
        }
        contentView.onBeginAddSubtask = { [weak self] task in
            self?.openAddSubtaskField(for: task)
        }
        contentView.onAddSubtask = { [weak self] title, parentID in
            Task { [weak self] in
                guard let self,
                      let subtask = await appState.addSubtask(title: title, parentId: parentID, in: pane)
                else { return }
                contentView.flashTask(taskID: subtask.id)
            }
        }
        contentView.onCancelAddSubtask = { [weak self] in
            self?.closeAddSubtaskField()
            self?.renderListContent()
        }
        contentView.onToggleCollapsed = { [weak self] taskID in
            Task { @MainActor [weak self] in
                self?.pane.toggleCollapsed(taskID)
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

    /// Opens the inline subtask field under `task`. Any active filter is
    /// cleared so the parent (and the subtask about to be created) is visible,
    /// and a collapsed parent is expanded so the field itself is on screen.
    private func openAddSubtaskField(for task: TaskItem) {
        pane.searchText = ""
        pane.expandTask(task.id)
        addingSubtaskParentID = task.id
        renderListContent()
    }

    private func closeAddSubtaskField() {
        addingSubtaskParentID = nil
    }

    // MARK: - New List Composer

    /// Idempotent: the popup can dispatch "New List…" through both the item's
    /// action and its own, so a double fire must not re-render twice.
    private func openNewListComposer() {
        guard !isComposingNewList else { return }
        isComposingNewList = true
        renderListScreen()
    }

    private func closeNewListComposer() {
        guard isComposingNewList else { return }
        isComposingNewList = false
        renderListScreen()
    }

    /// Enter in the header field: close the field first so a slow request
    /// never leaves an editable field over a picker that is about to change,
    /// reset the per-list UI the way a list switch does (`AppState` selects
    /// the new list itself, bypassing `selectList(_:)` here), then create and
    /// select.
    private func commitNewList(title: String) {
        closeNewListComposer()
        resetPerListUIState()
        quickAddView.focusField()
        Task { [appState, pane] in
            await appState.createTaskList(title: title, in: pane)
        }
    }

    /// Shared by `selectList(_:)` and `commitNewList(title:)`.
    private func resetPerListUIState() {
        showCompleted = false
        expandedCompletedSubtaskParentIDs = []
        closeAddSubtaskField()
        pane.searchText = ""
    }

    /// One-shot `--capture task` hook: the seeded tasks arrive asynchronously,
    /// so the push waits for the first render that has one to open. Only the
    /// primary pane opens it.
    private func presentTaskDetailForCaptureIfNeeded() {
        guard !hasPresentedCaptureDetail,
              pane.id == .primary,
              TaskMenuApp.captureScreen == .task,
              let task = appState.rootTasks(in: pane).first(where: {
                  !$0.isCompleted && !appState.subtasks(of: $0.id, in: pane).isEmpty
              }) ?? appState.rootTasks(in: pane).first(where: { !$0.isCompleted })
        else {
            return
        }

        hasPresentedCaptureDetail = true
        presentTaskDetail(for: task)
    }

    private func renderListScreen() {
        presentTaskDetailForCaptureIfNeeded()
        let listTitle = appState.selectedList(in: pane)?.title ?? "Tasks"
        headerView.isSideBySideEnabled = appState.sideBySideListsEnabled
        headerView.render(
            listTitle: listTitle,
            taskLists: appState.taskLists,
            selectedListID: pane.selectedListId,
            sortOrder: pane.sortOrder,
            isLoading: pane.isLoading,
            isComposingNewList: isComposingNewList
        )
        quickAddView.render(listTitle: listTitle)
        searchBarView.render(
            searchText: pane.searchText,
            isSearching: pane.isSearching,
            resultCount: appState.searchMatchCount(in: pane)
        )
        renderListContent()
    }

    private func renderListContent() {
        contentView.render(
            appState: appState,
            pane: pane,
            showCompleted: showCompleted,
            expandedCompletedSubtaskParentIDs: expandedCompletedSubtaskParentIDs,
            addingSubtaskParentID: addingSubtaskParentID
        )
    }

    private func selectList(_ listID: String) {
        guard listID != pane.selectedListId else { return }
        closeNewListComposer()
        resetPerListUIState()
        Task { [appState, pane] in
            await appState.selectList(listID, in: pane)
        }
    }

    /// Tracks the pane's own state, never the primary-pane forwarders on
    /// `AppState`, so the secondary pane re-renders on its own changes.
    private func observeAppState() {
        appStateObserver.observe { [appState, pane] in
            _ = pane.isLoading
            _ = appState.taskLists
            _ = pane.selectedListId
            _ = pane.tasks
            _ = pane.collapsedTaskIDs
            _ = pane.searchText
            _ = pane.sortOrder
            _ = appState.sideBySideListsEnabled
        } onChange: { [weak self] in
            self?.renderListScreen()
        }
    }
}

extension TaskListAppKitViewController: NSMenuItemValidation {
    /// Greys out ⌘N/⌘F whenever the list page is not showing. Note this is the
    /// *display* half of the scoping only: `performKeyEquivalent` was observed
    /// to still claim the event for a disabled item, so the guards inside
    /// `focusQuickAdd`/`focusFilterField` are what actually make them inert.
    /// Everything else must stay enabled — the clipboard items resolve to a text
    /// view earlier in the responder chain, but a blanket `false` here would be
    /// a silent trap for anything that does reach this controller.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(focusQuickAdd(_:)), #selector(focusFilterField(_:)):
            return isShowingListPage
        default:
            return true
        }
    }
}

import SwiftUI

@main
struct TaskMenuApp: App {
    @State private var appState: AppState

    static let isUITesting = CommandLine.arguments.contains("-ui-testing")

    init() {
        if Self.isUITesting {
            // Make the app a regular app so UI automation can attach
            NSApplication.shared.setActivationPolicy(.regular)
            let mockAPI = MockTasksAPI()
            let state = AppState(api: mockAPI)
            state.isSignedIn = true
            _appState = State(initialValue: state)
        } else {
            _appState = State(initialValue: AppState())
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(appState: appState)
        } label: {
            Label("TaskMenu", image: "MenuBarIcon")
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)

        Window("TaskMenu", id: "ui-testing") {
            Group {
                if Self.isUITesting {
                    MenuBarPopover(appState: appState)
                        .frame(width: 320, height: 480)
                }
            }
            .onAppear {
                if !Self.isUITesting {
                    DispatchQueue.main.async {
                        NSApplication.shared.windows
                            .filter { $0.title == "TaskMenu" }
                            .forEach { $0.close() }
                    }
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

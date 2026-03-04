import SwiftUI

struct MenuBarPopover: View {
    @Bindable var appState: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isSignedIn {
                SignInView(appState: appState)
            } else if showSettings {
                SettingsView(appState: appState)
                    .overlay(alignment: .topLeading) {
                        Button {
                            showSettings = false
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .padding(12)
                    }
            } else {
                TaskListView(appState: appState)

                Divider()

                HStack {
                    if let error = appState.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .onTapGesture {
                                appState.errorMessage = nil
                            }
                    }
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 320, height: appState.isSignedIn && !showSettings ? 480 : nil)
        .task {
            if appState.isSignedIn && appState.taskLists.isEmpty {
                await appState.loadTaskLists()
            }
        }
    }
}

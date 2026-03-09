import SwiftUI

struct MenuBarPopover: View {
    @Bindable var appState: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isSignedIn {
                SignInView(appState: appState)
                    .transition(.opacity)
            } else if showSettings {
                SettingsView(appState: appState)
                    .overlay(alignment: .topLeading) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSettings = false
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .padding(12)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                TaskListView(appState: appState)

                Divider()

                HStack(spacing: 8) {
                    if let error = appState.errorMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(error)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                appState.errorMessage = nil
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSettings = true
                        }
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .frame(width: 320, height: appState.isSignedIn && !showSettings ? 480 : nil)
        .animation(.easeInOut(duration: 0.25), value: appState.isSignedIn)
        .animation(.easeInOut(duration: 0.2), value: appState.errorMessage != nil)
        .task {
            if appState.isSignedIn && appState.taskLists.isEmpty {
                await appState.loadTaskLists()
            }
        }
    }
}

import SwiftUI

struct SignInView: View {
    @Bindable var appState: AppState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)

            Text("TaskMenu")
                .font(.title2.bold())

            Text("Sign in with Google to access your tasks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                appState.signIn()
            } label: {
                if appState.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing in...")
                    }
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Sign in with Google", systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(appState.isLoading)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let errorMessage = appState.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.top, 2)
                    Text(errorMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .padding(24)
        .frame(width: 320)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }
}

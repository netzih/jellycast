import SwiftUI

/// Shown on the device signing in: a code to approve elsewhere, polled until
/// someone does.
struct QuickConnectSignInSheet: View {
    let server: String
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let code {
                    Text("Enter this code on a device that's already signed in")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(spaced(code))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    VStack(alignment: .leading, spacing: 10) {
                        instruction("iphone", "In JellyCast: Settings → Sign in another device")
                        instruction("globe", "In Jellyfin on the web: your profile → Quick Connect")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for approval…").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else if let errorText {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorText).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        // Cancelled automatically when the sheet closes, which stops the polling.
        .task { await run() }
    }

    private func instruction(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
    }

    /// "123456" → "123 456", easier to read across a room.
    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func run() async {
        do {
            guard try await JellyfinClient.quickConnectEnabled(server: server) else {
                errorText = "Quick Connect is turned off on this server. An admin can turn it on in Jellyfin's Dashboard → General."
                return
            }
            let request = try await JellyfinClient.initiateQuickConnect(server: server)
            code = request.code

            // Codes last a few minutes on the server; poll a little short of that.
            let deadline = Date().addingTimeInterval(9 * 60)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(3))
                if try await JellyfinClient.quickConnectApproved(baseURL: request.baseURL, secret: request.secret) {
                    let session = try await JellyfinClient.logIn(baseURL: request.baseURL, quickConnectSecret: request.secret)
                    await appState.signIn(with: session)
                    dismiss()
                    return
                }
            }
            code = nil
            errorText = "That code expired. Close this and try again."
        } catch is CancellationError {
            // Sheet closed.
        } catch {
            code = nil
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Shown on a device that's already signed in: approve a code from a new one.
struct AuthorizeDeviceView: View {
    @EnvironmentObject var appState: AppState

    @State private var code = ""
    @State private var isWorking = false
    @State private var result: Result<Void, Error>?
    @FocusState private var focused: Bool

    private var cleanCode: String { code.filter(\.isNumber) }

    var body: some View {
        Form {
            Section {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                    .focused($focused)
                    .onChange(of: code) { _, _ in result = nil }
            } footer: {
                Text("On the other phone, open JellyCast, enter the server address and tap “Sign in with Quick Connect”. It signs in as you, \(appState.userName).")
            }

            Section {
                Button {
                    Task { await authorize() }
                } label: {
                    HStack {
                        Spacer()
                        if isWorking { ProgressView().padding(.trailing, 6) }
                        Text("Approve")
                        Spacer()
                    }
                }
                .disabled(isWorking || cleanCode.count != 6)
            }

            switch result {
            case .success:
                Section {
                    Label("Approved — the other device will finish signing in within a few seconds.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .failure(let error):
                Section {
                    Text(message(for: error)).foregroundStyle(.red)
                }
            case nil:
                EmptyView()
            }
        }
        .navigationTitle("Sign in another device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func authorize() async {
        guard let client = appState.client else { return }
        isWorking = true
        do {
            try await client.authorizeQuickConnect(code: cleanCode)
            result = .success(())
            code = ""
        } catch {
            result = .failure(error)
        }
        isWorking = false
    }

    private func message(for error: Error) -> String {
        if case JellyfinError.http(let status, _) = error, status == 404 || status == 400 {
            return "That code didn't match. Check it, or start again on the other phone — codes expire after a few minutes."
        }
        if case JellyfinError.http(403, _) = error {
            return "Quick Connect is turned off on this server, or this account isn't allowed to use it."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

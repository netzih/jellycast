import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isSignedIn {
                MainTabView()
                    .task {
                        // Asked only once there's a library to play from.
                        SiriVocabulary.requestAuthorizationIfNeeded()
                        if let client = appState.client { await SiriVocabulary.update(using: client) }
                    }
            } else {
                LoginView()
            }
        }
        .alert(
            "Playback problem",
            isPresented: Binding(
                get: { appState.player.errorMessage != nil },
                set: { if !$0 { appState.player.errorMessage = nil } }
            ),
            presenting: appState.player.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { appState.player.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                HomeTab()
                    .tabItem { Label("Home", systemImage: "house") }
                LibraryTab(kind: .albums)
                    .tabItem { Label("Albums", systemImage: "square.stack") }
                LibraryTab(kind: .artists)
                    .tabItem { Label("Artists", systemImage: "music.mic") }
                LibraryTab(kind: .playlists)
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
                SearchTab()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                // Settings lives behind the gear on Home: a sixth tab would
                // push everything past the fifth into a "More" list.
            }
            MiniPlayer(player: appState.player)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var appState: AppState

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.50:8096", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Jellyfin server address")
                } footer: {
                    Text("The same address you use in a browser. Include the port if it has one.")
                }

                Section("Your Jellyfin account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView().padding(.trailing, 6) }
                            Text(isWorking ? "Connecting…" : "Connect")
                            Spacer()
                        }
                    }
                    .disabled(isWorking || server.isEmpty || username.isEmpty)
                }
            }
            .navigationTitle("JellyCast")
        }
    }

    private func signIn() async {
        isWorking = true
        errorText = nil
        do {
            try await appState.signIn(server: server, username: username, password: password)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isWorking = false
    }
}

struct SettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                RoutePicker(player: appState.player)

                Section {
                    Picker("Library", selection: $appState.selectedLibraryId) {
                        Text("All libraries").tag(String?.none)
                        ForEach(appState.libraries) { library in
                            Text(library.name).tag(String?.some(library.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Browse")
                } footer: {
                    Text("Albums, artists and search stay inside this library. Playlists always span the whole server, because that's where Jellyfin keeps them.")
                }

                Section {
                    Picker("Quality", selection: $appState.streamQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Streaming")
                } footer: {
                    Text(appState.streamQuality.detail)
                }

                Section {
                    Toggle("Volume levelling", isOn: $appState.volumeLevelling)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Turns loud tracks down to match quieter ones, using the loudness your Jellyfin server measured. Works on this iPhone, in the car and on speakers.")
                }

                Section("Account") {
                    LabeledContent("Signed in as", value: appState.userName)
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Sign out of Jellyfin?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { appState.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Playback will stop and you'll need your password to sign back in.")
            }
        }
    }
}

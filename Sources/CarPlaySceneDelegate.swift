import CarPlay
import Foundation

/// CarPlay browsing. Separate from Cast on purpose: in the car the audio plays
/// through the car itself (the `.thisDevice` route), never to a Cast speaker.
///
/// This scene only ever connects if the app is signed with
/// `com.apple.developer.carplay-audio`, which Apple grants on request. Without
/// it the rest of the app is unaffected — see README.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor in
            // Driving means local playback; never hand the car's UI to a speaker at home.
            AppState.shared.player.switchTo(.thisDevice)
            interfaceController.setRootTemplate(self.makeRootTemplate(), animated: false, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    @MainActor
    private func makeRootTemplate() -> CPTemplate {
        guard AppState.shared.isSignedIn else {
            let template = CPListTemplate(
                title: "JellyCast",
                sections: [CPListSection(items: [
                    CPListItem(text: "Sign in on your iPhone first", detailText: nil)
                ])]
            )
            return template
        }

        let albums = makeSectionTemplate(title: "Albums", kind: .albums)
        let artists = makeSectionTemplate(title: "Artists", kind: .artists)
        let playlists = makeSectionTemplate(title: "Playlists", kind: .playlists)

        albums.tabTitle = "Albums"
        albums.tabImage = UIImage(systemName: "square.stack")
        artists.tabTitle = "Artists"
        artists.tabImage = UIImage(systemName: "music.mic")
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")

        return CPTabBarTemplate(templates: [albums, artists, playlists])
    }

    @MainActor
    private func makeSectionTemplate(title: String, kind: LibraryKind) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewSubtitleVariants = ["Loading your library…"]

        Task { @MainActor in
            guard let client = AppState.shared.client else { return }
            let items: [JFItem]
            do {
                switch kind {
                case .albums: items = try await client.albums(limit: 300)
                case .artists: items = try await client.artists(limit: 300)
                case .playlists: items = try await client.playlists()
                }
            } catch {
                print("[JellyCast] CarPlay load of \(title) failed: \(error.localizedDescription)")
                template.emptyViewSubtitleVariants = ["Couldn't reach your Jellyfin server."]
                return
            }

            let listItems = items.map { item -> CPListItem in
                let row = CPListItem(
                    text: item.name,
                    detailText: item.displayArtist.isEmpty ? nil : item.displayArtist
                )
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        await self?.open(item, kind: kind)
                        completion()
                    }
                }
                return row
            }

            template.emptyViewSubtitleVariants = ["Nothing in this part of your library yet."]
            template.updateSections([CPListSection(items: listItems)])
        }

        return template
    }

    /// Artists push another list; albums and playlists start playing immediately —
    /// fewer taps is safer behind the wheel.
    @MainActor
    private func open(_ item: JFItem, kind: LibraryKind) async {
        guard let client = AppState.shared.client else { return }

        if kind == .artists {
            let albums = (try? await client.albums(forArtist: item.id)) ?? []
            let template = CPListTemplate(title: item.name, sections: [
                CPListSection(items: albums.map { album in
                    let row = CPListItem(text: album.name, detailText: album.productionYear.map(String.init))
                    row.handler = { [weak self] _, completion in
                        Task { @MainActor in
                            await self?.playTracks(inParent: album.id)
                            completion()
                        }
                    }
                    return row
                })
            ])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        await playTracks(inParent: item.id)
    }

    @MainActor
    private func playTracks(inParent parentId: String) async {
        guard let client = AppState.shared.client else { return }
        let tracks = (try? await client.tracks(inParent: parentId)) ?? []
        guard !tracks.isEmpty else { return }

        AppState.shared.player.switchTo(.thisDevice)
        AppState.shared.player.play(items: tracks)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}

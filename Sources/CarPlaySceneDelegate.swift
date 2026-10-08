import CarPlay
import Combine
import Foundation

/// CarPlay browsing. Separate from Cast on purpose: in the car the audio plays
/// through the car itself (the `.thisDevice` route), never to a Cast speaker.
///
/// This scene only ever connects if the app is signed with
/// `com.apple.developer.carplay-audio`, which Apple grants on request. Without
/// it the rest of the app is unaffected — see README.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    /// The Up Next list while it's on screen, so it can follow the queue live.
    private weak var queueTemplate: CPListTemplate?
    private var queueObservation: AnyCancellable?
    /// The browse tabs that depend on which library is picked.
    private weak var albumsTemplate: CPListTemplate?
    private weak var artistsTemplate: CPListTemplate?
    private weak var libraryTemplate: CPListTemplate?
    private weak var homeTemplate: CPListTemplate?
    /// True when the tab bar had no room for Library and it lives on Home instead.
    private var libraryIsOnHome = false
    private var nowPlayingObservations: Set<AnyCancellable> = []
    private var libraryObservations: Set<AnyCancellable> = []

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor in
            // Driving means local playback; never hand the car's UI to a speaker at home.
            AppState.shared.player.switchTo(.thisDevice)
            self.configureNowPlaying()
            interfaceController.setRootTemplate(self.makeRootTemplate(), animated: false, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        CPNowPlayingTemplate.shared.remove(self)
        queueObservation = nil
        libraryObservations = []
        nowPlayingObservations = []
    }

    // MARK: - Now Playing

    /// Play/pause, next and previous come for free from the remote commands;
    /// these are the extra buttons along the bottom, plus the Up Next list.
    @MainActor
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Up Next"

        updateNowPlayingButtons()

        // The heart has to follow the track and any change made on the phone.
        let appState = AppState.shared
        nowPlayingObservations = []
        appState.player.$index.map { _ in () }
            .merge(with: appState.$favoriteOverrides.map { _ in () }, appState.player.$queue.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in Task { @MainActor in self?.updateNowPlayingButtons() } }
            .store(in: &nowPlayingObservations)

        // Keep the Up Next list in step with the queue while it's showing.
        let player = AppState.shared.player
        queueObservation = player.$queue.combineLatest(player.$index, player.$state)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshQueueTemplate() }
            }
    }

    /// Shuffle, back 15, favorite, forward 15, repeat — CarPlay's limit is five.
    @MainActor
    private func updateNowPlayingButtons() {
        let nowPlaying = CPNowPlayingTemplate.shared
        // Shuffle and repeat draw their on/off state from MPRemoteCommandCenter,
        // which the coordinator keeps current.
        let shuffle = CPNowPlayingShuffleButton { _ in
            Task { @MainActor in AppState.shared.player.toggleShuffle() }
        }
        let repeatButton = CPNowPlayingRepeatButton { _ in
            Task { @MainActor in AppState.shared.player.cycleRepeatMode() }
        }
        var buttons: [CPNowPlayingButton] = [shuffle]
        if let back = UIImage(systemName: "gobackward.15") {
            buttons.append(CPNowPlayingImageButton(image: back) { _ in
                Task { @MainActor in AppState.shared.player.skip(by: -15) }
            })
        }
        if let track = AppState.shared.player.currentTrack {
            let favorite = AppState.shared.isFavorite(track.item)
            if let heart = UIImage(systemName: favorite ? "heart.fill" : "heart") {
                buttons.append(CPNowPlayingImageButton(image: heart) { _ in
                    Task { @MainActor in AppState.shared.toggleFavorite(track.item) }
                })
            }
        }
        if let forward = UIImage(systemName: "goforward.15") {
            buttons.append(CPNowPlayingImageButton(image: forward) { _ in
                Task { @MainActor in AppState.shared.player.skip(by: 15) }
            })
        }
        buttons.append(repeatButton)
        nowPlaying.updateNowPlayingButtons(buttons)
    }

    @MainActor
    private func showQueue() {
        let template = CPListTemplate(title: "Up Next", sections: queueSections())
        template.emptyViewSubtitleVariants = ["Nothing queued"]
        queueTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    private func refreshQueueTemplate() {
        queueTemplate?.updateSections(queueSections())
    }

    /// From the playing track onward — what's already played isn't worth a
    /// driver's glance — capped at what CarPlay will show.
    @MainActor
    private func queueSections() -> [CPListSection] {
        let player = AppState.shared.player
        guard !player.queue.isEmpty else { return [] }

        let first = player.queue.indices.contains(player.index) ? player.index : 0
        let last = min(player.queue.count, first + CPListTemplate.maximumItemCount)
        let rows = (first..<last).map { position -> CPListItem in
            let track = player.queue[position]
            let row = CPListItem(
                text: track.title,
                detailText: track.artist.isEmpty ? nil : track.artist
            )
            if position == player.index {
                row.isPlaying = true
                row.playingIndicatorLocation = .trailing
            }
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    player.jumpToQueueItem(at: position)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
            }
            return row
        }

        let header = player.isShuffled ? "Shuffled" : nil
        return [CPListSection(items: rows, header: header, sectionIndexTitle: nil)]
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

        let library = CPListTemplate(title: "Library", sections: librarySections())
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "books.vertical")

        let home = CPListTemplate(title: "Home", sections: [])
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house")
        home.emptyViewSubtitleVariants = ["Loading…"]

        albumsTemplate = albums
        artistsTemplate = artists
        libraryTemplate = library
        homeTemplate = home

        var tabs: [CPTemplate] = [home, albums, artists, playlists, library]
        // Some head units allow fewer tabs; then Library becomes a row on Home.
        libraryIsOnHome = tabs.count > CPTabBarTemplate.maximumTabCount
        if libraryIsOnHome { tabs.removeLast() }

        observeLibrarySelection()
        reloadHome()

        let tabBar = CPTabBarTemplate(templates: Array(tabs.prefix(CPTabBarTemplate.maximumTabCount)))
        tabBar.delegate = self
        return tabBar
    }

    // MARK: - Home

    /// Reloaded whenever the tab is picked: recently played moves with every song.
    @MainActor
    private func reloadHome() {
        guard let home = homeTemplate, let client = AppState.shared.client else { return }
        let requestedLibrary = AppState.shared.selectedLibraryId

        Task { @MainActor in
            async let recent = try? client.recentlyPlayedTracks(limit: 12)
            async let favoriteSongs = try? client.favorites(type: "Audio")
            async let favoriteAlbums = try? client.favorites(type: "MusicAlbum", limit: 12)
            async let mostPlayed = try? client.mostPlayedTracks(limit: 12)
            async let justAdded = try? client.recentlyAddedAlbums(limit: 12)
            let sections = homeSections(
                recent: await recent ?? [],
                favoriteSongs: await favoriteSongs ?? [],
                favoriteAlbums: await favoriteAlbums ?? [],
                mostPlayed: await mostPlayed ?? [],
                justAdded: await justAdded ?? []
            )
            guard requestedLibrary == AppState.shared.selectedLibraryId else { return }
            home.emptyViewSubtitleVariants = ["Play some music and it'll show up here."]
            home.updateSections(sections)
        }
    }

    @MainActor
    private func homeSections(
        recent: [JFItem], favoriteSongs: [JFItem], favoriteAlbums: [JFItem],
        mostPlayed: [JFItem], justAdded: [JFItem]
    ) -> [CPListSection] {
        var sections: [CPListSection] = []

        // One-tap starts first: the whole point of Home behind the wheel.
        var quick: [CPListItem] = []
        if !favoriteSongs.isEmpty {
            let row = CPListItem(text: "Shuffle favorite songs", detailText: countOf(favoriteSongs.count, "song"),
                                 image: UIImage(systemName: "heart.fill"))
            row.handler = { [weak self] _, completion in
                Task { @MainActor in self?.start(favoriteSongs, shuffle: true); completion() }
            }
            quick.append(row)
        }
        if let current = AppState.shared.player.currentTrack {
            let row = CPListItem(text: "Instant Mix", detailText: "Based on \(current.title)",
                                 image: UIImage(systemName: "dot.radiowaves.left.and.right"))
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await AppState.shared.player.playInstantMix(from: current.item)
                    self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    completion()
                }
            }
            quick.append(row)
        }
        let downloads = DownloadStore.shared
        if !downloads.downloaded.isEmpty {
            let row = CPListItem(text: "Downloads", detailText: "\(countOf(downloads.downloaded.count, "song")), no signal needed",
                                 image: UIImage(systemName: "arrow.down.circle.fill"))
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor in self?.showDownloads(); completion() }
            }
            quick.append(row)
        }
        if libraryIsOnHome {
            let row = CPListItem(text: "Library", detailText: AppState.shared.selectedLibraryName ?? "All libraries",
                                 image: UIImage(systemName: "books.vertical"))
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    guard let self else { completion(); return }
                    let picker = CPListTemplate(title: "Library", sections: self.librarySections())
                    self.libraryTemplate = picker
                    self.interfaceController?.pushTemplate(picker, animated: true, completion: nil)
                    completion()
                }
            }
            quick.append(row)
        }
        if !quick.isEmpty { sections.append(CPListSection(items: quick)) }

        func trackRows(_ tracks: [JFItem]) -> [CPListItem] {
            tracks.enumerated().map { offset, track in
                let row = CPListItem(text: track.name, detailText: track.displayArtist)
                loadArtwork(for: track, into: row)
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in self?.start(tracks, startAt: offset); completion() }
                }
                return row
            }
        }
        func albumRows(_ albums: [JFItem]) -> [CPListItem] {
            albums.map { album in
                let row = CPListItem(text: album.name, detailText: album.displayArtist)
                loadArtwork(for: album, into: row)
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in await self?.playTracks(inParent: album.id); completion() }
                }
                return row
            }
        }

        if !recent.isEmpty {
            sections.append(CPListSection(items: trackRows(recent), header: "Recently played", sectionIndexTitle: nil))
        }
        if !favoriteAlbums.isEmpty {
            sections.append(CPListSection(items: albumRows(favoriteAlbums), header: "Favorite albums", sectionIndexTitle: nil))
        }
        if !mostPlayed.isEmpty {
            sections.append(CPListSection(items: trackRows(mostPlayed), header: "Most played", sectionIndexTitle: nil))
        }
        if !justAdded.isEmpty {
            sections.append(CPListSection(items: albumRows(justAdded), header: "Just added", sectionIndexTitle: nil))
        }
        return Array(sections.prefix(CPListTemplate.maximumSectionCount))
    }

    @MainActor
    private func showDownloads() {
        let albums = DownloadStore.shared.albums
        let everything = albums.flatMap(\.tracks)

        let shuffle = CPListItem(text: "Shuffle all downloads", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, completion in
            Task { @MainActor in self?.start(everything, shuffle: true); completion() }
        }
        let albumRows = albums.prefix(CPListTemplate.maximumItemCount - 1).map { album -> CPListItem in
            let row = CPListItem(text: album.title, detailText: album.artist)
            if let art = album.tracks.first.flatMap({ DownloadStore.shared.localArtworkURL(for: $0.id) }),
               let image = UIImage(contentsOfFile: art.path) {
                row.setImage(image)
            }
            row.handler = { [weak self] _, completion in
                Task { @MainActor in self?.start(album.tracks); completion() }
            }
            return row
        }
        let template = CPListTemplate(title: "Downloads", sections: [
            CPListSection(items: [shuffle]),
            CPListSection(items: Array(albumRows)),
        ])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Small artwork, fetched after the row is already on screen.
    @MainActor
    private func loadArtwork(for item: JFItem, into row: CPListItem) {
        guard let url = AppState.shared.client?.artworkURL(for: item, maxHeight: 120) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { row.setImage(image) }
        }
    }

    // MARK: - Library picker

    /// Follows the selection wherever it's made — this tab or the phone's
    /// picker — and the library list itself, which loads after launch.
    @MainActor
    private func observeLibrarySelection() {
        let appState = AppState.shared
        libraryObservations = []
        appState.$selectedLibraryId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.libraryTemplate?.updateSections(self.librarySections())
                    // Playlists aren't scoped to a library, so only these two reload.
                    if let albums = self.albumsTemplate { self.load(albums, title: "Albums", kind: .albums) }
                    if let artists = self.artistsTemplate { self.load(artists, title: "Artists", kind: .artists) }
                    self.reloadHome()
                }
            }
            .store(in: &libraryObservations)
        // `$libraries` publishes before the property changes; read on the next turn.
        appState.$libraries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.libraryTemplate?.updateSections(self.librarySections())
                }
            }
            .store(in: &libraryObservations)
    }

    @MainActor
    private func librarySections() -> [CPListSection] {
        let appState = AppState.shared
        let choices: [(id: String?, name: String)] =
            [(nil, "All libraries")] + appState.libraries.map { ($0.id, $0.name) }

        let rows = choices.map { choice -> CPListItem in
            let selected = choice.id == appState.selectedLibraryId
            let row = CPListItem(
                text: choice.name,
                detailText: selected ? "Showing now" : nil,
                image: UIImage(systemName: choice.id == nil ? "square.grid.2x2" : "music.note.house"),
                accessoryImage: selected ? UIImage(systemName: "checkmark") : nil,
                accessoryType: .none
            )
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    AppState.shared.selectedLibraryId = choice.id
                    // Straight to the albums of the library just picked.
                    self?.interfaceController?.popToRootTemplate(animated: false, completion: nil)
                    if let tabs = self?.interfaceController?.rootTemplate as? CPTabBarTemplate,
                       let albums = self?.albumsTemplate {
                        tabs.select(albums)
                    }
                    completion()
                }
            }
            return row
        }
        return [CPListSection(items: rows)]
    }

    // MARK: - Browse tabs

    @MainActor
    private func makeSectionTemplate(title: String, kind: LibraryKind) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        load(template, title: title, kind: kind)
        return template
    }

    /// Fills (or refills, after a library change) one browse tab.
    @MainActor
    private func load(_ template: CPListTemplate, title: String, kind: LibraryKind) {
        template.emptyViewSubtitleVariants = ["Loading your library…"]
        template.updateSections([])
        let requestedLibrary = AppState.shared.selectedLibraryId

        Task { @MainActor in
            guard let client = AppState.shared.client else { return }
            let items: [JFItem]
            do {
                switch kind {
                // Same order as the phone's lists. No genre filter: it isn't
                // visible in the car, so it would only look like missing albums.
                case .albums: items = try await client.albums(limit: 300, sort: AppState.shared.albumSort)
                case .artists: items = try await client.artists(limit: 300, sort: AppState.shared.artistSort)
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

            // A quicker pick may have landed meanwhile; its own load fills the tab.
            guard requestedLibrary == AppState.shared.selectedLibraryId else { return }
            template.emptyViewSubtitleVariants = ["Nothing in this part of your library yet."]
            template.updateSections([CPListSection(items: listItems)])
        }
    }

    /// Artists push another list; albums and playlists start playing immediately —
    /// fewer taps is safer behind the wheel.
    @MainActor
    private func open(_ item: JFItem, kind: LibraryKind) async {
        guard let client = AppState.shared.client else { return }

        if kind == .artists {
            let albums = (try? await client.albums(forArtist: item.id)) ?? []
            let shuffleAll = CPListItem(
                text: "Shuffle all",
                detailText: nil,
                image: UIImage(systemName: "shuffle")
            )
            shuffleAll.handler = { [weak self] _, completion in
                Task { @MainActor in
                    let tracks = (try? await client.tracks(byArtist: item.id)) ?? []
                    self?.start(tracks, shuffle: true)
                    completion()
                }
            }
            let template = CPListTemplate(title: item.name, sections: [
                CPListSection(items: [shuffleAll]),
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
        start(tracks)
    }

    /// `shuffle: nil` keeps whatever shuffle mode the Now Playing button set.
    @MainActor
    private func start(_ tracks: [JFItem], startAt: Int? = nil, shuffle: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        AppState.shared.player.switchTo(.thisDevice)
        AppState.shared.player.play(items: tracks, startAt: startAt, shuffle: shuffle)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in self.showQueue() }
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}

extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        Task { @MainActor in
            if selectedTemplate === self.homeTemplate { self.reloadHome() }
        }
    }
}

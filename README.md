# JellyCast

A personal iPhone app for a Jellyfin music library, with two independent
output paths:

| Where | Route | How it works |
|---|---|---|
| **At home** | Google Cast | The Google Home / Nest speaker fetches the stream from Jellyfin itself. The phone is only a remote, so playback survives the phone locking or leaving the room. |
| **In the car** | This iPhone | `AVPlayer` plays locally, and iOS routes that audio to CarPlay or Bluetooth. |

These are deliberately separate. Cast is useless in the car (the speaker is at
home), and CarPlay is useless at home. `PlaybackEngine` is the shared interface;
`CastEngine` and `LocalPlayer` implement it, and `PlayerCoordinator` owns which
one is live.

## Build and install

```sh
./install.sh
```

That builds Release, signs, installs and launches on the iPhone 16 Pro Max.
Pass another paired device's identifier to target it instead:

```sh
./install.sh <device-identifier>      # xcrun devicectl list devices
```

It signs by hand against the team's existing wildcard provisioning profile
(`N484MY8AUM.*`, valid to 25 Jun 2027), so **no Apple ID needs to be signed
into Xcode**. This is deliberate: `xcodebuild` refuses to consume an
Xcode-managed profile in manual signing mode, and automatic mode requires an
Xcode account, so neither built-in path works here.

Note the team id is `N484MY8AUM` — the signing certificate's **OU**. The
`BJM636YTKD` inside the certificate's common name is a user id, not a team.

To build from the Xcode GUI instead, add your Apple ID in Xcode → Settings →
Accounts, then `xcodegen generate && open JellyCast.xcodeproj`. Automatic
signing is already configured for the right team.

Run `xcodegen generate` after changing `project.yml` or adding source files.

On first launch iOS asks for **Local Network** access. Cast discovery finds
nothing if you decline — Settings → JellyCast → Local Network to re-enable.

## Layout

```
Sources/
  JellyCastApp.swift        app entry; initializes the Cast context
  Models.swift              Jellyfin DTOs + PascalCase key decoding
  JellyfinClient.swift      auth, browsing, playlists, stream URLs, reporting
  Playback.swift            PlaybackEngine protocol, shared types
  CastEngine.swift          Google Cast implementation
  LocalPlayer.swift         AVPlayer + Now Playing (the CarPlay/Bluetooth path)
  AppState.swift            session, library selection + PlayerCoordinator
  Keychain.swift            token storage
  CarPlaySceneDelegate.swift  CarPlay browse templates
  Views/
    RootView.swift          login, tabs, settings
    LibraryViews.swift      albums, artists, playlists, search
    NowPlayingView.swift    full-screen player
    QueueView.swift         up next: reorder, remove, jump
    PlaylistSheets.swift    "add to playlist" + the shared long-press menu
    Components.swift        artwork, mini player, route picker, library menu
Vendor/GoogleCast.xcframework  Google's official SDK 4.8.6
install.sh                  build + sign + install to a paired iPhone
```

## Libraries, playlists and the queue

**Choosing a library.** A server that keeps *Music* and *Story tapes* as
separate media folders shouldn't merge them into one alphabetical wall. The
picker lives in Settings → Browse and in the toolbar of the Albums, Artists and
Search screens (it hides itself if the server only has one music library).
The choice is stored in `AppState.selectedLibraryId`, pushed down to
`JellyfinClient.libraryId`, and sent as `parentId` on every browse and search
request — so CarPlay is scoped by it too, without knowing it exists.

Playlists are deliberately *not* scoped: Jellyfin keeps them in their own root
folder, outside any library, so filtering them by `parentId` would return
nothing.

**Playlists.** Create one empty from the Playlists tab's **+**, or create one
around something you're looking at: long-press any album, artist or song →
*Add to playlist…* → *New playlist…*. Inside a playlist, swipe a row to remove
it and use **Edit** to reorder.

Playlist membership is keyed by `PlaylistItemId`, not the track's own id —
the same song can legitimately appear twice. Only `/Playlists/{id}/Items`
returns that handle, which is why playlist contents are fetched through a
different call than album contents.

**The queue.** The list icon in the player opens *Up Next*: tap to jump, swipe
to remove, **Reorder** to drag. Long-pressing anything in the library offers
*Play next* and *Add to queue*.

Queue edits are applied to `PlayerCoordinator.queue` first — that's what SwiftUI
renders — and then handed to whichever engine is live. `LocalPlayer` just
mutates its array. `CastEngine` has to talk to the receiver, which tracks its
queue by its own item ids, so it keeps an `itemIDs` array parallel to the
tracks and addresses every edit by id rather than position; a status update
that lands mid-edit then can't make it remove the wrong song.

## How audio reaches the speaker

The Cast receiver fetches the URL itself, so every URL carries `api_key=` —
the `Authorization` header only exists on requests the app makes directly.

Two URL shapes, chosen per track in `JellyfinClient.streamInfo(for:quality:)`:

- **Direct** — `/Audio/{id}/stream.{container}?static=true` when the file is
  already something a Google speaker decodes (MP3, FLAC, WAV, AAC, Ogg, WebM).
  Bit-exact, no server CPU.
- **Transcoded** — `/Audio/{id}/universal?...&audioCodec=mp3` for anything else
  (ALAC, WMA, APE). Settings → Streaming → *MP3 320* forces this for every
  track if some file misbehaves.

The receiver is Google's stock **Default Media Receiver**
(`kGCKDefaultMediaReceiverApplicationID`), which supports queues. No registered
Cast receiver app and no $5 Cast developer registration are needed.

Requirements: the speaker must be on the same network as Jellyfin, and both on
the same Wi-Fi as the phone for discovery.

## CarPlay status

`LocalPlayer` works today with no special approval. In the car you get audio
through CarPlay/Bluetooth plus the dashboard Now Playing screen — title, artist,
artwork, and working steering-wheel transport buttons — via
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.

**Browsing your library on the car's touchscreen is enabled.** It needs the
`com.apple.developer.carplay-audio` entitlement, which Apple grants only on
request at <https://developer.apple.com/contact/carplay/> (app type: **Audio**).
That request was **approved on 2026-09-22**.

The app is signed against an explicit App ID,
`N484MY8AUM.com.yitzchokwagner.jellycast`, whose development profile carries the
entitlement. `install.sh` prefers an exact-bundle-id profile over the team
wildcard and derives entitlements from whichever it picks, so nothing in the
project references the entitlement directly. After signing it prints what
actually landed in the signature:

```
==> Signed entitlements
    com.apple.developer.carplay-audio
    com.apple.developer.team-identifier
```

`CarPlaySceneDelegate.swift` and the `CPTemplateApplicationSceneSessionRoleApplication`
entry in `Info.plist` supply the browse templates.

### If the profile ever needs regenerating

The entitlement belongs to the *account*, so it survives; only the profile
expires (this one on **2027-09-22**). Recreate a development profile for that
App ID in Certificates, Identifiers & Profiles with CarPlay Audio ticked,
download it to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`, and
re-run `install.sh`. A wildcard App ID can never carry this entitlement, and
CarPlay is not in the App Store Connect API's capability list — it can only be
toggled by hand in the developer portal.

For the Xcode GUI path only, also add to `project.yml` under the target's
`settings.base`: `CODE_SIGN_ENTITLEMENTS: JellyCast.entitlements`, then
`xcodegen generate`. `JellyCast.entitlements` is already in the repo root,
unreferenced.

## Known limitations

- Library lists cap at 200 items (300 in CarPlay); no pagination yet.
- Deleting a playlist needs the Jellyfin account's "allow media deletion"
  permission; without it the app reports the server's refusal.
- CarPlay browses albums, artists and playlists, but has no queue editing —
  reordering while driving isn't worth building.
- No offline downloads — both routes stream, so the car needs cell coverage to
  reach Jellyfin unless you expose it publicly.
- Cast volume is controlled in-app; the local route defers to the hardware
  buttons and the car's own volume knob.
- Gapless playback depends on the receiver's `preloadTime` (set to 5s); it is
  not truly gapless.

import SwiftUI

@main
struct iPodifyApp: App {
    @StateObject private var auth: SpotifyAuth
    @StateObject private var library: Library
    @StateObject private var player: Player
    @StateObject private var ipod: IPod
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let auth = SpotifyAuth()
        let api = SpotifyAPI(auth: auth)
        let library = Library(api: api)
        let player = Player(api: api)
        _auth = StateObject(wrappedValue: auth)
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: player)
        _ipod = StateObject(wrappedValue: IPod(auth: auth, library: library, player: player))
    }

    var body: some Scene {
        WindowGroup {
            IPodView(ipod: ipod, library: library, player: player)
                .task {
                    guard auth.isSignedIn else { return }
                    player.startPolling()
                    await library.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard auth.isSignedIn else { return }
                    if phase == .active {
                        player.startPolling()
                        player.syncSystemVolume()
                        Task {
                            await player.resumePending()
                            // Pick up playlist edits made in Spotify. Unchanged playlists are skipped.
                            await library.sync()
                        }
                    } else if phase == .background {
                        player.stopPolling()
                    }
                }
                .onChange(of: auth.isSignedIn) { _, signedIn in
                    if signedIn { player.startPolling() } else { player.stopPolling(); ipod.returnToSignIn() }
                }
        }
    }
}

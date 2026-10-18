import AudioToolbox
import SwiftUI
import UIKit

enum Screen: Hashable {
    case signIn, main, music, playlists, playlist(Playlist), artists, artist(String),
         artistSongs(String), albums, album(String), songs, nowPlaying, settings, about
}

struct MenuItem {
    enum Action {
        case push(Screen)
        case play([Track], Int, Playlist?)
        case shuffleAll, signIn, sync, signOut, toggleClicker, toggleTheme, none
    }
    var title: String
    var detail: String? = nil
    var chevron = true
    var action: Action
}

enum Theme: String { case silver, black }

/// The iPod's brain: a stack of menus, a highlighted row per menu, and the five buttons.
@MainActor
final class IPod: ObservableObject {
    struct Level { var screen: Screen; var selection = 0; var top = 0 }

    @Published private(set) var stack: [Level]
    @Published var alert: String?
    @Published private(set) var wheelMode: WheelMode = .volume
    @Published private(set) var showVolumeUntil = Date.distantPast
    @Published var clicker: Bool { didSet { UserDefaults.standard.set(clicker, forKey: "clicker") } }
    @Published var theme: Theme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") } }

    enum WheelMode { case volume, scrub }

    let visibleRows = 7
    let auth: SpotifyAuth
    let library: Library
    let player: Player

    private let stepHaptic = UISelectionFeedbackGenerator()
    private let pressHaptic = UIImpactFeedbackGenerator(style: .medium)

    init(auth: SpotifyAuth, library: Library, player: Player) {
        self.auth = auth
        self.library = library
        self.player = player
        stack = [Level(screen: auth.isSignedIn ? .main : .signIn)]
        clicker = UserDefaults.standard.object(forKey: "clicker") as? Bool ?? true
        theme = Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .silver
    }

    var current: Level { stack[stack.count - 1] }

    // MARK: Menus

    func title(for screen: Screen) -> String {
        switch screen {
        case .signIn, .main: return "iPod"
        case .music: return "Music"
        case .playlists: return "Playlists"
        case .playlist(let p): return p.name
        case .artists: return "Artists"
        case .artist(let a), .artistSongs(let a): return a
        case .albums: return "Albums"
        case .album(let a): return a
        case .songs: return "Songs"
        case .nowPlaying: return "Now Playing"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    func items(for screen: Screen) -> [MenuItem] {
        switch screen {
        case .signIn:
            return [MenuItem(title: "Sign in to Spotify", action: .signIn)]

        case .main:
            var items = [
                MenuItem(title: "Music", action: .push(.music)),
                MenuItem(title: "Settings", action: .push(.settings)),
                MenuItem(title: "Shuffle Songs", chevron: false, action: .shuffleAll),
            ]
            if player.track != nil { items.append(MenuItem(title: "Now Playing", action: .push(.nowPlaying))) }
            return items

        case .music:
            return [
                MenuItem(title: "Playlists", action: .push(.playlists)),
                MenuItem(title: "Artists", action: .push(.artists)),
                MenuItem(title: "Albums", action: .push(.albums)),
                MenuItem(title: "Songs", action: .push(.songs)),
            ]

        case .playlists:
            return library.playlists.map { MenuItem(title: $0.name, action: .push(.playlist($0))) }

        case .playlist(let p):
            return songItems(library.tracks(in: p), playlist: p)

        case .artists:
            return library.artists.map { MenuItem(title: $0, action: .push(.artist($0))) }

        case .artist(let artist):
            return [MenuItem(title: "All Songs", action: .push(.artistSongs(artist)))]
                + library.albums(by: artist).map { MenuItem(title: $0, action: .push(.album($0))) }

        case .artistSongs(let artist):
            return songItems(library.songs(byArtist: artist))

        case .albums:
            return library.albums().map { MenuItem(title: $0, action: .push(.album($0))) }

        case .album(let album):
            return songItems(library.songs(onAlbum: album))

        case .songs:
            return songItems(library.songs)

        case .settings:
            return [
                MenuItem(title: "About", action: .push(.about)),
                MenuItem(title: "Sync Playlists", chevron: false, action: .sync),
                MenuItem(title: "Clicker", detail: clicker ? "On" : "Off", chevron: false, action: .toggleClicker),
                MenuItem(title: "Color", detail: theme == .silver ? "Silver" : "Black", chevron: false, action: .toggleTheme),
                MenuItem(title: "Sign Out", chevron: false, action: .signOut),
            ]

        case .about:
            let synced = library.snapshot.syncedAt.map {
                $0.formatted(.relative(presentation: .named))
            } ?? "Never"
            let info: [(String, String)] = [
                ("Songs", "\(library.snapshot.tracks.count)"),
                ("Playlists", "\(library.playlists.count)"),
                ("Artists", "\(library.artists.count)"),
                ("Synced", synced),
                ("Playing on", player.deviceName ?? "—"),
            ]
            return info.map { MenuItem(title: $0.0, detail: $0.1, chevron: false, action: .none) }

        case .nowPlaying:
            return []
        }
    }

    func emptyMessage(for screen: Screen) -> String? {
        switch screen {
        case .playlists, .artists, .albums, .songs:
            return library.playlists.isEmpty
                ? "No music yet.\nIn Spotify, start a playlist's name with \"\(Config.playlistPrefix)\", then choose Settings › Sync Playlists."
                : nil
        default: return nil
        }
    }

    private func songItems(_ tracks: [Track], playlist: Playlist? = nil) -> [MenuItem] {
        tracks.enumerated().map { i, t in MenuItem(title: t.name, chevron: false, action: .play(tracks, i, playlist)) }
    }

    // MARK: Buttons

    func wheel(_ delta: Int) {
        alert = nil
        library.lastError = nil
        if current.screen == .nowPlaying {
            switch wheelMode {
            case .volume:
                player.changeVolume(by: delta)
                showVolumeUntil = Date().addingTimeInterval(2)
            case .scrub:
                player.scrub(by: delta)
            }
            click()
            return
        }

        let count = items(for: current.screen).count
        guard count > 0 else { return }
        var level = current
        let newSelection = max(0, min(count - 1, level.selection + delta))
        guard newSelection != level.selection else { return }
        level.selection = newSelection
        if level.selection < level.top { level.top = level.selection }
        if level.selection >= level.top + visibleRows { level.top = level.selection - visibleRows + 1 }
        stack[stack.count - 1] = level
        click()
    }

    func select() {
        press()
        if alert != nil || library.lastError != nil { alert = nil; library.lastError = nil; return }
        if current.screen == .nowPlaying {
            wheelMode = wheelMode == .volume ? .scrub : .volume
            return
        }
        let items = items(for: current.screen)
        guard items.indices.contains(current.selection) else { return }

        switch items[current.selection].action {
        case .push(let screen): push(screen)
        case .play(let tracks, let index, let playlist):
            run { try await self.player.play(tracks, startAt: index, in: playlist) }
            push(.nowPlaying)
        case .shuffleAll:
            let shuffled = library.songs.shuffled()
            guard !shuffled.isEmpty else { alert = emptyMessage(for: .songs); return }
            run { try await self.player.play(shuffled, startAt: 0) }
            push(.nowPlaying)
        case .signIn:
            run {
                try await self.auth.signIn()
                self.stack = [Level(screen: .main)]
                await self.library.sync()
            }
        case .sync:
            Task { await library.sync() }
        case .signOut:
            auth.signOut()
            library.clear()
            stack = [Level(screen: .signIn)]
        case .toggleClicker: clicker.toggle()
        case .toggleTheme: theme = theme == .silver ? .black : .silver
        case .none: break
        }
    }

    func menu() {
        press()
        alert = nil
        library.lastError = nil
        wheelMode = .volume
        if stack.count > 1 { stack.removeLast() }
    }

    func playPause() {
        press()
        run { try await self.player.togglePlayPause() }
    }

    func next() {
        press()
        run { try await self.player.next() }
    }

    func previous() {
        press()
        run { try await self.player.previous() }
    }

    func returnToSignIn() {
        stack = [Level(screen: .signIn)]
    }

    // MARK: Helpers

    private func push(_ screen: Screen) {
        wheelMode = .volume
        stack.append(Level(screen: screen))
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() }
            catch { alert = error.localizedDescription }
        }
    }

    private func click() {
        stepHaptic.selectionChanged()
        if clicker { AudioServicesPlaySystemSound(1104) }
    }

    private func press() {
        pressHaptic.impactOccurred()
        if clicker { AudioServicesPlaySystemSound(1104) }
    }
}

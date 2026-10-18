import Foundation

struct Track: Codable, Hashable, Identifiable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let durationMs: Int
}

struct Playlist: Codable, Hashable, Identifiable {
    let id: String
    let uri: String
    let name: String
    let snapshotID: String?
    let trackIDs: [String]
}

/// What's "on the iPod": only the prefixed playlists, plus everything derived from them.
struct LibrarySnapshot: Codable {
    var playlists: [Playlist] = []
    var tracks: [String: Track] = [:]
    var syncedAt: Date?
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var snapshot: LibrarySnapshot
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus = ""
    @Published var lastError: String?

    private let api: SpotifyAPI
    private static let cacheURL = URL.documentsDirectory.appending(path: "library.json")

    init(api: SpotifyAPI) {
        self.api = api
        snapshot = (try? JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: Self.cacheURL))) ?? .init()
    }

    // MARK: Derived views, iPod-style

    var playlists: [Playlist] { snapshot.playlists }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { snapshot.tracks[$0] }
    }

    var songs: [Track] {
        snapshot.tracks.values.sorted { Self.sortKey($0.name) < Self.sortKey($1.name) }
    }

    var artists: [String] {
        Set(snapshot.tracks.values.map(\.artist)).sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    func albums(by artist: String? = nil) -> [String] {
        let tracks = snapshot.tracks.values.filter { artist == nil || $0.artist == artist }
        return Set(tracks.map(\.album)).sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    func songs(byArtist artist: String) -> [Track] {
        // Grouped by album, then title, like the iPod's "All Songs" under an artist.
        snapshot.tracks.values.filter { $0.artist == artist }
            .sorted { (Self.sortKey($0.album), Self.sortKey($0.name)) < (Self.sortKey($1.album), Self.sortKey($1.name)) }
    }

    func songs(onAlbum album: String) -> [Track] {
        let byID = snapshot.tracks.values.filter { $0.album == album }
        // Keep the order they appear in your playlists rather than alphabetical.
        let order = snapshot.playlists.flatMap(\.trackIDs)
        return byID.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }

    /// The iPod ignored a leading "The" when sorting.
    static func sortKey(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.hasPrefix("the ") ? String(lower.dropFirst(4)) : lower
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; syncStatus = "" }

        do {
            syncStatus = "Finding playlists…"
            let all: [SPPlaylist] = try await api.getAllPages("/me/playlists", query: ["limit": "50"])
            let marked = all.compactMap { sp in Config.iPodName(forPlaylist: sp.name).map { (sp, $0) } }

            var next = LibrarySnapshot()
            var skipped: [String] = []
            for (index, (sp, name)) in marked.enumerated() {
                syncStatus = "Syncing \(index + 1) of \(marked.count)"

                // Reuse the cached copy when the playlist hasn't changed.
                if let cached = snapshot.playlists.first(where: { $0.id == sp.id }),
                   cached.snapshotID != nil, cached.snapshotID == sp.snapshot_id {
                    next.playlists.append(Playlist(id: sp.id, uri: sp.uri, name: name,
                                                   snapshotID: sp.snapshot_id, trackIDs: cached.trackIDs))
                    for id in cached.trackIDs { next.tracks[id] = snapshot.tracks[id] }
                    continue
                }

                let items: [SPPlaylistItem]
                do {
                    items = try await api.getAllPages("/playlists/\(sp.id)/items", query: ["limit": "100"])
                } catch let error as SpotifyAPI.APIError where error.code == 403 {
                    // Spotify only shares songs from playlists you own or collaborate on.
                    skipped.append(name)
                    continue
                }
                var ids: [String] = []
                for case let t? in items.map(\.track) where (t.type ?? "track") == "track" {
                    guard let id = t.id else { continue }  // local files have no Spotify ID
                    ids.append(id)
                    next.tracks[id] = Track(
                        id: id, uri: t.uri, name: t.name,
                        artist: t.artists.first?.name ?? "Unknown Artist",
                        album: t.album.name,
                        artworkURL: (t.album.images?.first { $0.width == 300 } ?? t.album.images?.first)
                            .flatMap { URL(string: $0.url) },
                        durationMs: t.duration_ms
                    )
                }
                next.playlists.append(Playlist(id: sp.id, uri: sp.uri, name: name,
                                               snapshotID: sp.snapshot_id, trackIDs: ids))
            }
            next.syncedAt = .now
            snapshot = next
            try? JSONEncoder().encode(next).write(to: Self.cacheURL, options: .atomic)
            if !skipped.isEmpty {
                lastError = "Couldn't load \(skipped.joined(separator: ", ")). Spotify only shares playlists you made or collaborate on."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clear() {
        snapshot = .init()
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }
}

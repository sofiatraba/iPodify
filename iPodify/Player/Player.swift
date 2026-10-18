import Foundation
import UIKit

/// Drives the Spotify app (on this iPhone, or wherever Spotify Connect points) through the Web API.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var progressMs = 0
    @Published private(set) var progressStamp = Date()
    @Published private(set) var volume = 50
    @Published private(set) var queue: [Track] = []
    @Published private(set) var deviceName: String?

    private let api: SpotifyAPI
    private var device: SPDevice?
    private var pollTask: Task<Void, Never>?
    private var pending: (tracks: [Track], index: Int, playlist: Playlist?)?
    private var volumeTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var holdRefreshUntil = Date.distantPast

    init(api: SpotifyAPI) { self.api = api }

    enum PlayerError: LocalizedError {
        case openingSpotify
        var errorDescription: String? { "Opening Spotify… Come back to keep listening." }
    }

    // MARK: State

    var queuePosition: (index: Int, count: Int)? {
        guard let track, let i = queue.firstIndex(where: { $0.id == track.id }) else { return nil }
        return (i + 1, queue.count)
    }

    func progress(at date: Date) -> Int {
        let elapsed = isPlaying ? Int(date.timeIntervalSince(progressStamp) * 1000) : 0
        return min(progressMs + elapsed, track?.durationMs ?? .max)
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Right after a command Spotify still reports the old state; don't let it undo our optimistic update.
        guard Date() >= holdRefreshUntil else { return }
        let state: SPPlayback?
        do { state = try await api.get("/me/player") } catch { return }
        guard let state else {
            isPlaying = false
            return
        }
        device = state.device
        deviceName = state.device?.name
        if let v = state.device?.volume_percent, volumeTask == nil { volume = v }
        isPlaying = state.is_playing
        if seekTask == nil {
            progressMs = state.progress_ms ?? 0
            progressStamp = Date()
        }
        if let t = state.item?.value, let id = t.id {
            track = queue.first { $0.id == id } ?? Track(
                id: id, uri: t.uri, name: t.name,
                artist: t.artists.first?.name ?? "", album: t.album.name,
                artworkURL: t.album.images?.first.flatMap { URL(string: $0.url) },
                durationMs: t.duration_ms
            )
        }
    }

    // MARK: Commands

    func play(_ tracks: [Track], startAt index: Int, in playlist: Playlist? = nil) async throws {
        guard tracks.indices.contains(index) else { return }
        guard let deviceID = try await targetDeviceID() else {
            pending = (tracks, index, playlist)
            await UIApplication.shared.open(URL(string: "spotify:")!)
            throw PlayerError.openingSpotify
        }

        var body: [String: Any]
        if let playlist {
            body = ["context_uri": playlist.uri, "offset": ["uri": tracks[index].uri]]
            queue = tracks
        } else {
            // Spotify takes a limited list of URIs, so send a window starting at the chosen song.
            let window = Array(tracks[index..<min(index + 100, tracks.count)])
            body = ["uris": window.map(\.uri)]
            queue = window
        }
        try? await api.send("PUT", "/me/player/shuffle", query: ["state": "false", "device_id": deviceID])
        try await api.send("PUT", "/me/player/play", query: ["device_id": deviceID], json: body)

        track = tracks[index]
        isPlaying = true
        progressMs = 0
        progressStamp = Date()
        holdRefresh()
    }

    /// Called when the app comes back to the foreground, e.g. after we opened Spotify to wake it.
    func resumePending() async {
        guard let pending else { return }
        self.pending = nil
        for _ in 0..<3 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await targetDeviceID()) != nil {
                try? await play(pending.tracks, startAt: pending.index, in: pending.playlist)
                return
            }
        }
    }

    func togglePlayPause() async throws {
        let wasPlaying = isPlaying
        progressMs = progress(at: Date())
        progressStamp = Date()
        isPlaying.toggle()
        holdRefresh()
        do {
            try await api.send("PUT", wasPlaying ? "/me/player/pause" : "/me/player/play")
        } catch let error as SpotifyAPI.APIError where error.code == 404 {
            // No active device: restart whatever was last chosen.
            isPlaying = wasPlaying
            if let track, let i = queue.firstIndex(of: track) { try await play(queue, startAt: i) }
            else { throw error }
        }
    }

    func next() async throws {
        try await api.send("POST", "/me/player/next")
        stepQueue(by: 1)
    }

    /// Like the iPod: restart the song if it's a few seconds in, otherwise go back one.
    func previous() async throws {
        if progress(at: Date()) > 3000 {
            try await api.send("PUT", "/me/player/seek", query: ["position_ms": "0"])
            progressMs = 0
            progressStamp = Date()
        } else {
            try await api.send("POST", "/me/player/previous")
            stepQueue(by: -1)
        }
        holdRefresh()
    }

    func changeVolume(by steps: Int) {
        volume = max(0, min(100, volume + steps * 4))
        if device?.supports_volume == false {
            SystemVolume.shared.set(Float(volume) / 100)
            return
        }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            try? await self.api.send("PUT", "/me/player/volume", query: ["volume_percent": "\(self.volume)"])
            self.volumeTask = nil
        }
    }

    func scrub(by steps: Int) {
        guard let track else { return }
        progressMs = max(0, min(track.durationMs - 1000, progress(at: Date()) + steps * 5000))
        progressStamp = Date()
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            try? await self.api.send("PUT", "/me/player/seek", query: ["position_ms": "\(self.progressMs)"])
            self.progressStamp = Date()
            self.seekTask = nil
            self.holdRefresh()
        }
    }

    func syncSystemVolume() {
        if device?.supports_volume == false { volume = Int(SystemVolume.shared.current * 100) }
    }

    // MARK: Helpers

    private func stepQueue(by delta: Int) {
        if let track, let i = queue.firstIndex(of: track), queue.indices.contains(i + delta) {
            self.track = queue[i + delta]
            progressMs = 0
            progressStamp = Date()
        }
        holdRefresh()
    }

    private func holdRefresh() {
        holdRefreshUntil = Date().addingTimeInterval(1.5)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            await self?.refresh()
        }
    }

    /// Prefer Spotify on an iPhone (this is an iPod, after all), then whatever is active.
    private func targetDeviceID() async throws -> String? {
        let response: SPDevices? = try await api.get("/me/player/devices")
        let usable = (response?.devices ?? []).filter { $0.id != nil && $0.is_restricted != true }
        let chosen = usable.first { $0.type == "Smartphone" } ?? usable.first(where: \.is_active) ?? usable.first
        if let chosen { device = chosen; deviceName = chosen.name }
        return chosen?.id
    }
}

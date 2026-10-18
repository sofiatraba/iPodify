import Foundation

/// Thin Spotify Web API client. Retries once on an expired token and once on rate limiting.
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private let base = URL(string: "https://api.spotify.com/v1")!

    init(auth: SpotifyAuth) { self.auth = auth }

    enum APIError: LocalizedError {
        case status(Int, String)
        var errorDescription: String? {
            switch self { case .status(let code, let body): return "Spotify error \(code): \(body)" }
        }
        var code: Int { if case .status(let c, _) = self { return c }; return 0 }
    }

    /// GET a path ("/me/playlists") or a full `next` URL. Returns nil on 204 No Content.
    func get<T: Decodable>(_ pathOrURL: String, query: [String: String] = [:]) async throws -> T? {
        let data = try await perform("GET", pathOrURL, query: query, json: nil)
        guard let data, !data.isEmpty else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws {
        _ = try await perform(method, path, query: query, json: json)
    }

    /// Follows `next` links until every page is loaded.
    func getAllPages<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        var results: [T] = []
        var page: Page<T>? = try await get(path, query: query)
        while let current = page {
            results += current.items.compactMap(\.value)
            guard let next = current.next else { break }
            page = try await get(next)
        }
        return results
    }

    private func perform(_ method: String, _ pathOrURL: String, query: [String: String], json: [String: Any]?,
                         attempt: Int = 0) async throws -> Data? {
        var components: URLComponents
        if pathOrURL.hasPrefix("http") {
            components = URLComponents(string: pathOrURL)!
        } else {
            components = URLComponents(url: base.appendingPathComponent(pathOrURL), resolvingAgainstBaseURL: false)!
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if method != "GET" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200..<300:
            return status == 204 ? nil : data
        case 401 where attempt == 0:
            return try await perform(method, pathOrURL, query: query, json: json, attempt: 1)
        case 429 where attempt == 0:
            let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            try await Task.sleep(for: .seconds(min(wait, 10)))
            return try await perform(method, pathOrURL, query: query, json: json, attempt: 1)
        default:
            let body = String(decoding: data, as: UTF8.self)
            NSLog("[iPodify] %@ %@ -> %d %@", method, components.path, status, body)
            throw APIError.status(status, "\(method) \(components.path): \(body)")
        }
    }
}

// MARK: - Spotify response shapes

/// Decodes to nil instead of failing the whole page (podcast episodes, local files, unavailable tracks).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct Page<T: Decodable>: Decodable {
    let items: [Lenient<T>]
    let next: String?
}

struct SPImage: Decodable { let url: String; let width: Int? }
struct SPArtist: Decodable { let name: String }
struct SPAlbum: Decodable { let name: String; let images: [SPImage]? }

struct SPTrack: Decodable {
    let id: String?
    let uri: String
    let name: String
    let duration_ms: Int
    let artists: [SPArtist]
    let album: SPAlbum
    let type: String?
}

struct SPPlaylist: Decodable {
    let id: String
    let uri: String
    let name: String
    let snapshot_id: String?
}

/// Playlist entry. Since Feb 2026 the track lives under `item`; older responses used `track`.
struct SPPlaylistItem: Decodable {
    let track: SPTrack?

    enum CodingKeys: String, CodingKey { case item, track }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = (try? c.decodeIfPresent(SPTrack.self, forKey: .item))
            ?? (try? c.decodeIfPresent(SPTrack.self, forKey: .track))
    }
}

struct SPDevice: Decodable {
    let id: String?
    let name: String
    let type: String
    let is_active: Bool
    let is_restricted: Bool?
    let volume_percent: Int?
    let supports_volume: Bool?
}

struct SPDevices: Decodable { let devices: [SPDevice] }

struct SPPlayback: Decodable {
    let device: SPDevice?
    let is_playing: Bool
    let progress_ms: Int?
    let item: Lenient<SPTrack>?
    let shuffle_state: Bool?
}

import Foundation

enum Config {
    /// From your app at developer.spotify.com → Dashboard → your app → Settings.
    /// The Client ID is not a secret; this app uses PKCE, so there is no client secret.
    static let spotifyClientID = "7dda45f9fbf3427ab6efd06d1c9d590d"

    /// Must be added exactly like this under "Redirect URIs" in the Spotify dashboard.
    static let redirectURI = "ipodify://callback"
    static let callbackScheme = "ipodify"

    /// Playlists whose names start with this word go on the iPod. Everything else is ignored.
    /// Name a playlist "iPod Sunday Morning" (or "ipod - Sunday Morning") in Spotify
    /// and it shows up as "Sunday Morning". Capitals don't matter.
    static let playlistPrefix = "iPod"

    /// The iPod name for a Spotify playlist, or nil if it isn't marked for the iPod.
    static func iPodName(forPlaylist name: String) -> String? {
        guard name.lowercased().hasPrefix(playlistPrefix.lowercased()) else { return nil }
        let rest = name.dropFirst(playlistPrefix.count)
        // "iPodcasts" isn't marked; "iPod Sunday", "iPod: Sunday", "iPod - Sunday" are.
        if let next = rest.first, next.isLetter || next.isNumber { return nil }
        let trimmed = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ":-–—·•|/")))
        return trimmed.isEmpty ? nil : trimmed
    }

    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
    ]
}

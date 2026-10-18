# iPod (for Spotify)

An iPod classic for your iPhone. It only holds the music you put on it: Spotify playlists whose names start with the word `iPod`.

## Web version (no Xcode needed)

https://sofiatraba.github.io/iPodify/ is the same iPod as a web app, served from `docs/` by GitHub Pages.

1. In the Spotify dashboard, open the app's **Settings › Redirect URIs**, add `https://sofiatraba.github.io/iPodify/` and save.
2. On the iPhone, open the link in **Safari**, tap **Share › Add to Home Screen**.
3. Open the iPod from the Home Screen icon and sign in there. The Home Screen app keeps its own sign-in, separate from Safari.

Differences from the native app: the wheel clicks with sound only, since iOS doesn't let web pages vibrate. On Now Playing the wheel scrubs; use the side buttons for volume, because Spotify on an iPhone doesn't accept volume changes from other apps.

## Curating your iPod

- In Spotify, rename a playlist to start with `iPod`, for example `iPod Sunday Morning`. On the iPod it shows up as just `Sunday Morning`. Capitals don't matter, and `iPod: Sunday Morning` or `iPod - Sunday Morning` work too.
- On the iPod, choose **Settings › Sync Playlists**. It also syncs each time you open the app.
- **Artists**, **Albums** and **Songs** are built only from those playlists.
- Only playlists you **own or collaborate on** work. This is a Spotify rule from February 2026. To use someone else's playlist, copy its songs into one of your own.

## Controls

| Wheel | What it does |
|---|---|
| Turn | Scrolls menus. On Now Playing, changes the volume |
| Center | Selects. On Now Playing, switches the wheel between volume and scrubbing |
| MENU | Goes back |
| ⏮ / ⏭ | Previous or next song (⏮ restarts the song if it's more than 3 seconds in) |
| ⏯ | Play or pause |

Music plays through the Spotify app. The iPod is its remote, with a click wheel. If Spotify isn't running, the iPod opens it once. Come back to the iPod and playback starts.

## One-time setup

### 1. Spotify developer app (about 5 minutes)
1. Go to https://developer.spotify.com/dashboard and log in. You need Premium.
2. Click **Create app**:
   - Name: `iPod`. Description: anything.
   - Redirect URI: `ipodify://callback` (click **Add**)
   - APIs used: tick **Web API** and **iOS**
   - iOS bundle ID (if asked): `com.sofiatraba.ipodify`
3. Save, open **Settings**, and copy the **Client ID**.
4. Paste it into `iPodify/Config.swift` in place of `PASTE_YOUR_CLIENT_ID_HERE`.

Development-mode Spotify apps work for the owner plus up to 5 users you add under **User Management**.

### 2. Run it
1. Install **Xcode** from the Mac App Store and open it once to finish setup.
2. Open `iPodify.xcodeproj`.
3. Simulator: choose an iPhone and press ⌘R. Music will play on whatever device has Spotify open, such as your Mac.
4. Your iPhone: connect it, select it at the top of Xcode, go to **Signing & Capabilities**, choose your Apple ID as the Team, and press ⌘R. On the phone, allow it under Settings › General › VPN & Device Management. With a free Apple ID, reinstall every 7 days.

If you change `project.yml`, regenerate the project with `xcodegen generate`.

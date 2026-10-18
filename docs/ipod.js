'use strict';

// ---------------------------------------------------------------------------
// Config (mirrors iPodify/Config.swift)
// ---------------------------------------------------------------------------

/** Not a secret: sign-in uses PKCE, so there is no client secret. */
const CLIENT_ID = '7dda45f9fbf3427ab6efd06d1c9d590d';
/** Must be listed exactly like this under "Redirect URIs" in the Spotify dashboard. */
const REDIRECT_URI = new URL('./', location.href).href;
const SCOPES = [
  'playlist-read-private',
  'playlist-read-collaborative',
  'user-read-playback-state',
  'user-modify-playback-state',
  'user-read-currently-playing',
];
/** Playlists whose names start with this word go on the iPod. Everything else is ignored. */
const PLAYLIST_PREFIX = 'iPod';
const VISIBLE_ROWS = 7;
const STEPS_PER_TURN = 20;

/** "iPod Sunday", "iPod: Sunday", "ipod - Sunday" → "Sunday". "iPodcasts" or "Road trip" → null. */
function iPodName(name) {
  if (!name.toLowerCase().startsWith(PLAYLIST_PREFIX.toLowerCase())) return null;
  const rest = name.slice(PLAYLIST_PREFIX.length);
  if (rest && /[\p{L}\p{N}]/u.test(rest[0])) return null;
  const trimmed = rest.replace(/^[\s:\-–—·•|/]+|[\s:\-–—·•|/]+$/g, '');
  return trimmed || null;
}

// localStorage can throw (private mode, blocked storage); the iPod still works for the session.
const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(key, value) {
    try { value == null ? localStorage.removeItem(key) : localStorage.setItem(key, JSON.stringify(value)); } catch {}
  },
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Spotify sign-in: Authorization Code + PKCE
// ---------------------------------------------------------------------------

const auth = {
  tokens: store.get('tokens', null),
  refreshing: null,

  get signedIn() { return !!this.tokens; },

  async signIn() {
    const verifier = randomString(64);
    const state = randomString(16);
    store.set('pkce', { verifier, state });
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
    const params = new URLSearchParams({
      client_id: CLIENT_ID,
      response_type: 'code',
      redirect_uri: REDIRECT_URI,
      code_challenge_method: 'S256',
      code_challenge: base64url(new Uint8Array(digest)),
      state,
      scope: SCOPES.join(' '),
    });
    location.assign('https://accounts.spotify.com/authorize?' + params);
  },

  /** Finishes sign-in when Spotify sends us back with ?code=…; returns true if it did. */
  async handleRedirect() {
    const query = new URLSearchParams(location.search);
    if (!query.has('code') && !query.has('error')) return false;
    history.replaceState(null, '', location.pathname);
    const pkce = store.get('pkce', null);
    store.set('pkce', null);
    if (query.has('error')) throw new Error(query.get('error') === 'access_denied' ? 'Sign-in cancelled' : 'Spotify sign-in failed: ' + query.get('error'));
    if (!pkce || pkce.state !== query.get('state')) throw new Error('Sign-in expired. Try again.');
    await this.requestTokens({
      grant_type: 'authorization_code',
      code: query.get('code'),
      redirect_uri: REDIRECT_URI,
      code_verifier: pkce.verifier,
    });
    return true;
  },

  async accessToken(forceRefresh = false) {
    if (!this.tokens) throw new Error('Not signed in');
    if (!forceRefresh && Date.now() < this.tokens.expiresAt - 60_000) return this.tokens.accessToken;
    this.refreshing ??= this.requestTokens({ grant_type: 'refresh_token', refresh_token: this.tokens.refreshToken })
      .finally(() => { this.refreshing = null; });
    await this.refreshing;
    return this.tokens.accessToken;
  },

  async requestTokens(params) {
    const response = await fetch('https://accounts.spotify.com/api/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: CLIENT_ID, ...params }),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (params.grant_type === 'refresh_token' && body.error === 'invalid_grant') { this.signOut(); ipod.returnToSignIn(); }
      throw new Error('Spotify sign-in failed: ' + (body.error_description || body.error || response.status));
    }
    this.tokens = {
      accessToken: body.access_token,
      // Spotify may rotate the refresh token; keep the old one if it doesn't.
      refreshToken: body.refresh_token || this.tokens?.refreshToken,
      expiresAt: Date.now() + body.expires_in * 1000,
    };
    store.set('tokens', this.tokens);
  },

  signOut() {
    this.tokens = null;
    store.set('tokens', null);
  },
};

function randomString(length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return Array.from(crypto.getRandomValues(new Uint8Array(length)), b => chars[b % chars.length]).join('');
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ---------------------------------------------------------------------------
// Spotify Web API: retries once on an expired token and once on rate limiting
// ---------------------------------------------------------------------------

class APIError extends Error {
  constructor(status, body, path) {
    super(friendlyError(status, body) || `Spotify error ${status} (${path})`);
    this.status = status;
    this.reason = body?.error?.reason;
  }
}

function friendlyError(status, body) {
  if (body?.error?.reason === 'PREMIUM_REQUIRED') return 'Playing music from the iPod needs Spotify Premium.';
  if (status === 404) return 'Spotify isn\'t open. Open the Spotify app, then try again.';
  if (status === 403 && /premium/i.test(body?.error?.message || '')) return 'Playing music from the iPod needs Spotify Premium.';
  return body?.error?.message ? `Spotify: ${body.error.message}` : null;
}

async function api(method, pathOrURL, { query, json } = {}, attempt = 0) {
  const url = new URL(pathOrURL.startsWith('http') ? pathOrURL : 'https://api.spotify.com/v1' + pathOrURL);
  for (const [k, v] of Object.entries(query || {})) url.searchParams.set(k, v);
  const headers = { Authorization: 'Bearer ' + await auth.accessToken(attempt > 0) };
  if (json) headers['Content-Type'] = 'application/json';

  const response = await fetch(url, { method, headers, body: json ? JSON.stringify(json) : undefined });
  if (response.ok) {
    if (response.status === 204) return null;
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  if (response.status === 401 && attempt === 0) return api(method, pathOrURL, { query, json }, 1);
  if (response.status === 429 && attempt === 0) {
    await sleep(Math.min(Number(response.headers.get('Retry-After')) || 1, 10) * 1000);
    return api(method, pathOrURL, { query, json }, 1);
  }
  const body = await response.json().catch(() => null);
  throw new APIError(response.status, body, url.pathname);
}

/** Follows `next` links until every page is loaded. */
async function getAllPages(path, query) {
  const results = [];
  let page = await api('GET', path, { query });
  while (page) {
    results.push(...page.items.filter(Boolean));
    page = page.next ? await api('GET', page.next) : null;
  }
  return results;
}

function toTrack(t) {
  const images = t.album?.images || [];
  return {
    id: t.id,
    uri: t.uri,
    name: t.name,
    artist: t.artists?.[0]?.name || 'Unknown Artist',
    album: t.album?.name || '',
    art: (images.find(i => i.width === 300) || images[0])?.url || null,
    durationMs: t.duration_ms,
  };
}

// ---------------------------------------------------------------------------
// Library: only the prefixed playlists, plus everything derived from them
// ---------------------------------------------------------------------------

const library = {
  snapshot: store.get('library', null) || { playlists: [], tracks: {}, syncedAt: null },
  syncing: false,
  status: '',
  error: null,
  derived: null,

  get playlists() { return this.snapshot.playlists; },
  playlist(id) { return this.playlists.find(p => p.id === id); },
  tracksIn(p) { return p.trackIDs.map(id => this.snapshot.tracks[id]).filter(Boolean); },

  /** Sorted views, rebuilt only when a sync replaces the snapshot. */
  get views() {
    if (this.derived?.snapshot === this.snapshot) return this.derived;
    const all = Object.values(this.snapshot.tracks);
    const order = new Map(this.playlists.flatMap(p => p.trackIDs).map((id, i) => [id, i]).reverse());
    const cmp = (a, b) => sortKey(a).localeCompare(sortKey(b));
    this.derived = {
      snapshot: this.snapshot,
      songs: [...all].sort((a, b) => cmp(a.name, b.name)),
      artists: [...new Set(all.map(t => t.artist))].sort(cmp),
      albums: [...new Set(all.map(t => t.album))].sort(cmp),
      all, order, cmp,
    };
    return this.derived;
  },
  get songs() { return this.views.songs; },
  get artists() { return this.views.artists; },
  albums(artist) {
    const v = this.views;
    return artist == null ? v.albums : [...new Set(v.all.filter(t => t.artist === artist).map(t => t.album))].sort(v.cmp);
  },
  songsByArtist(artist) {
    // Grouped by album, then title, like the iPod's "All Songs" under an artist.
    const { all, cmp } = this.views;
    return all.filter(t => t.artist === artist).sort((a, b) => cmp(a.album, b.album) || cmp(a.name, b.name));
  },
  songsOnAlbum(album) {
    // Keep the order they appear in your playlists rather than alphabetical.
    const { all, order } = this.views;
    return all.filter(t => t.album === album).sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
  },

  async sync() {
    if (this.syncing || !auth.signedIn) return;
    this.syncing = true;
    this.error = null;
    render();
    try {
      this.status = 'Finding playlists…'; render();
      const all = await getAllPages('/me/playlists', { limit: 50 });
      const marked = all.map(sp => [sp, iPodName(sp.name)]).filter(([, name]) => name);

      const next = { playlists: [], tracks: {}, syncedAt: null };
      const skipped = [];
      for (const [index, [sp, name]] of marked.entries()) {
        this.status = `Syncing ${index + 1} of ${marked.length}`; render();

        // Reuse the cached copy when the playlist hasn't changed.
        const cached = this.playlist(sp.id);
        if (cached?.snapshotID && cached.snapshotID === sp.snapshot_id) {
          next.playlists.push({ ...cached, name });
          for (const id of cached.trackIDs) if (this.snapshot.tracks[id]) next.tracks[id] = this.snapshot.tracks[id];
          continue;
        }

        let items;
        try {
          items = await getAllPages(`/playlists/${sp.id}/items`, { limit: 100 });
        } catch (e) {
          // Spotify only shares songs from playlists you own or collaborate on.
          if (e.status === 403) { skipped.push(name); continue; }
          throw e;
        }
        const ids = [];
        for (const entry of items) {
          // Since Feb 2026 the track lives under `item`; older responses used `track`.
          const t = entry.item || entry.track;
          if (!t || (t.type && t.type !== 'track') || !t.id) continue;  // episodes, local files
          ids.push(t.id);
          next.tracks[t.id] = toTrack(t);
        }
        next.playlists.push({ id: sp.id, uri: sp.uri, name, snapshotID: sp.snapshot_id, trackIDs: ids });
      }
      next.syncedAt = Date.now();
      this.snapshot = next;
      store.set('library', next);
      if (skipped.length) this.error = `Couldn't load ${skipped.join(', ')}. Spotify only shares playlists you made or collaborate on.`;
    } catch (e) {
      this.error = e.message;
    } finally {
      this.syncing = false;
      this.status = '';
      render();
    }
  },

  clear() {
    this.snapshot = { playlists: [], tracks: {}, syncedAt: null };
    store.set('library', null);
  },
};

/** The iPod ignored a leading "The" when sorting. */
function sortKey(s) {
  const lower = s.toLowerCase();
  return lower.startsWith('the ') ? lower.slice(4) : lower;
}

// ---------------------------------------------------------------------------
// Player: drives the Spotify app through the Web API
// ---------------------------------------------------------------------------

const player = {
  track: null,
  isPlaying: false,
  progressMs: 0,
  progressStamp: Date.now(),
  volume: 50,
  queue: [],
  device: null,
  pending: null,
  pollTimer: null,
  volumeTimer: null,
  seekTimer: null,
  holdUntil: 0,

  get deviceName() { return this.device?.name || null; },
  /** Spotify on an iPhone won't take volume changes from outside; the side buttons still work. */
  get canSetVolume() { return this.device?.supports_volume !== false; },

  get queuePosition() {
    if (!this.track) return null;
    const i = this.queue.findIndex(t => t.id === this.track.id);
    return i < 0 ? null : { index: i + 1, count: this.queue.length };
  },

  progress(now = Date.now()) {
    const elapsed = this.isPlaying ? now - this.progressStamp : 0;
    return Math.min(this.progressMs + elapsed, this.track?.durationMs ?? Infinity);
  },

  startPolling() {
    this.stopPolling();
    const tick = async () => { await this.refresh(); this.pollTimer = setTimeout(tick, 2000); };
    tick();
  },

  stopPolling() {
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
  },

  async refresh() {
    // Right after a command Spotify still reports the old state; don't let it undo our optimistic update.
    if (!auth.signedIn || Date.now() < this.holdUntil) return;
    let state;
    try { state = await api('GET', '/me/player'); } catch { return; }
    if (!state) { this.isPlaying = false; render(); return; }
    this.device = state.device || this.device;
    if (state.device?.volume_percent != null && !this.volumeTimer) this.volume = state.device.volume_percent;
    this.isPlaying = state.is_playing;
    if (!this.seekTimer) { this.progressMs = state.progress_ms || 0; this.progressStamp = Date.now(); }
    const t = state.item;
    if (t?.id && t.type !== 'episode') this.track = this.queue.find(q => q.id === t.id) || toTrack(t);
    render();
  },

  async play(tracks, index, playlist) {
    if (!tracks[index]) return;
    const deviceID = await this.targetDeviceID();
    if (!deviceID) {
      // Nothing to play on: wake the Spotify app, then pick up again when the iPod comes back.
      this.pending = { tracks, index, playlist };
      location.href = 'spotify:';
      throw new Error('Opening Spotify… Come back to keep listening.');
    }

    let body;
    if (playlist) {
      body = { context_uri: playlist.uri, offset: { uri: tracks[index].uri } };
      this.queue = tracks;
    } else {
      // Spotify takes a limited list of URIs, so send a window starting at the chosen song.
      const window = tracks.slice(index, index + 100);
      body = { uris: window.map(t => t.uri) };
      this.queue = window;
    }
    await api('PUT', '/me/player/shuffle', { query: { state: 'false', device_id: deviceID } }).catch(() => {});
    await api('PUT', '/me/player/play', { query: { device_id: deviceID }, json: body });

    this.track = tracks[index];
    this.isPlaying = true;
    this.progressMs = 0;
    this.progressStamp = Date.now();
    this.holdRefresh();
  },

  /** Called when the iPod comes back to the front, e.g. after we opened Spotify to wake it. */
  async resumePending() {
    const pending = this.pending;
    if (!pending) return;
    this.pending = null;
    for (let i = 0; i < 3; i++) {
      await sleep(1000);
      if (await this.targetDeviceID().catch(() => null)) {
        try { await this.play(pending.tracks, pending.index, pending.playlist); } catch (e) { ipod.alert = e.message; }
        render();
        return;
      }
    }
  },

  async togglePlayPause() {
    const wasPlaying = this.isPlaying;
    this.progressMs = this.progress();
    this.progressStamp = Date.now();
    this.isPlaying = !wasPlaying;
    this.holdRefresh();
    render();
    try {
      await api('PUT', wasPlaying ? '/me/player/pause' : '/me/player/play');
    } catch (e) {
      this.isPlaying = wasPlaying;
      // No active device: restart whatever was last chosen.
      const i = this.track ? this.queue.findIndex(t => t.id === this.track.id) : -1;
      if (e.status === 404 && i >= 0) await this.play(this.queue, i);
      else throw e;
    }
  },

  async next() {
    await api('POST', '/me/player/next');
    this.stepQueue(1);
  },

  /** Like the iPod: restart the song if it's a few seconds in, otherwise go back one. */
  async previous() {
    if (this.progress() > 3000) {
      await api('PUT', '/me/player/seek', { query: { position_ms: 0 } });
      this.progressMs = 0;
      this.progressStamp = Date.now();
      this.holdRefresh();
    } else {
      await api('POST', '/me/player/previous');
      this.stepQueue(-1);
    }
  },

  changeVolume(steps) {
    this.volume = Math.max(0, Math.min(100, this.volume + steps * 4));
    clearTimeout(this.volumeTimer);
    this.volumeTimer = setTimeout(async () => {
      await api('PUT', '/me/player/volume', { query: { volume_percent: this.volume } }).catch(() => {});
      this.volumeTimer = null;
    }, 150);
  },

  scrub(steps) {
    if (!this.track) return;
    this.progressMs = Math.max(0, Math.min(this.track.durationMs - 1000, this.progress() + steps * 5000));
    this.progressStamp = Date.now();
    clearTimeout(this.seekTimer);
    this.seekTimer = setTimeout(async () => {
      await api('PUT', '/me/player/seek', { query: { position_ms: this.progressMs } }).catch(() => {});
      this.progressStamp = Date.now();
      this.seekTimer = null;
      this.holdRefresh();
    }, 300);
  },

  stepQueue(delta) {
    const i = this.track ? this.queue.findIndex(t => t.id === this.track.id) : -1;
    if (i >= 0 && this.queue[i + delta]) {
      this.track = this.queue[i + delta];
      this.progressMs = 0;
      this.progressStamp = Date.now();
    }
    this.holdRefresh();
  },

  holdRefresh() {
    this.holdUntil = Date.now() + 1500;
    setTimeout(() => this.refresh(), 1600);
  },

  /** Prefer Spotify on a phone (this is an iPod, after all), then whatever is active. */
  async targetDeviceID() {
    const response = await api('GET', '/me/player/devices');
    const usable = (response?.devices || []).filter(d => d.id && !d.is_restricted);
    const chosen = usable.find(d => d.type === 'Smartphone') || usable.find(d => d.is_active) || usable[0];
    if (chosen) this.device = chosen;
    return chosen?.id || null;
  },
};

// ---------------------------------------------------------------------------
// The iPod's brain: a stack of menus, a highlighted row per menu, and the five buttons
// ---------------------------------------------------------------------------

const ipod = {
  stack: [{ screen: { type: auth.signedIn ? 'main' : 'signIn' }, selection: 0, top: 0 }],
  alert: null,
  wheelMode: 'volume',
  showVolumeUntil: 0,
  clicker: store.get('clicker', true),
  theme: store.get('theme', 'silver'),

  get current() { return this.stack[this.stack.length - 1]; },

  title(s) {
    switch (s.type) {
      case 'signIn': case 'main': return 'iPod';
      case 'music': return 'Music';
      case 'playlists': return 'Playlists';
      case 'playlist': return library.playlist(s.arg)?.name || 'Playlist';
      case 'artists': return 'Artists';
      case 'artist': case 'artistSongs': case 'album': return s.arg;
      case 'albums': return 'Albums';
      case 'songs': return 'Songs';
      case 'nowPlaying': return 'Now Playing';
      case 'settings': return 'Settings';
      case 'about': return 'About';
    }
    return 'iPod';
  },

  items(s) {
    const push = (title, type, arg) => ({ title, chevron: true, action: { push: { type, arg } } });
    const songs = (tracks, playlist) => tracks.map((t, i) => ({ title: t.name, action: { play: [tracks, i, playlist] } }));

    switch (s.type) {
      case 'signIn':
        return [{ title: 'Sign in to Spotify', chevron: true, action: { signIn: true } }];
      case 'main': {
        const items = [push('Music', 'music'), push('Settings', 'settings'), { title: 'Shuffle Songs', action: { shuffleAll: true } }];
        if (player.track) items.push(push('Now Playing', 'nowPlaying'));
        return items;
      }
      case 'music':
        return [push('Playlists', 'playlists'), push('Artists', 'artists'), push('Albums', 'albums'), push('Songs', 'songs')];
      case 'playlists':
        return library.playlists.map(p => push(p.name, 'playlist', p.id));
      case 'playlist': {
        const p = library.playlist(s.arg);
        return p ? songs(library.tracksIn(p), p) : [];
      }
      case 'artists':
        return library.artists.map(a => push(a, 'artist', a));
      case 'artist':
        return [push('All Songs', 'artistSongs', s.arg), ...library.albums(s.arg).map(a => push(a, 'album', a))];
      case 'artistSongs':
        return songs(library.songsByArtist(s.arg));
      case 'albums':
        return library.albums().map(a => push(a, 'album', a));
      case 'album':
        return songs(library.songsOnAlbum(s.arg));
      case 'songs':
        return songs(library.songs);
      case 'settings':
        return [
          push('About', 'about'),
          { title: 'Sync Playlists', action: { sync: true } },
          { title: 'Clicker', detail: this.clicker ? 'On' : 'Off', action: { toggleClicker: true } },
          { title: 'Color', detail: this.theme === 'silver' ? 'Silver' : 'Black', action: { toggleTheme: true } },
          { title: 'Sign Out', action: { signOut: true } },
        ];
      case 'about':
        return [
          ['Songs', Object.keys(library.snapshot.tracks).length],
          ['Playlists', library.playlists.length],
          ['Artists', library.artists.length],
          ['Synced', library.snapshot.syncedAt ? timeAgo(library.snapshot.syncedAt) : 'Never'],
          ['Playing on', player.deviceName || '—'],
        ].map(([title, detail]) => ({ title, detail: String(detail), action: {} }));
    }
    return [];
  },

  emptyMessage(s) {
    if (['playlists', 'artists', 'albums', 'songs'].includes(s.type) && !library.playlists.length) {
      return `No music yet.\nIn Spotify, start a playlist's name with "${PLAYLIST_PREFIX}", then choose Settings › Sync Playlists.`;
    }
    return null;
  },

  /** On Now Playing the wheel changes volume, or scrubs when Spotify won't take volume (iPhone). */
  get npWheel() { return player.canSetVolume ? this.wheelMode : 'scrub'; },

  wheel(delta) {
    this.dismiss();
    if (this.current.screen.type === 'nowPlaying') {
      if (this.npWheel === 'volume') { player.changeVolume(delta); this.showVolumeUntil = Date.now() + 2000; }
      else player.scrub(delta);
      feedback.click();
      render();
      return;
    }
    const count = this.items(this.current.screen).length;
    const level = this.current;
    const selection = Math.max(0, Math.min(count - 1, level.selection + delta));
    if (!count || selection === level.selection) return;
    level.selection = selection;
    if (selection < level.top) level.top = selection;
    if (selection >= level.top + VISIBLE_ROWS) level.top = selection - VISIBLE_ROWS + 1;
    feedback.click();
    render();
  },

  select() {
    feedback.press();
    if (this.alert || library.error) { this.dismiss(); render(); return; }
    const screen = this.current.screen;
    if (screen.type === 'nowPlaying') {
      if (player.canSetVolume) this.wheelMode = this.wheelMode === 'volume' ? 'scrub' : 'volume';
      render();
      return;
    }
    const item = this.items(screen)[this.current.selection];
    const a = item?.action || {};
    if (a.push) this.push(a.push);
    else if (a.play) { this.run(() => player.play(...a.play)); this.push({ type: 'nowPlaying' }); }
    else if (a.shuffleAll) {
      const shuffled = [...library.songs];
      for (let i = shuffled.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]]; }
      if (!shuffled.length) this.alert = this.emptyMessage({ type: 'songs' });
      else { this.run(() => player.play(shuffled, 0)); this.push({ type: 'nowPlaying' }); }
    }
    else if (a.signIn) this.run(() => auth.signIn());
    else if (a.sync) library.sync();
    else if (a.signOut) { auth.signOut(); library.clear(); player.stopPolling(); this.returnToSignIn(); }
    else if (a.toggleClicker) { this.clicker = !this.clicker; store.set('clicker', this.clicker); }
    else if (a.toggleTheme) { this.theme = this.theme === 'silver' ? 'black' : 'silver'; store.set('theme', this.theme); }
    render();
  },

  menu() {
    feedback.press();
    this.dismiss();
    this.wheelMode = 'volume';
    if (this.stack.length > 1) this.stack.pop();
    render();
  },

  playPause() { feedback.press(); this.run(() => player.togglePlayPause()); },
  next() { feedback.press(); this.run(() => player.next()); },
  previous() { feedback.press(); this.run(() => player.previous()); },

  returnToSignIn() { this.stack = [{ screen: { type: 'signIn' }, selection: 0, top: 0 }]; render(); },

  push(screen) {
    this.wheelMode = 'volume';
    this.stack.push({ screen, selection: 0, top: 0 });
  },

  dismiss() { this.alert = null; library.error = null; },

  async run(work) {
    try { await work(); } catch (e) { this.alert = e.message; }
    render();
  },
};

function timeAgo(ms) {
  const minutes = Math.round((Date.now() - ms) / 60000);
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hr ago`;
  const days = Math.round(hours / 24);
  return days === 1 ? 'Yesterday' : `${days} days ago`;
}

// ---------------------------------------------------------------------------
// Feedback: a click sound, plus a Taptic tick where Safari allows it
// ---------------------------------------------------------------------------

const feedback = {
  audio: null,
  switchInput: document.getElementById('haptic'),

  /** Called on the first touch: Safari only starts audio from a gesture. */
  unlock() {
    if (this.audio) { if (this.audio.state === 'suspended') this.audio.resume(); return; }
    // "ambient" mixes with Spotify instead of pausing it.
    try { if (navigator.audioSession) navigator.audioSession.type = 'ambient'; } catch {}
    try { this.audio = new (window.AudioContext || window.webkitAudioContext)(); } catch {}
  },

  haptic() {
    // Flipping a native switch is the only way a web page can tick the Taptic Engine on iPhone.
    if ('switch' in this.switchInput) this.switchInput.parentElement.click();
    else navigator.vibrate?.(8);
  },

  sound(gainLevel) {
    if (!ipod.clicker || !this.audio) return;
    try {
      const t = this.audio.currentTime, osc = this.audio.createOscillator(), gain = this.audio.createGain();
      osc.type = 'square';
      osc.frequency.value = 2400;
      gain.gain.setValueAtTime(gainLevel, t);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.012);
      osc.connect(gain).connect(this.audio.destination);
      osc.start(t);
      osc.stop(t + 0.015);
    } catch {}
  },

  click() { this.haptic(); this.sound(0.06); },
  press() { this.haptic(); this.sound(0.1); },
};

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const $ = id => document.getElementById(id);

function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null) el.append(c);
  return el;
}

function svg(viewBox, d, cls) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  el.setAttribute('viewBox', viewBox);
  if (cls) el.setAttribute('class', cls);
  el.innerHTML = d;
  return el;
}

const CHEVRON = '<path d="M1.5 1.5 5.5 5.5 1.5 9.5"/>';
const SPEAKER = '<path d="M0 3.5h2.5L6 .5v9L2.5 6.5H0z"/>';
const SPEAKER_LOUD = SPEAKER + '<path d="M7.5 3a2.5 2.5 0 0 1 0 4M9 1.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="1.1"/>';

let renderQueued = false;
function render() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => { renderQueued = false; draw(); });
}

function draw() {
  document.body.className = ipod.theme;
  const screen = ipod.current.screen;
  $('title').textContent = ipod.title(screen);
  $('state').innerHTML = player.isPlaying ? '<path d="M1 0v10l8-5z"/>' : '<path d="M1 0h3v10H1zM6 0h3v10H6z"/>';

  const body = $('body');
  const nodes = [];
  if (library.syncing && (!library.snapshot.syncedAt || screen.type === 'settings')) {
    nodes.push(h('div', { class: 'message' }, h('div', { class: 'spinner' }), h('b', {}, 'Syncing…'), library.status || 'Do not disconnect.'));
  } else if (screen.type === 'nowPlaying') {
    nodes.push(drawNowPlaying());
  } else {
    nodes.push(drawMenu());
  }
  const message = ipod.alert || library.error;
  if (message) nodes.push(h('div', { class: 'alert', role: 'alert' }, message));
  body.replaceChildren(...nodes);
}

function drawMenu() {
  const level = ipod.current;
  const items = ipod.items(level.screen);
  const empty = ipod.emptyMessage(level.screen);
  if (!items.length && empty) return h('div', { class: 'message' }, empty);

  const rows = items.slice(level.top, level.top + VISIBLE_ROWS).map((item, i) =>
    h('div', { class: 'row' + (level.top + i === level.selection ? ' sel' : '') },
      h('span', { class: 't' }, item.title),
      item.detail != null ? h('span', { class: 'd' }, item.detail) : null,
      item.chevron ? svg('0 0 7 11', CHEVRON, 'c') : null));

  const list = h('div', { class: 'menu-list' }, h('div', { class: 'rows' }, rows));
  if (items.length > VISIBLE_ROWS) {
    const thumb = Math.max(12 / ($('body').clientHeight || 1), VISIBLE_ROWS / items.length);
    const offset = (1 - thumb) * level.top / Math.max(1, items.length - VISIBLE_ROWS);
    list.append(h('div', { class: 'scrollbar' }, h('i', { style: `top:${offset * 100}%;height:${thumb * 100}%` })));
  }
  if (level.screen.type === 'signIn' && !isStandalone() && /iPhone|iPad/.test(navigator.userAgent)) {
    list.append(h('div', { class: 'footnote' }, 'First tap Share › Add to Home Screen, then sign in from the iPod icon.'));
  }
  return list;
}

let artCache = { url: undefined, node: null };
function artwork(url) {
  if (artCache.url === url) return artCache.node;
  const image = () => url ? h('img', { src: url, alt: '' }) : h('div', { class: 'ph' }, '♪\uFE0E');
  artCache = { url, node: h('div', { class: 'art' }, image(), h('div', { class: 'refl' }, image())) };
  return artCache.node;
}

function drawNowPlaying() {
  const t = player.track;
  const pos = player.queuePosition;
  const art = Math.round(Math.min($('body').clientHeight * 0.52, $('body').clientWidth * 0.34));

  let bottom;
  if (ipod.npWheel === 'volume' && Date.now() < ipod.showVolumeUntil) {
    bottom = h('div', { class: 'barrow' },
      svg('0 0 10 10', SPEAKER),
      h('div', { class: 'bar' }, h('div', { class: 'fill', style: `width:${player.volume}%` })),
      svg('0 0 12 10', SPEAKER_LOUD));
  } else {
    const elapsed = player.progress(), duration = t?.durationMs || 0;
    const pct = duration ? Math.min(100, elapsed / duration * 100) : 0;
    bottom = h('div', {},
      h('div', { class: 'bar' },
        h('div', { class: 'fill', style: `width:${pct}%` }),
        // The knob marks scrub mode; on an iPhone the wheel always scrubs, so it isn't needed.
        ipod.wheelMode === 'scrub' && player.canSetVolume ? h('div', { class: 'knob', style: `left:${pct}%` }) : null),
      h('div', { class: 'times' }, h('span', {}, clock(elapsed)), h('span', {}, '-' + clock(Math.max(0, duration - elapsed)))));
  }

  return h('div', { class: 'np', style: `--art:${art}px` },
    h('div', { class: 'pos' }, pos ? `${pos.index} of ${pos.count}` : ''),
    h('div', { class: 'main' },
      artwork(t?.art || null),
      h('div', { class: 'info' },
        h('div', { class: 'song' }, t?.name || 'Not Playing'),
        h('div', { class: 'artist' }, t?.artist || ''),
        h('div', { class: 'album' }, t?.album || ''))),
    h('div', { class: 'bottom' }, bottom));
}

function clock(ms) {
  const s = Math.floor(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function isStandalone() {
  return navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
}

/** Screen on top, wheel filling what's left, like IPodView.swift. */
function layout() {
  const gutter = 22;
  const w = Math.min(window.innerWidth, 500) - gutter * 2;
  const style = getComputedStyle($('ipod'));
  const usable = window.innerHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
  const screenH = Math.min(w * 0.78, usable * 0.45);
  const wheel = Math.min(w * 0.86, usable - screenH - 32);
  const root = document.documentElement.style;
  root.setProperty('--screen-w', w + 'px');
  root.setProperty('--screen-h', screenH + 'px');
  root.setProperty('--wheel-size', Math.max(160, wheel) + 'px');
  render();
}

// ---------------------------------------------------------------------------
// Click wheel input: drag around the ring to scroll, tap its edges for the buttons, tap the center to select
// ---------------------------------------------------------------------------

(function wheelInput() {
  const wheel = $('wheel'), center = $('center');
  let lastAngle = null, accumulated = 0, travelled = 0, inCenter = false, start = null;

  const geometry = e => {
    const r = wheel.getBoundingClientRect();
    const x = e.clientX - (r.left + r.width / 2), y = e.clientY - (r.top + r.height / 2);
    return { angle: Math.atan2(y, x), dist: Math.hypot(x, y) / r.width };
  };

  wheel.addEventListener('pointerdown', e => {
    feedback.unlock();
    wheel.setPointerCapture(e.pointerId);
    const g = geometry(e);
    inCenter = g.dist < 0.19;
    start = { x: e.clientX, y: e.clientY };
    if (inCenter) { center.classList.add('down'); return; }
    lastAngle = g.angle; accumulated = 0; travelled = 0;
  });

  wheel.addEventListener('pointermove', e => {
    if (inCenter || lastAngle === null) return;
    const { angle } = geometry(e);
    let delta = angle - lastAngle;
    if (delta > Math.PI) delta -= 2 * Math.PI;
    if (delta < -Math.PI) delta += 2 * Math.PI;
    lastAngle = angle;
    accumulated += delta;
    travelled += Math.abs(delta);
    const step = 2 * Math.PI / STEPS_PER_TURN;
    while (accumulated >= step) { accumulated -= step; ipod.wheel(1); }
    while (accumulated <= -step) { accumulated += step; ipod.wheel(-1); }
  });

  wheel.addEventListener('pointerup', e => {
    if (inCenter) {
      center.classList.remove('down');
      inCenter = false;
      ipod.select();
      return;
    }
    if (lastAngle === null) return;
    lastAngle = null;
    // Barely moved: it's a press on one of the four buttons.
    if (travelled >= 0.15 || Math.hypot(e.clientX - start.x, e.clientY - start.y) >= 12) return;
    const degrees = geometry(e).angle * 180 / Math.PI;
    if (degrees >= -135 && degrees < -45) ipod.menu();
    else if (degrees >= -45 && degrees < 45) ipod.next();
    else if (degrees >= 45 && degrees < 135) ipod.playPause();
    else ipod.previous();
  });

  wheel.addEventListener('pointercancel', () => {
    center.classList.remove('down');
    inCenter = false;
    lastAngle = null;
  });

  // Keyboard, for trying it on a computer.
  wheel.addEventListener('keydown', e => {
    feedback.unlock();
    const keys = {
      ArrowDown: () => ipod.wheel(1), ArrowRight: () => ipod.wheel(1),
      ArrowUp: () => ipod.wheel(-1), ArrowLeft: () => ipod.wheel(-1),
      Enter: () => ipod.select(), Escape: () => ipod.menu(), Backspace: () => ipod.menu(),
      ' ': () => ipod.playPause(), '.': () => ipod.next(), ',': () => ipod.previous(),
    };
    if (keys[e.key]) { keys[e.key](); e.preventDefault(); }
  });
})();

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

window.addEventListener('resize', layout);
document.addEventListener('gesturestart', e => e.preventDefault());  // no pinch-zoom on the iPod
setInterval(() => { if (ipod.current.screen.type === 'nowPlaying') render(); }, 500);

document.addEventListener('visibilitychange', () => {
  if (!auth.signedIn) return;
  if (document.visibilityState === 'visible') {
    player.startPolling();
    player.resumePending();
    // Pick up playlist changes made in Spotify while the iPod was away.
    if (Date.now() - (library.snapshot.syncedAt || 0) > 10 * 60_000) library.sync();
  } else {
    player.stopPolling();
  }
});

(async function start() {
  layout();
  try {
    if (await auth.handleRedirect()) ipod.stack = [{ screen: { type: 'main' }, selection: 0, top: 0 }];
  } catch (e) {
    ipod.alert = e.message;
  }
  render();
  if (auth.signedIn) {
    player.startPolling();
    library.sync();
  }
})();

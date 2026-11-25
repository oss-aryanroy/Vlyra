<p align="center"><img src="brand/vlyra-icon.svg" width="96" height="96" alt=""></p>

<h1 align="center">Vlyra</h1>

<p align="center">
An open, self-hosted media server that other applications can contribute to, not just read
from. One library, several protocols, and every client or integration is an <b>app</b> with
its own permissions and an audit trail.
</p>

Written in [V](https://vlang.io); the web UI is plain HTML, CSS and JavaScript
compiled into the binary. Licensed under the GPL-3.0 (see `LICENSE`).

## Run

```sh
brew install vlang ffmpeg      # ffmpeg/ffprobe are optional but recommended
v -prod -o vlyra .
./vlyra --media ~/Music        # then open http://localhost:4040
```

The first visit asks you to choose the admin password. Flags: `--port` (4040),
`--host` (0.0.0.0), `--data` (`./data`: database and artwork), `--media`.

Run the tests with `v test .`

To deploy to a server running Docker, `VLYRA_SSH="-i ~/.ssh/key user@host" deploy/deploy.sh`
compiles on your machine (in Docker, for the server's CPU), sends only the binary to
`~/vlyra` on the server, and restarts it; nothing is compiled on the server. Setup is
in `deploy/compose.yaml`. To compile on the server instead, build `deploy/Dockerfile`
with `--target source`.

## How it fits together

```
 web UI ─┐                       ┌─ items, lyrics, artwork
 apps ───┤ native API  /api/v1 ──┤
 clients ┘ Subsonic    /rest   ──┤  core.v  ── SQLite (data/vlyra.db)
           Jellyfin    /...    ──┘   every write is attributed
```

| File          | Role                                                                 |
| ------------- | -------------------------------------------------------------------- |
| `core.v`      | The single source of truth: items, playlists, plays, attributed writes |
| `sql_fast.v`  | Direct C `sqlite3_stmt` prepared-statement cache and read connection pool |
| `auth.v`      | Apps, scopes, admin sessions, protocol switches                        |
| `scan.v`      | Indexes the media folder (directory-mtime `scan_fast` skip, native tags, `ffprobe` fallback) |
| `tags.v`      | In-process tag, artwork, lyrics, ReplayGain, and audio-tech readers for mp3/flac/m4a/m4b/ogg/oga/opus/wav/aac; aiff/wma/wv/ape/mka go to `ffprobe` |
| `api.v`       | Native JSON API (`ETag`/`304`, `gzip`) and media/artwork streaming     |
| `subsonic.v`  | Subsonic / OpenSubsonic translation layer; owns no data                |
| `jellyfin.v`  | Jellyfin translation layer for music clients; owns no data             |
| `scrobble.v`  | Forwards every listen to ListenBrainz and/or Last.fm                   |
| `web/`        | The management UI                                                      |

A protocol is a translation layer over `core.v`. To add one, add its name to
`protocols` in `auth.v`, a `ProtocolInfo` line in `api.v`, and a file of routes
that checks `app.protocol_on('name')`.

## Apps and permissions

Create an app under **Apps**. It gets an API token (shown once; only its SHA-256
is stored) and any mix of these scopes, changeable or revocable at any time:

| Resource    | `:read`                 | `:write`                         |
| ----------- | ----------------------- | -------------------------------- |
| `library`   | browse, search, stream  | edit title, artist, album, genre, year, track, tags |
| `lyrics`    | read lyrics             | add or replace lyrics            |
| `artwork`   | fetch cover art         | upload cover art                 |
| `playlists` | list playlists          | create, edit, delete             |
| `history`   | read listening history  | report listens (scrobble)        |
| `ratings`   | see album ratings       | rate albums 1 to 5 stars         |

Every write is recorded with who made it, the old value and the new value
(**Activity**, or per item under *Edit → Who changed this*). The media folder is
checked every few seconds: new files are added, missing ones flagged and tags
re-read from files that changed on disk, but a field that you or an app has
edited is never overwritten.

Subsonic clients need a second secret: Subsonic's login scheme requires the
server to know the original password, so it cannot be hashed. Tick *It is a
Subsonic client* when creating the app to get a separate Subsonic password. It
is stored readable in `data/vlyra.db` (created `0600`), works only on `/rest`,
and apps without one cannot sign in over Subsonic at all. Keep that file and its
backups private.

## Native API

Send `Authorization: Bearer <token>`. Errors are `{"error": "..."}` with 400,
401 (unknown or paused app), 403 (missing scope) or 404.

| Method & path                         | Scope             | Body / notes                                  |
| ------------------------------------- | ----------------- | --------------------------------------------- |
| `GET /api/v1/me`                      | none              | who am I, which scopes                        |
| `GET /api/v1/items?q=&limit=&offset=` | `library:read`    | `{items, total}`                              |
| `GET /api/v1/items/:id`               | `library:read`    |                                               |
| `PATCH /api/v1/items/:id`             | `library:write`   | any of `title artist album genre year track_no disc_no tags` |
| `GET /api/v1/items/:id/stream`        | `library:read`    | supports `Range`                              |
| `GET` / `PUT /api/v1/items/:id/lyrics`  | `lyrics:read` / `lyrics:write`   | `{"text": "..."}`, plain or LRC  |
| `GET` / `PUT /api/v1/items/:id/artwork` | `artwork:read` / `artwork:write` | raw JPEG, PNG, WebP or GIF body  |
| `GET` / `POST /api/v1/playlists`        | `playlists:read` / `playlists:write` | `{"name", "item_ids": []}`   |
| `GET` / `PUT` / `DELETE /api/v1/playlists/:id` | same       | `PUT`: `name` and/or the full `item_ids` order |
| `GET` / `POST /api/v1/plays`            | `history:read` / `history:write` | `{"item_id", "at"?: unix seconds}` |
| `PUT /api/v1/albums/rating`             | `ratings:write`   | `{"artist", "album", "rating": 0-5}`; 0 clears it |

```sh
curl -X PUT localhost:4040/api/v1/items/3/lyrics \
  -H "Authorization: Bearer $TOKEN" -d '{"text":"[00:01.50]First line"}'
```

Admin-only endpoints used by the web UI (`/apps`, `/activity`, `/settings`,
`/scan`, `/setup`, `/session`) are in `api.v`.

## Subsonic

Server URL is the Vlyra address; username is the app name; password is the
app's Subsonic password, or pass the app's API token via OpenSubsonic `apiKey`
authentication (`apiKeyAuthentication`). Supported: browsing (ID3 and folder
style), album lists (including highest rated and starred), starring (`star`,
`unstar`, `getStarred`, `getStarred2`), play queues (`savePlayQueue`,
`getPlayQueue`), search, streaming, cover art, lyrics (plain and synced),
playlists, album ratings (`setRating` on an album id), scrobbling. JSON and XML.

Vlyra also adds its own `vlyraTags` extension, so a Subsonic client can edit a
song with the password it already has: `vlyraGetTags?id=` (`library:read`;
lyrics with `lyrics:read`), `vlyraSetTags?id=` with any of `title artist
albumArtist album genre year track` (`library:write`) and `lyrics`
(`lyrics:write`), as query or form parameters, and `vlyraSetCoverArt?id=` with
the image as the POST body (`artwork:write`). Edits are attributed like any
other; files on disk are never rewritten.

## Jellyfin

Server URL is the Vlyra address; username is the app name; password is the
app's API token (which also becomes the client's Jellyfin access token, so no
extra secret is stored). Supported for music: libraries, albums, artists,
tracks, search (`/Search/Hints`), item counts (`/Items/Counts`), genres,
favorites (`FavoriteItems` / `UserFavoriteItems` and `IsFavorite` filter),
streaming, cover art, lyrics, playlists, and reporting listens. As in Jellyfin
itself, cover images are served without sign-in while the protocol is switched
on. It has been exercised with scripted requests, not yet with real client
apps, and video libraries are not exposed.

## Scrobbling

Every listen Vlyra records (web player, Subsonic `scrobble`, Jellyfin playback
reports, `POST /api/v1/plays`) is also sent to the accounts connected under
**Settings → Scrobbling**: ListenBrainz (paste your user token) and Last.fm
(your own API key and secret, then approve Vlyra on last.fm). Credentials are
stored in `data/vlyra.db` and never returned by the API. A failed send is logged
to stderr and not retried; the listen stays in Vlyra's history either way.
Outbound HTTPS checks certificates against the system CA bundle (`SSL_CERT_FILE`
to override).

## Compared with Navidrome

Same machine (Apple M5), same generated library of 10,000 tracks (1,000 albums,
250 artists), Navidrome 0.64.2 against Vlyra's optimised build, measured back to
back on the same day.

| | Vlyra | Navidrome |
| --- | --- | --- |
| Binary | 3.8 MB | 66 MB |
| Start and first scan | 1.0 s | 9.6 s |
| Memory, idle after scan | 52 MB | 63 MB |
| Memory after the load test | 143 MB | 105 MB |

Subsonic requests, 3,000 each at 20 concurrent (HTTP/1.1 keep-alive), no errors on either:

| Request | Vlyra req/s (p99) | Navidrome req/s (p99) |
| --- | --- | --- |
| ping | 30,404 (2 ms) | 6,208 (18 ms) |
| stream a 16 KB file | 26,694 (2 ms) | 3,195 (19 ms) |
| getArtists | 9,792 (6 ms) | 906 (41 ms) |
| album list, newest 50 | 8,442 (7 ms) | 2,267 (17 ms) |
| album list, random 50 | 12,053 (4 ms) | 921 (38 ms) |
| getAlbum | 21,877 (3 ms) | 2,268 (15 ms) |
| search "harbour" | 9,061 (6 ms) | 303 (120 ms) |
| 50 random songs | 6,054 (10 ms) | 590 (57 ms) |

Navidrome returns more fields per item, so its responses are larger. The test
files above are 2-second generated tones over loopback, so they only measure
metadata and small-file overhead.

### Real FLAC streaming

Measured on a 6-vCPU ARM64 Linux VPS (7.7 GiB RAM, SSD) in Docker (`vlyra` vs.
`deluan/navidrome:0.64.2`) over loopback against a real library of **177 FLAC
files** (71 albums, 84 artists, **4.96 GiB** total, avg **28.7 MiB** /
4.3–105.5 MiB, avg duration 205 s, avg bitrate **1,173 kbps**). Fresh idle
Vlyra container footprint: **6.4 MiB** RSS. No errors on either server:

| Scenario | Vlyra throughput (p99 TTFB · peak RSS) | Navidrome 0.64.2 (p99 TTFB · peak RSS) |
| --- | --- | --- |
| Non-Range `c = 10` (full FLACs) | 637.4 MiB/s (46.9 ms · 7.1 MiB) | 414.5 MiB/s (82.9 ms · 159.1 MiB) |
| Non-Range `c = 50` (full FLACs) | 472.9 MiB/s (260.8 ms · 27.8 MiB) | — |
| Range `c = 10` (full FLACs) | 826.9 MiB/s (23.3 ms · 13.0 MiB) | 394.8 MiB/s (92.7 ms · 178.2 MiB) |
| Range `c = 50` (full FLACs) | 508.7 MiB/s (145.9 ms · 36.9 MiB) | 548.8 MiB/s (199.4 ms · 270.6 MiB) |
| Range `c = 100` (full FLACs) | 464.6 MiB/s (408.6 ms · 113.3 MiB) | 478.4 MiB/s (933.5 ms · 318.4 MiB) |
| Live-paced `c = 200` (1,173 kbps × 5 s) | 24.2 MiB/s (327.7 ms · 130.2% CPU) | 20.0 MiB/s (1,802.3 ms · 373.2% CPU) |

At 3.9–6.9 Gbps of sustained direct-stream throughput, outbound network
bandwidth—not CPU or RAM—is the limiting factor on this VPS (roughly ~830
concurrent 1,173 kbps FLAC listeners per Gbps of upload).

## Runtime & scanner benchmarks

Measured locally on an **Apple M5** (10 cores, 16 GiB RAM) with a native C
HTTP/1.1 keep-alive benchmarker (8 threads, warmed up, 3–5 interleaved rounds,
0 errors).

### Scanner, artwork & HTTP caching

Sample library: **5,000 tracks** (mixed MP3, FLAC, M4A) across **250 albums**,
with 5 embedded 400×400 JPEG covers tested for artwork extraction and dedup.

| Benchmark | Before | After | Change |
| --- | --- | --- | --- |
| Cold initial scan (5,000 tracks) | 212.0 ms | 188.5 ms | −11.1% |
| Idle watch tick (`scan` → `scan_fast`) | 20.34 ms | 0.509 ms | 40.0× faster |
| Cold embedded artwork extraction (50 tracks, 5 albums) | 1,112.9 ms (`ffmpeg`) | 16.06 ms (in-process) | 69.3× faster |
| Artwork disk usage (50 tracks, 5 shared covers) | 1,034,350 B | 23,099 B | −97.8% (44.8× smaller) |
| Gzip wire size: `/api/v1/items?limit=1000` | 340,547 B | 21,206 B | −93.8% |
| Gzip wire size: `/api/v1/albums` | 89,088 B | 6,164 B | −93.1% |
| Gzip wire size: `/rest/getArtists?f=json` | 8,007 B | 1,290 B | −83.9% |

Conditional `304 Not Modified` throughput (8 threads, 0-byte body):

| Endpoint | Throughput |
| --- | --- |
| `/api/v1/albums` | 96,440 req/s |
| `/rest/getArtists?f=json` | 76,267 req/s |
| `/api/v1/items/:id/artwork` | 58,042 req/s |

### Direct C `sqlite3_stmt` cache & protocol endpoints

Sample library: **5,000 tracks**, **1,000 albums**, **200 artists** (8 threads,
3 interleaved rounds, median req/s).

| Endpoint | Before | After | Change |
| --- | --- | --- | --- |
| `/api/v1/albums` (1,000 albums) | 1,025 req/s | 8,401 req/s | 8.2× |
| `/api/v1/items?limit=1000` | 833 req/s | 2,678 req/s | 3.2× |
| `/api/v1/items?limit=200` | 7,794 req/s | 10,747 req/s | +37.9% |
| `/rest/getArtists?f=json` | 11,199 req/s | 13,505 req/s | +20.6% |
| `/rest/search3?query=Artist&f=json` | 9,569 req/s | 13,579 req/s | +41.9% |
| `/Items/Counts` | — | 18,489 req/s | new |
| `/Search/Hints?searchTerm=Artist` | — | 9,047 req/s | new |
| `/rest/getStarred2?f=json` | — | 6,136 req/s | new |

Post-load RSS on Apple M5 dropped from **80.9 MB** to **76.9 MB**; on the
6-vCPU ARM64 VPS in Docker (`deploy-vlyra-1`, 177-FLAC library), idle RSS after
migrating and indexing the new audio/tech fields is **10.7 MiB**.

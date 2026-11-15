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
| `auth.v`      | Apps, scopes, admin sessions, protocol switches                        |
| `scan.v`      | Indexes the media folder (native tag parsing, `ffprobe` fallback)      |
| `tags.v`      | In-process tag readers for mp3/flac/m4a/m4b/ogg/oga/opus/wav/aac; aiff/wma/wv/ape/mka go to `ffprobe` |
| `api.v`       | Native JSON API and media/artwork streaming                            |
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
| `PATCH /api/v1/items/:id`             | `library:write`   | any of `title artist album genre year track_no tags` |
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
app's Subsonic password. Supported: browsing (ID3 and folder style), album
lists (including highest rated), search, streaming, cover art, lyrics (plain
and synced), playlists, album ratings (`setRating` on an album id), scrobbling.
JSON and XML.

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
tracks, search, genres, streaming, cover art, lyrics, playlists, and reporting
listens. As in Jellyfin itself, cover images are served without sign-in while
the protocol is switched on. It has been exercised with scripted requests, not
yet with real client apps, and video libraries are not exposed.

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
250 artists), Navidrome 0.64.2 against Vlyra's optimised build.

| | Vlyra | Navidrome |
| --- | --- | --- |
| Binary | 3 MB | 66 MB |
| First scan | 0.9 s | about 7 s |
| Memory, idle after scan | 10 MB | 31 MB |
| Memory after the load test | 69 MB | 87 MB |

Subsonic requests, 3,000 each at 20 concurrent, no errors on either:

| Request | Vlyra req/s (p99) | Navidrome req/s (p99) |
| --- | --- | --- |
| ping | 21,018 (4 ms) | 4,382 (18 ms) |
| stream a 16 KB file | 18,006 (4 ms) | 3,587 (23 ms) |
| getArtists | 473 (131 ms) | 898 (37 ms) |
| album list, newest 50 | 289 (215 ms) | 2,430 (15 ms) |
| album list, random 50 | 283 (210 ms) | 993 (34 ms) |
| getAlbum | 875 (69 ms) | 2,312 (15 ms) |
| search "harbour" | 328 (186 ms) | 356 (102 ms) |
| 50 random songs | 696 (89 ms) | 623 (52 ms) |

Vlyra groups albums and artists from tags on every request, with no stored
album table or indexes, so Navidrome is faster on catalogue queries. Navidrome
also returns more fields per item. The first scan was re-measured after Vlyra
gained native tag readers (it was 211 s with one `ffprobe` per file); the other
rows are from the first build. The test files are 2-second generated tones, over
loopback, so streaming figures say nothing about large files.

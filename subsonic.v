module main

import crypto.md5
import encoding.base64
import encoding.hex
import net.urllib
import os
import time
import veb
import x.json2

type Obj = map[string]json2.Any

fn artist_id(artist string) string {
	return 'ar-' + base64.url_encode_str(artist)
}

fn album_id(artist string, album string) string {
	return 'al-' + base64.url_encode_str(artist + '\x1f' + album)
}

fn decode_id(id string) []string {
	return base64.url_decode_str(id.all_after('-')).split('\x1f')
}

fn or_unknown(s string, what string) string {
	return if s != '' { s } else { '[Unknown ${what}]' }
}

fn iso(unix i64) string {
	return time.unix(unix).format_rfc3339()
}

fn sub_secret_ok(secret string, p string, t string, s string) bool {
	// No Subsonic password means no Subsonic sign-in, whatever hash is sent.
	if secret == '' {
		return false
	}
	if t != '' {
		return md5.hexhash(secret + s) == t.to_lower()
	}
	if p.starts_with('enc:') {
		return (hex.decode(p[4..]) or { return false }).bytestr() == secret
	}
	return p != '' && p == secret
}

fn xml_escape(s string) string {
	return s.replace_each(['&', '&amp;', '<', '&lt;', '>', '&gt;', '"', '&quot;'])
}

fn to_xml(name string, v json2.Any) string {
	match v {
		[]json2.Any {
			return v.map(to_xml(name, it)).join('')
		}
		map[string]json2.Any {
			mut attrs := ''
			mut kids := ''
			for k, c in v {
				if c is map[string]json2.Any || c is []json2.Any {
					kids += to_xml(k, c)
				} else if k == 'value' {
					kids += xml_escape(c.str())
				} else {
					attrs += ' ${k}="${xml_escape(c.str())}"'
				}
			}
			return '<${name}${attrs}>${kids}</${name}>'
		}
		else {
			return '<${name}>${xml_escape(v.str())}</${name}>'
		}
	}
}

fn sub_reply(mut ctx Context, q urllib.Values, payload Obj) veb.Result {
	mut r := Obj(map[string]json2.Any{})
	r['status'] = if 'error' in payload { 'failed' } else { 'ok' }
	r['version'] = '1.16.1'
	r['type'] = 'vlyra'
	r['serverVersion'] = version
	r['openSubsonic'] = true
	for k, v in payload {
		r[k] = v
	}
	if (q.get('f') or { 'xml' }) == 'json' {
		mut env := map[string]json2.Any{}
		env['subsonic-response'] = json2.Any(map[string]json2.Any(r))
		return ctx.send_response_to_client('application/json', json2.Any(env).json_str())
	}
	r['xmlns'] = 'http://subsonic.org/restapi'
	return ctx.send_response_to_client('text/xml', '<?xml version="1.0" encoding="UTF-8"?>' +
		to_xml('subsonic-response', json2.Any(map[string]json2.Any(r))))
}

fn sub_error(mut ctx Context, q urllib.Values, code int, message string) veb.Result {
	mut e := map[string]json2.Any{}
	e['code'] = code
	e['message'] = message
	mut payload := Obj(map[string]json2.Any{})
	payload['error'] = e
	return sub_reply(mut ctx, q, payload)
}

fn song(it Item) json2.Any {
	ext := os.file_ext(it.path).to_lower()
	mut s := map[string]json2.Any{}
	s['id'] = it.id.str()
	s['parent'] = album_id(it.album_artist, it.album)
	s['isDir'] = false
	s['title'] = it.title
	s['album'] = or_unknown(it.album, 'Album')
	s['artist'] = or_unknown(it.artist, 'Artist')
	s['albumId'] = album_id(it.album_artist, it.album)
	s['artistId'] = artist_id(it.artist)
	s['track'] = it.track_no
	s['year'] = it.year
	s['genre'] = it.genre
	s['coverArt'] = it.id.str()
	s['size'] = it.size
	s['contentType'] = media_types[ext]
	s['suffix'] = ext.trim_left('.')
	s['duration'] = it.duration
	s['path'] = os.file_name(it.path)
	s['type'] = 'music'
	s['isVideo'] = false
	s['created'] = iso(it.added_at)
	return s
}

fn songs(items []Item) json2.Any {
	return json2.Any(items.map(song(it)))
}

fn (app &App) albums(rated bool, tail string, params []string) []json2.Any {
	mut out := []json2.Any{}
	for al in app.album_rows(tail, params) {
		mut a := map[string]json2.Any{}
		a['id'] = album_id(al.artist, al.name)
		a['parent'] = artist_id(al.artist)
		a['isDir'] = true
		a['name'] = or_unknown(al.name, 'Album')
		a['title'] = or_unknown(al.name, 'Album')
		a['album'] = or_unknown(al.name, 'Album')
		a['artist'] = or_unknown(al.artist, 'Artist')
		a['artistId'] = artist_id(al.artist)
		a['songCount'] = al.songs
		a['duration'] = al.duration
		a['year'] = al.year
		a['genre'] = al.genre
		a['coverArt'] = al.first_id.str()
		a['created'] = iso(al.added_at)
		if rated && al.rating > 0 {
			a['userRating'] = al.rating
		}
		out << a
	}
	return out
}

fn (app &App) artist_index() []json2.Any {
	rows := app.db.exec('select artist, count(distinct album), min(id) from items where ${audio} group by artist order by artist collate nocase') or {
		return []
	}
	mut letters := []string{}
	mut groups := map[string][]json2.Any{}
	for r in rows {
		name := or_unknown(r.vals[0], 'Artist')
		first := name[..1].to_upper()
		letter := if first[0].is_letter() { first } else { '#' }
		mut a := map[string]json2.Any{}
		a['id'] = artist_id(r.vals[0])
		a['name'] = name
		a['albumCount'] = r.vals[1].int()
		a['coverArt'] = r.vals[2]
		if letter !in groups {
			letters << letter
		}
		groups[letter] << a
	}
	mut out := []json2.Any{}
	for letter in letters {
		mut g := map[string]json2.Any{}
		g['name'] = letter
		g['artist'] = groups[letter]
		out << g
	}
	return out
}

fn (app &App) cover_item(id string) ?Item {
	if id.starts_with('al-') || id.starts_with('ar-') {
		parts := decode_id(id)
		found := if parts.len == 2 {
			app.items('where ${audio} and ${album_match} order by track_no limit 1', parts)
		} else {
			app.items('where ${audio} and artist = ? limit 1', parts)
		}
		return if found.len > 0 { found[0] } else { none }
	}
	return app.item(id.int())
}

fn sub_playlist(pl Playlist, items []Item, with_entries bool) json2.Any {
	mut total := 0
	for it in items {
		total += it.duration
	}
	mut o := map[string]json2.Any{}
	o['id'] = pl.id.str()
	o['name'] = pl.name
	o['owner'] = pl.owner
	o['public'] = true
	o['songCount'] = items.len
	o['duration'] = total
	o['created'] = iso(pl.created_at)
	o['changed'] = iso(pl.created_at)
	if with_entries {
		o['entry'] = songs(items)
	}
	return o
}

fn structured_lyrics(text string) json2.Any {
	mut lines := []json2.Any{}
	mut synced := false
	for raw in text.split_into_lines() {
		mut l := map[string]json2.Any{}
		stamp := raw.find_between('[', ']').split(':')
		if raw.starts_with('[') && stamp.len == 2 {
			if stamp[0] == '' || !stamp[0][0].is_digit() {
				continue
			}
			l['start'] = int((stamp[0].f64() * 60 + stamp[1].f64()) * 1000)
			l['value'] = raw.all_after(']').trim_space()
			synced = true
		} else {
			l['value'] = raw
		}
		lines << l
	}
	mut o := map[string]json2.Any{}
	o['lang'] = 'und'
	o['synced'] = synced
	o['line'] = lines
	return o
}

const sub_tag_fields = {
	'title':       'title'
	'artist':      'artist'
	'albumArtist': 'album_artist'
	'album':       'album'
	'genre':       'genre'
	'year':        'year'
	'track':       'track_no'
}

fn int_param(q urllib.Values, key string, default int, max int) int {
	n := (q.get(key) or { return default }).int()
	return if n < 0 {
		0
	} else if n > max {
		max
	} else {
		n
	}
}

@['/rest/:endpoint'; get; post]
pub fn (mut app App) subsonic(mut ctx Context, endpoint string) veb.Result {
	if !app.protocol_on('subsonic') {
		return ctx.not_found()
	}
	mut raw := if ctx.req.url.contains('?') { ctx.req.url.all_after('?') } else { '' }
	method := endpoint.trim_string_right('.view')
	if ctx.req.method == .post && method != 'vlyraSetCoverArt' {
		raw += '&' + ctx.req.data
	}
	q := urllib.parse_query(raw) or { urllib.new_values() }

	user := q.get('u') or { '' }
	apps := sql app.db {
		select from ClientApp where name == user && enabled == true
	} or { []ClientApp{} }
	if apps.len == 0 || !sub_secret_ok(apps[0].subsonic_password, q.get('p') or { '' }, q.get('t') or {
		''
	}, q.get('s') or { '' }) {
		return sub_error(mut ctx, q, 40, 'Wrong username or password.')
	}
	p := app.principal_for(apps[0])

	need := match method {
		'ping', 'getLicense', 'getUser', 'getOpenSubsonicExtensions' { '' }
		'getLyrics', 'getLyricsBySongId' { 'lyrics:read' }
		'getCoverArt' { 'artwork:read' }
		'getPlaylists', 'getPlaylist' { 'playlists:read' }
		'createPlaylist', 'updatePlaylist', 'deletePlaylist' { 'playlists:write' }
		'scrobble' { 'history:write' }
		'setRating' { 'ratings:write' }
		'vlyraGetTags' { 'library:read' }
		'vlyraSetTags' { '' }
		'vlyraSetCoverArt' { 'artwork:write' }
		else { 'library:read' }
	}

	if need != '' && !p.can(need) {
		return sub_error(mut ctx, q, 50, '"${p.name}" has not been granted ${need} in Vlyra.')
	}

	id := q.get('id') or { '' }
	rated := p.can('ratings:read')
	mut out := Obj(map[string]json2.Any{})
	match method {
		'ping' {}
		'getLicense' {
			mut l := map[string]json2.Any{}
			l['valid'] = true
			out['license'] = l
		}
		'getOpenSubsonicExtensions' {
			mut e := map[string]json2.Any{}
			e['name'] = 'songLyrics'
			e['versions'] = [json2.Any(1)]
			mut t := map[string]json2.Any{}
			t['name'] = 'vlyraTags'
			t['versions'] = [json2.Any(1)]
			out['openSubsonicExtensions'] = [json2.Any(e), t]
		}
		'getUser' {
			mut u := map[string]json2.Any{}
			u['username'] = p.name
			u['adminRole'] = false
			u['streamRole'] = p.can('library:read')
			u['downloadRole'] = p.can('library:read')
			u['coverArtRole'] = p.can('artwork:read')
			u['playlistRole'] = p.can('playlists:write')
			u['scrobblingEnabled'] = p.can('history:write')
			u['commentRole'] = p.can('ratings:write')
			out['user'] = u
		}
		'getMusicFolders' {
			mut f := map[string]json2.Any{}
			f['id'] = 1
			f['name'] = 'Library'
			mut m := map[string]json2.Any{}
			m['musicFolder'] = [json2.Any(f)]
			out['musicFolders'] = m
		}
		'getScanStatus' {
			mut s := map[string]json2.Any{}
			s['scanning'] = app.scanning
			s['count'] = app.db.q_int('select count(*) from items where ${audio}') or { 0 }
			out['scanStatus'] = s
		}
		'getArtists', 'getIndexes' {
			mut a := map[string]json2.Any{}
			a['ignoredArticles'] = ''
			a['index'] = app.artist_index()

			out[if method == 'getArtists' {
				'artists'
			} else {
				'indexes'
			}] = a
		}
		'getArtist', 'getMusicDirectory' {
			parts := decode_id(id)
			if id.starts_with('ar-') {
				found := app.albums(rated,
					'and artist = ? group by ${album_group} order by max(year), album collate nocase',
					parts)
				mut a := map[string]json2.Any{}
				a['id'] = id
				a['name'] = or_unknown(parts[0], 'Artist')
				a['albumCount'] = found.len

				a[if method == 'getArtist' {
					'album'
				} else {
					'child'
				}] = found

				out[if method == 'getArtist' {
					'artist'
				} else {
					'directory'
				}] = a
			} else if id.starts_with('al-') && parts.len == 2 && method == 'getMusicDirectory' {
				mut d := map[string]json2.Any{}
				d['id'] = id
				d['parent'] = artist_id(parts[0])
				d['name'] = or_unknown(parts[1], 'Album')
				d['child'] = songs(app.items('where ${audio} and ${album_match} order by track_no, title',
					parts))
				out['directory'] = d
			} else {
				return sub_error(mut ctx, q, 70, 'Not found.')
			}
		}
		'getAlbum' {
			parts := decode_id(id)
			found := if parts.len == 2 {
				app.albums(rated, 'and ${album_match} group by ${album_group}', parts)
			} else {
				[]json2.Any{}
			}
			if found.len == 0 {
				return sub_error(mut ctx, q, 70, 'Album not found.')
			}
			mut a := found[0].as_map()
			a['song'] = songs(app.items('where ${audio} and ${album_match} order by track_no, title',
				parts))
			out['album'] = a
		}
		'getAlbumList', 'getAlbumList2' {
			kind := q.get('type') or { 'alphabeticalByName' }
			mut filter := ''
			mut params := []string{}
			if kind == 'byGenre' {
				filter = 'and genre = ?'
				params << q.get('genre') or { '' }
			}
			order := match kind {
				'random' { 'random()' }
				'newest', 'recent', 'frequent' { 'max(added_at) desc' }
				'alphabeticalByArtist' { 'album_artist collate nocase, album collate nocase' }
				'byYear' { 'max(year), album collate nocase' }
				'highest' { 'rating desc, album collate nocase' }
				else { 'album collate nocase' }
			}

			having := if kind == 'highest' { 'having rating > 0' } else { '' }

			params << int_param(q, 'size', 10, 500).str()
			params << int_param(q, 'offset', 0, max_int).str()
			mut l := map[string]json2.Any{}
			l['album'] = if kind == 'starred' || (kind == 'highest' && !rated) {
				[]json2.Any{}
			} else {
				app.albums(rated,
					'${filter} group by ${album_group} ${having} order by ${order} limit ? offset ?',
					params)
			}

			out[if method == 'getAlbumList' {
				'albumList'
			} else {
				'albumList2'
			}] = l
		}
		'getGenres' {
			rows := app.db.exec("select genre, count(*), count(distinct album_artist || char(31) || album) from items where ${audio} and genre != '' group by genre order by genre collate nocase") or {
				[]
			}
			mut list := []json2.Any{}
			for r in rows {
				mut g := map[string]json2.Any{}
				g['value'] = r.vals[0]
				g['songCount'] = r.vals[1].int()
				g['albumCount'] = r.vals[2].int()
				list << g
			}
			mut g := map[string]json2.Any{}
			g['genre'] = list
			out['genres'] = g
		}
		'getSong' {
			it := app.item(id.int()) or { return sub_error(mut ctx, q, 70, 'Song not found.') }
			out['song'] = song(it)
		}
		'getRandomSongs' {
			mut r := map[string]json2.Any{}
			r['song'] = songs(app.items('where ${audio} order by random() limit ?', [
				int_param(q, 'size', 10, 500).str(),
			]))
			out['randomSongs'] = r
		}
		'getStarred', 'getStarred2' {
			out[if method == 'getStarred' {
				'starred'
			} else {
				'starred2'
			}] = map[string]json2.Any{}
		}
		'search2', 'search3' {
			pattern := '%' + (q.get('query') or { '' }).trim('"') + '%'
			mut r := map[string]json2.Any{}
			r['song'] = songs(app.items('where ${audio} and (title like ?1 or artist like ?1 or album like ?1) order by artist collate nocase, album collate nocase, track_no limit ?2 offset ?3', [
				pattern,
				int_param(q, 'songCount', 20, 500).str(),
				int_param(q, 'songOffset', 0, max_int).str(),
			]))
			r['album'] = app.albums(rated,
				'and (album like ?1 or album_artist like ?1) group by ${album_group} order by album collate nocase limit ?2 offset ?3', [
				pattern,
				int_param(q, 'albumCount', 20, 500).str(),
				int_param(q, 'albumOffset', 0, max_int).str(),
			])
			artist_rows := app.db.exec_param_many('select artist, count(distinct album), min(id) from items where ${audio} and artist like ?1 group by artist order by artist collate nocase limit ?2 offset ?3', [
				pattern,
				int_param(q, 'artistCount', 20, 500).str(),
				int_param(q, 'artistOffset', 0, max_int).str(),
			]) or { [] }
			mut artists := []json2.Any{}
			for row in artist_rows {
				mut a := map[string]json2.Any{}
				a['id'] = artist_id(row.vals[0])
				a['name'] = or_unknown(row.vals[0], 'Artist')
				a['albumCount'] = row.vals[1].int()
				a['coverArt'] = row.vals[2]
				artists << a
			}
			r['artist'] = artists

			out[if method == 'search2' {
				'searchResult2'
			} else {
				'searchResult3'
			}] = r
		}
		'stream', 'download' {
			it := app.item(id.int()) or { return sub_error(mut ctx, q, 70, 'Song not found.') }
			return serve_media(mut ctx, it.path)
		}
		'getCoverArt' {
			it := app.cover_item(id) or { return sub_error(mut ctx, q, 70, 'Not found.') }
			return send_artwork(mut ctx, app, it, int_param(q, 'size', 0, max_int))
		}
		'getLyrics' {
			found := app.items('where ${audio} and artist like ? and title like ? limit 1', [
				q.get('artist') or { '' },
				q.get('title') or { '' },
			])
			mut l := map[string]json2.Any{}
			if found.len > 0 {
				l['artist'] = found[0].artist
				l['title'] = found[0].title
				l['value'] = app.lyrics(found[0].id)
			}
			out['lyrics'] = l
		}
		'getLyricsBySongId' {
			text := app.lyrics(id.int())
			mut l := map[string]json2.Any{}
			l['structuredLyrics'] = if text != '' {
				[structured_lyrics(text)]
			} else {
				[]json2.Any{}
			}
			out['lyricsList'] = l
		}
		'getPlaylists' {
			found := sql app.db {
				select from Playlist order by name
			} or { []Playlist{} }
			mut l := map[string]json2.Any{}
			l['playlist'] = found.map(sub_playlist(it, app.playlist_items(it.id), false))
			out['playlists'] = l
		}
		'getPlaylist' {
			pl := app.playlist(id.int()) or {
				return sub_error(mut ctx, q, 70, 'Playlist not found.')
			}
			out['playlist'] = sub_playlist(pl, app.playlist_items(pl.id), true)
		}
		'createPlaylist' {
			pid := app.save_playlist(p, (q.get('playlistId') or { '0' }).int(), q.get('name') or {
				''
			}, q.get_all('songId').map(it.int())) or { return sub_error(mut ctx, q, 10, err.msg()) }
			pl := app.playlist(pid) or { return sub_error(mut ctx, q, 70, 'Playlist not found.') }
			out['playlist'] = sub_playlist(pl, app.playlist_items(pid), true)
		}
		'updatePlaylist' {
			pid := (q.get('playlistId') or { '0' }).int()
			remove := q.get_all('songIndexToRemove').map(it.int())
			mut ids := []int{}
			for i, it in app.playlist_items(pid) {
				if i !in remove {
					ids << it.id
				}
			}
			ids << q.get_all('songIdToAdd').map(it.int())
			app.save_playlist(p, pid, q.get('name') or { '' }, ids) or {
				return sub_error(mut ctx, q, 70, err.msg())
			}
		}
		'deletePlaylist' {
			app.delete_playlist(p, id.int()) or { return sub_error(mut ctx, q, 70, err.msg()) }
		}
		'scrobble' {
			if (q.get('submission') or { 'true' }) != 'false' {
				at := (q.get('time') or { '0' }).i64() / 1000
				for song_id in q.get_all('id') {
					app.record_play(p, song_id.int(), at) or {
						return sub_error(mut ctx, q, 70, err.msg())
					}
				}
			}
		}
		'vlyraGetTags' {
			it := app.item(id.int()) or { return sub_error(mut ctx, q, 70, 'Song not found.') }
			mut t := map[string]json2.Any{}
			t['id'] = it.id.str()
			t['title'] = it.title
			t['artist'] = it.artist
			t['albumArtist'] = it.album_artist
			t['album'] = it.album
			t['genre'] = it.genre
			t['year'] = it.year
			t['track'] = it.track_no
			if p.can('lyrics:read') {
				t['lyrics'] = app.lyrics(it.id)
			}
			out['vlyraTags'] = t
		}
		'vlyraSetTags' {
			it := app.item(id.int()) or { return sub_error(mut ctx, q, 70, 'Song not found.') }
			mut fields := map[string]string{}
			for param, field in sub_tag_fields {
				if v := q.get(param) {
					fields[field] = v
				}
			}
			has_lyrics := q.get_all('lyrics').len > 0
			lyrics := q.get('lyrics') or { '' }
			// Every permission first, so a refused edit changes nothing.
			mut needs := []string{}
			if fields.len > 0 {
				needs << 'library:write'
			}
			if has_lyrics {
				needs << 'lyrics:write'
			}
			for scope in needs {
				if !p.can(scope) {
					return sub_error(mut ctx, q, 50,
						'"${p.name}" has not been granted ${scope} in Vlyra.')
				}
			}
			for field, v in fields {
				app.set_item_field(p, it.id, field, v) or {
					return sub_error(mut ctx, q, 10, err.msg())
				}
			}
			if has_lyrics {
				app.set_lyrics(p, it.id, lyrics) or { return sub_error(mut ctx, q, 10, err.msg()) }
			}
		}
		'vlyraSetCoverArt' {
			app.set_artwork(p, id.int(), ctx.req.data) or {
				return sub_error(mut ctx, q, if err.msg() == 'no such item' { 70 } else { 10 },
					err.msg())
			}
		}
		'setRating' {
			parts := decode_id(id)
			if !id.starts_with('al-') || parts.len != 2 {
				return sub_error(mut ctx, q, 0, 'Vlyra rates albums, not songs or artists.')
			}
			app.rate_album(p, parts[0], parts[1], (q.get('rating') or { '-1' }).int()) or {
				return sub_error(mut ctx, q, if err.msg() == 'no such album' { 70 } else { 10 },
					err.msg())
			}
		}
		else {
			return sub_error(mut ctx, q, 0, '${method} is not supported by Vlyra.')
		}
	}

	return sub_reply(mut ctx, q, out)
}

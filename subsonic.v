module main

import crypto.md5
import crypto.sha256
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
		return send_json(mut ctx, json2.Any(env).json_str())
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

const sub_index_letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ#'

fn sub_write_open(mut j JsonBuf, key string) {
	j.raw('{"subsonic-response":{"status":"ok","version":"1.16.1","type":"vlyra","serverVersion":"')
	j.raw(version)
	j.raw('","openSubsonic":true,"')
	j.raw(key)
	j.raw('":')
}

fn sub_write_song_ex(mut j JsonBuf, it &Item, starred_at i64) {
	ext := os.file_ext(it.path).to_lower()
	al_id := album_id(it.album_artist, it.album)
	j.raw('{"id":"')
	j.jint(it.id)
	j.raw('","parent":')
	j.jstr(al_id)
	j.raw(',"isDir":false,"title":')
	j.jstr(it.title)
	j.raw(',"album":')
	j.jstr(or_unknown(it.album, 'Album'))
	j.raw(',"artist":')
	j.jstr(or_unknown(it.artist, 'Artist'))
	j.raw(',"albumId":')
	j.jstr(al_id)
	j.raw(',"artistId":')
	j.jstr(artist_id(it.artist))
	j.raw(',"track":')
	j.jint(it.track_no)
	if it.disc_no > 0 {
		j.raw(',"discNumber":')
		j.jint(it.disc_no)
	}
	j.raw(',"year":')
	j.jint(it.year)
	j.raw(',"genre":')
	j.jstr(it.genre)
	j.raw(',"coverArt":"')
	j.jint(it.id)
	j.raw('","size":')
	j.jint(it.size)
	j.raw(',"contentType":')
	j.jstr(media_types[ext])
	j.raw(',"suffix":')
	j.jstr(ext.trim_left('.'))
	j.raw(',"duration":')
	j.jint(it.duration)
	if it.bitrate > 0 {
		j.raw(',"bitRate":')
		j.jint(it.bitrate)
	}
	if it.sample_rate > 0 {
		j.raw(',"samplingRate":')
		j.jint(it.sample_rate)
	}
	if it.bit_depth > 0 {
		j.raw(',"bitDepth":')
		j.jint(it.bit_depth)
	}
	if it.channels > 0 {
		j.raw(',"channelCount":')
		j.jint(it.channels)
	}
	j.raw(',"path":')
	j.jstr(os.file_name(it.path))
	j.raw(',"type":"music","isVideo":false,"created":')
	j.jstr(iso(it.added_at))
	if it.play_count > 0 {
		j.raw(',"playCount":')
		j.jint(it.play_count)
	}
	if it.last_played > 0 {
		j.raw(',"played":')
		j.jstr(iso(it.last_played))
	}
	if starred_at > 0 {
		j.raw(',"starred":')
		j.jstr(iso(starred_at))
	}
	if it.rg_track_gain != 0 || it.rg_album_gain != 0 || it.rg_track_peak != 0
		|| it.rg_album_peak != 0 {
		j.raw(',"replayGain":{"trackGain":')
		j.jf64(it.rg_track_gain)
		j.raw(',"albumGain":')
		j.jf64(it.rg_album_gain)
		j.raw(',"trackPeak":')
		j.jf64(it.rg_track_peak)
		j.raw(',"albumPeak":')
		j.jf64(it.rg_album_peak)
		j.byte(`}`)
	}
	j.byte(`}`)
}

fn sub_write_song(mut j JsonBuf, it &Item) {
	sub_write_song_ex(mut j, it, 0)
}

fn sub_write_album_fields(mut j JsonBuf, al &Album, rated bool) {
	ar_id := artist_id(al.artist)
	al_name := or_unknown(al.name, 'Album')
	j.raw('{"id":')
	j.jstr(album_id(al.artist, al.name))
	j.raw(',"parent":')
	j.jstr(ar_id)
	j.raw(',"isDir":true,"name":')
	j.jstr(al_name)
	j.raw(',"title":')
	j.jstr(al_name)
	j.raw(',"album":')
	j.jstr(al_name)
	j.raw(',"artist":')
	j.jstr(or_unknown(al.artist, 'Artist'))
	j.raw(',"artistId":')
	j.jstr(ar_id)
	j.raw(',"songCount":')
	j.jint(al.songs)
	j.raw(',"duration":')
	j.jint(al.duration)
	j.raw(',"year":')
	j.jint(al.year)
	j.raw(',"genre":')
	j.jstr(al.genre)
	j.raw(',"coverArt":"')
	j.jint(al.first_id)
	j.raw('","created":')
	j.jstr(iso(al.added_at))
	if rated && al.rating > 0 {
		j.raw(',"userRating":')
		j.jint(al.rating)
	}
	if al.play_count > 0 {
		j.raw(',"playCount":')
		j.jint(al.play_count)
	}
	if al.last_played > 0 {
		j.raw(',"played":')
		j.jstr(iso(al.last_played))
	}
}

fn sub_write_artist(mut j JsonBuf, r &ArtistRow) {
	j.raw('{"id":')
	j.jstr(artist_id(r.name))
	j.raw(',"name":')
	j.jstr(or_unknown(r.name, 'Artist'))
	j.raw(',"albumCount":')
	j.jint(r.albums)
	j.raw(',"coverArt":"')
	j.jint(r.first_id)
	j.raw('"}')
}

fn encode_sub_artists_json(rows &[]ArtistRow, is_artists bool) string {
	mut buckets := [27][]int{}
	mut order := []int{cap: 27}
	for i := 0; i < rows.len; i++ {
		r := unsafe { &(*rows)[i] }
		name := or_unknown(r.name, 'Artist')
		c := name[0]
		b := if c >= `A` && c <= `Z` {
			int(c - `A`)
		} else if c >= `a` && c <= `z` {
			int(c - `a`)
		} else {
			26
		}
		if buckets[b].len == 0 {
			order << b
		}
		buckets[b] << i
	}
	mut j := new_jbuf(rows.len * 84 + 1024)
	sub_write_open(mut j, if is_artists { 'artists' } else { 'indexes' })
	j.raw('{"ignoredArticles":"","index":[')
	for oi, b in order {
		if oi > 0 {
			j.byte(`,`)
		}
		j.raw('{"name":"')
		j.byte(sub_index_letters[b])
		j.raw('","artist":[')
		for k := 0; k < buckets[b].len; k++ {
			if k > 0 {
				j.byte(`,`)
			}
			ri := buckets[b][k]
			r := unsafe { &(*rows)[ri] }
			sub_write_artist(mut j, r)
		}
		j.raw(']}')
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_album_list_json(list &[]Album, rated bool, is_v1 bool) string {
	mut j := new_jbuf(list.len * 380 + 256)
	sub_write_open(mut j, if is_v1 { 'albumList' } else { 'albumList2' })
	j.raw('{"album":[')
	for i := 0; i < list.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		al := unsafe { &(*list)[i] }
		sub_write_album_fields(mut j, al, rated)
		j.byte(`}`)
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_album_detail_json(al &Album, tracks &[]Item, rated bool) string {
	mut j := new_jbuf(tracks.len * 420 + 512)
	sub_write_open(mut j, 'album')
	sub_write_album_fields(mut j, al, rated)
	j.raw(',"song":[')
	for i := 0; i < tracks.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		it := unsafe { &(*tracks)[i] }
		sub_write_song(mut j, it)
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_genres_json(rows &[]GenreRow) string {
	mut j := new_jbuf(rows.len * 64 + 192)
	sub_write_open(mut j, 'genres')
	j.raw('{"genre":[')
	for i := 0; i < rows.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		gr := unsafe { &(*rows)[i] }
		j.raw('{"value":')
		j.jstr(gr.name)
		j.raw(',"songCount":')
		j.jint(gr.songs)
		j.raw(',"albumCount":')
		j.jint(gr.albums)
		j.byte(`}`)
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_random_songs_json(items &[]Item) string {
	mut j := new_jbuf(items.len * 420 + 256)
	sub_write_open(mut j, 'randomSongs')
	j.raw('{"song":[')
	for i := 0; i < items.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		it := unsafe { &(*items)[i] }
		sub_write_song(mut j, it)
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_playlists_json(sums &[]PlaylistSummary) string {
	mut j := new_jbuf(sums.len * 160 + 256)
	sub_write_open(mut j, 'playlists')
	j.raw('{"playlist":[')
	for i := 0; i < sums.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		ps := unsafe { &(*sums)[i] }
		ts := iso(ps.created_at)
		j.raw('{"id":"')
		j.jint(ps.id)
		j.raw('","name":')
		j.jstr(ps.name)
		j.raw(',"owner":')
		j.jstr(ps.owner)
		j.raw(',"public":true,"songCount":')
		j.jint(ps.songs)
		j.raw(',"duration":')
		j.jint(ps.duration)
		j.raw(',"created":')
		j.jstr(ts)
		j.raw(',"changed":')
		j.jstr(ts)
		j.byte(`}`)
	}
	j.raw(']}}}')
	return j.finish()
}

fn encode_sub_search_json(song_rows &[]Item, album_rows &[]Album, artist_rows &[]ArtistRow, rated bool, is_v2 bool) string {
	mut j := new_jbuf(song_rows.len * 420 + album_rows.len * 380 + artist_rows.len * 84 + 256)
	sub_write_open(mut j, if is_v2 { 'searchResult2' } else { 'searchResult3' })
	j.raw('{"song":[')
	for i := 0; i < song_rows.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		it := unsafe { &(*song_rows)[i] }
		sub_write_song(mut j, it)
	}
	j.raw('],"album":[')
	for i := 0; i < album_rows.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		al := unsafe { &(*album_rows)[i] }
		sub_write_album_fields(mut j, al, rated)
		j.byte(`}`)
	}
	j.raw('],"artist":[')
	for i := 0; i < artist_rows.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		r := unsafe { &(*artist_rows)[i] }
		sub_write_artist(mut j, r)
	}
	j.raw(']}}}')
	return j.finish()
}

fn (app &App) sub_album_list(rated bool, q urllib.Values) []Album {
	kind := q.get('type') or { 'alphabeticalByName' }
	size := int_param(q, 'size', 10, 500)
	offset := int_param(q, 'offset', 0, max_int)
	return match kind {
		'starred' {
			app.starred_albums(rated, size, offset)
		}
		'highest' {
			if !rated || !app.has_ratings() {
				[]Album{}
			} else {
				app.albums_mat(rated, 'where rating > 0 order by rating desc, album collate nocase limit ? offset ?', [
					size.str(),
					offset.str(),
				])
			}
		}
		'random' {
			app.random_albums(rated, size)
		}
		'newest' {
			app.albums_mat(rated, 'order by added_at desc, album collate nocase limit ? offset ?', [
				size.str(),
				offset.str(),
			])
		}
		'frequent' {
			app.albums_mat(rated, 'where play_count > 0 order by play_count desc, album collate nocase limit ? offset ?', [
				size.str(),
				offset.str(),
			])
		}
		'recent' {
			app.albums_mat(rated, 'where last_played > 0 order by last_played desc, album collate nocase limit ? offset ?', [
				size.str(),
				offset.str(),
			])
		}
		'alphabeticalByArtist' {
			app.albums_mat(rated, 'order by album_artist collate nocase, album collate nocase limit ? offset ?', [
				size.str(),
				offset.str(),
			])
		}
		'byGenre' {
			app.albums_mat(rated, 'where genre = ? order by album collate nocase limit ? offset ?', [
				q.get('genre') or { '' },
				size.str(),
				offset.str(),
			])
		}
		'byYear' {
			app.albums_by_year(rated, q, size, offset)
		}
		else {
			app.albums_mat(rated, 'order by album collate nocase limit ? offset ?', [
				size.str(),
				offset.str(),
			])
		}
	}
}

fn song_ex(it Item, starred_at i64) json2.Any {
	ext := os.file_ext(it.path).to_lower()
	id_str := it.id.str()
	al_id := album_id(it.album_artist, it.album)
	mut s := map[string]json2.Any{}
	s['id'] = id_str
	s['parent'] = al_id
	s['isDir'] = false
	s['title'] = it.title
	s['album'] = or_unknown(it.album, 'Album')
	s['artist'] = or_unknown(it.artist, 'Artist')
	s['albumId'] = al_id
	s['artistId'] = artist_id(it.artist)
	s['track'] = it.track_no
	if it.disc_no > 0 {
		s['discNumber'] = it.disc_no
	}
	s['year'] = it.year
	s['genre'] = it.genre
	s['coverArt'] = id_str
	s['size'] = it.size
	s['contentType'] = media_types[ext]
	s['suffix'] = ext.trim_left('.')
	s['duration'] = it.duration
	if it.bitrate > 0 {
		s['bitRate'] = it.bitrate
	}
	if it.sample_rate > 0 {
		s['samplingRate'] = it.sample_rate
	}
	if it.bit_depth > 0 {
		s['bitDepth'] = it.bit_depth
	}
	if it.channels > 0 {
		s['channelCount'] = it.channels
	}
	s['path'] = os.file_name(it.path)
	s['type'] = 'music'
	s['isVideo'] = false
	s['created'] = iso(it.added_at)
	if it.play_count > 0 {
		s['playCount'] = it.play_count
	}
	if it.last_played > 0 {
		s['played'] = iso(it.last_played)
	}
	if starred_at > 0 {
		s['starred'] = iso(starred_at)
	}
	if it.rg_track_gain != 0 || it.rg_album_gain != 0 || it.rg_track_peak != 0
		|| it.rg_album_peak != 0 {
		mut rg := map[string]json2.Any{}
		rg['trackGain'] = it.rg_track_gain
		rg['albumGain'] = it.rg_album_gain
		rg['trackPeak'] = it.rg_track_peak
		rg['albumPeak'] = it.rg_album_peak
		s['replayGain'] = rg
	}
	return s
}

fn song(it Item) json2.Any {
	return song_ex(it, 0)
}

fn songs(items []Item) json2.Any {
	return json2.Any(items.map(song(it)))
}

fn sub_album_ex(rated bool, al Album, starred_at i64) json2.Any {
	al_id := album_id(al.artist, al.name)
	ar_id := artist_id(al.artist)
	al_name := or_unknown(al.name, 'Album')
	ar_name := or_unknown(al.artist, 'Artist')
	mut a := map[string]json2.Any{}
	a['id'] = al_id
	a['parent'] = ar_id
	a['isDir'] = true
	a['name'] = al_name
	a['title'] = al_name
	a['album'] = al_name
	a['artist'] = ar_name
	a['artistId'] = ar_id
	a['songCount'] = al.songs
	a['duration'] = al.duration
	a['year'] = al.year
	a['genre'] = al.genre
	a['coverArt'] = al.first_id.str()
	a['created'] = iso(al.added_at)
	if rated && al.rating > 0 {
		a['userRating'] = al.rating
	}
	if al.play_count > 0 {
		a['playCount'] = al.play_count
	}
	if al.last_played > 0 {
		a['played'] = iso(al.last_played)
	}
	if starred_at > 0 {
		a['starred'] = iso(starred_at)
	}
	return a
}

fn sub_album(rated bool, al Album) json2.Any {
	return sub_album_ex(rated, al, 0)
}

fn albums_json(rated bool, list []Album) []json2.Any {
	return list.map(sub_album(rated, it))
}

fn (app &App) albums_by_year(rated bool, q urllib.Values, size int, offset int) []Album {
	has_from := (q.get('fromYear') or { '' }) != ''
	has_to := (q.get('toYear') or { '' }) != ''
	if has_from || has_to {
		fy := (q.get('fromYear') or { '0' }).int()
		ty := (q.get('toYear') or { '9999' }).int()
		if fy <= ty {
			return app.albums_mat(rated, 'where year >= ? and year <= ? order by year asc, album collate nocase limit ? offset ?', [
				fy.str(),
				ty.str(),
				size.str(),
				offset.str(),
			])
		}
		return app.albums_mat(rated, 'where year >= ? and year <= ? order by year desc, album collate nocase limit ? offset ?', [
			ty.str(),
			fy.str(),
			size.str(),
			offset.str(),
		])
	}
	return app.albums_mat(rated, 'order by year, album collate nocase limit ? offset ?', [
		size.str(),
		offset.str(),
	])
}

fn (app &App) artist_index() []json2.Any {
	rows := app.artists_mat('artist', 'order by name collate nocase', [])
	mut letters := []string{}
	mut groups := map[string][]json2.Any{}
	for r in rows {
		name := or_unknown(r.name, 'Artist')
		first := name[..1].to_upper()
		letter := if first[0].is_letter() { first } else { '#' }
		mut a := map[string]json2.Any{}
		a['id'] = artist_id(r.name)
		a['name'] = name
		a['albumCount'] = r.albums
		a['coverArt'] = r.first_id.str()
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

fn sub_playlist_summary(ps PlaylistSummary) json2.Any {
	mut o := map[string]json2.Any{}
	o['id'] = ps.id.str()
	o['name'] = ps.name
	o['owner'] = ps.owner
	o['public'] = true
	o['songCount'] = ps.songs
	o['duration'] = ps.duration
	o['created'] = iso(ps.created_at)
	o['changed'] = iso(ps.created_at)
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
	'discNumber':  'disc_no'
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

	api_key := q.get('apiKey') or { '' }
	mut client := ClientApp{}
	if api_key != '' {
		client = app.cached_app_by_token(sha256.hexhash(api_key)) or {
			return sub_error(mut ctx, q, 44, 'Invalid API key.')
		}
	} else {
		user := q.get('u') or { '' }
		client = app.cached_app_by_name(user) or {
			return sub_error(mut ctx, q, 40, 'Wrong username or password.')
		}
		if !sub_secret_ok(client.subsonic_password, q.get('p') or { '' }, q.get('t') or { '' },
			q.get('s') or { '' }) {
			return sub_error(mut ctx, q, 40, 'Wrong username or password.')
		}
	}
	p := app.principal_for(client)

	need := match method {
		'ping', 'getLicense', 'getUser', 'getOpenSubsonicExtensions' { '' }
		'getLyrics', 'getLyricsBySongId' { 'lyrics:read' }
		'getCoverArt' { 'artwork:read' }
		'getPlaylists', 'getPlaylist' { 'playlists:read' }
		'createPlaylist', 'updatePlaylist', 'deletePlaylist' { 'playlists:write' }
		'scrobble', 'savePlayQueue' { 'history:write' }
		'setRating', 'star', 'unstar' { 'ratings:write' }
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
	is_json := (q.get('f') or { 'xml' }) == 'json'
	mut out := Obj(map[string]json2.Any{})
	match method {
		'ping' {
			if is_json {
				return ctx.send_response_to_client('application/json',
					'{"subsonic-response":{"status":"ok","version":"1.16.1","type":"vlyra","serverVersion":"${version}","openSubsonic":true}}')
			}
		}
		'getLicense' {
			mut l := map[string]json2.Any{}
			l['valid'] = true
			out['license'] = l
		}
		'getOpenSubsonicExtensions' {
			mut f := map[string]json2.Any{}
			f['name'] = 'formPost'
			f['versions'] = [json2.Any(1)]
			mut ak := map[string]json2.Any{}
			ak['name'] = 'apiKeyAuthentication'
			ak['versions'] = [json2.Any(1)]
			mut e := map[string]json2.Any{}
			e['name'] = 'songLyrics'
			e['versions'] = [json2.Any(1)]
			mut t := map[string]json2.Any{}
			t['name'] = 'vlyraTags'
			t['versions'] = [json2.Any(1)]
			out['openSubsonicExtensions'] = [json2.Any(f), ak, e, t]
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
			s['count'] = app.reader().q_int('select count(*) from items where ${audio}') or { 0 }
			out['scanStatus'] = s
		}
		'getArtists', 'getIndexes' {
			if is_json {
				tag := '"v${app.catalog_version()}-${method}"'
				if etag_matches(ctx, tag) {
					return not_modified(mut ctx, tag, 'private, no-cache')
				}
				rows := app.artists_mat('artist', 'order by name collate nocase', [])
				ctx.set_header(.etag, tag)
				ctx.set_header(.cache_control, 'private, no-cache')
				return send_json(mut ctx, encode_sub_artists_json(&rows, method == 'getArtists'))
			}
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
				found := albums_json(rated, app.albums_mat(rated,
					"where album_artist = ?1 or exists (select 1 from items i where i.missing = 0 and i.kind = 'audio' and i.artist = ?1 and i.album_artist = albums.album_artist and i.album = albums.album) order by year, album collate nocase",
					parts))
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
				d['child'] = songs(app.items('where ${audio} and ${album_match} order by disc_no, track_no, title',
					parts))
				out['directory'] = d
			} else {
				return sub_error(mut ctx, q, 70, 'Not found.')
			}
		}
		'getAlbum' {
			parts := decode_id(id)
			rows := if parts.len == 2 {
				app.albums_mat(rated, 'where ${album_match} limit 1', parts)
			} else {
				[]Album{}
			}
			if rows.len == 0 {
				return sub_error(mut ctx, q, 70, 'Album not found.')
			}
			tracks := app.items('where ${audio} and ${album_match} order by disc_no, track_no, title',
				parts)
			if is_json {
				al := unsafe { &rows[0] }
				return send_json(mut ctx, encode_sub_album_detail_json(al, &tracks, rated))
			}
			mut a := sub_album(rated, rows[0]).as_map()
			a['song'] = songs(tracks)
			out['album'] = a
		}
		'getAlbumList', 'getAlbumList2' {
			list := app.sub_album_list(rated, q)
			if is_json {
				return send_json(mut ctx, encode_sub_album_list_json(&list, rated,
					method == 'getAlbumList'))
			}

			mut l := map[string]json2.Any{}
			l['album'] = albums_json(rated, list)

			out[if method == 'getAlbumList' {
				'albumList'
			} else {
				'albumList2'
			}] = l
		}
		'getGenres' {
			if is_json {
				tag := '"v${app.catalog_version()}-genres"'
				if etag_matches(ctx, tag) {
					return not_modified(mut ctx, tag, 'private, no-cache')
				}
				rows := app.genres_mat()
				ctx.set_header(.etag, tag)
				ctx.set_header(.cache_control, 'private, no-cache')
				return send_json(mut ctx, encode_sub_genres_json(&rows))
			}
			rows := app.genres_mat()
			mut list := []json2.Any{}
			for gr in rows {
				mut g := map[string]json2.Any{}
				g['value'] = gr.name
				g['songCount'] = gr.songs
				g['albumCount'] = gr.albums
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
			items := app.random_items(int_param(q, 'size', 10, 500))
			if is_json {
				return send_json(mut ctx, encode_sub_random_songs_json(&items))
			}
			mut r := map[string]json2.Any{}
			r['song'] = songs(items)
			out['randomSongs'] = r
		}
		'getStarred', 'getStarred2' {
			s_items := app.starred_items()
			s_albums := app.starred_albums(rated, 500, 0)
			s_artists := app.starred_artists()
			item_at := app.starred_map('item')
			album_at := app.starred_map('album')
			artist_at := app.starred_map('artist')
			mut artists_arr := []json2.Any{cap: s_artists.len}
			for ar in s_artists {
				mut ao := map[string]json2.Any{}
				ao['id'] = artist_id(ar.name)
				ao['name'] = or_unknown(ar.name, 'Artist')
				ao['albumCount'] = ar.albums
				ao['coverArt'] = ar.first_id.str()
				if at := artist_at[ar.name] {
					if at > 0 {
						ao['starred'] = iso(at)
					}
				}
				artists_arr << ao
			}
			mut albums_arr := []json2.Any{cap: s_albums.len}
			for al in s_albums {
				albums_arr << sub_album_ex(rated, al, album_at['${al.artist}\x1f${al.name}'])
			}
			mut songs_arr := []json2.Any{cap: s_items.len}
			for it in s_items {
				songs_arr << song_ex(it, item_at[it.id.str()])
			}
			mut st := map[string]json2.Any{}
			st['artist'] = artists_arr
			st['album'] = albums_arr
			st['song'] = songs_arr
			out[if method == 'getStarred' {
				'starred'
			} else {
				'starred2'
			}] = st
		}
		'search2', 'search3' {
			q_text := (q.get('query') or { '' }).trim('"').trim_space()
			song_cnt := int_param(q, 'songCount', 20, 500)
			song_off := int_param(q, 'songOffset', 0, max_int)
			album_cnt := int_param(q, 'albumCount', 20, 500)
			album_off := int_param(q, 'albumOffset', 0, max_int)
			artist_cnt := int_param(q, 'artistCount', 20, 500)
			artist_off := int_param(q, 'artistOffset', 0, max_int)
			song_rows := if song_cnt > 0 {
				if q_text == '' {
					app.items('where ${audio} order by artist collate nocase, album collate nocase, disc_no, track_no limit ? offset ?', [
						song_cnt.str(),
						song_off.str(),
					])
				} else {
					app.search_items_fts(q_text, 'title artist album', true, '', song_cnt,
						song_off)
				}
			} else {
				[]Item{}
			}
			album_rows := if album_cnt > 0 {
				if q_text == '' {
					app.albums_mat(rated, 'order by album collate nocase limit ? offset ?', [
						album_cnt.str(),
						album_off.str(),
					])
				} else {
					app.search_albums_fts(rated, q_text, '', album_cnt, album_off)
				}
			} else {
				[]Album{}
			}
			artist_rows := if artist_cnt > 0 {
				if q_text == '' {
					app.artists_mat('artist', 'order by name collate nocase limit ? offset ?', [
						artist_cnt.str(),
						artist_off.str(),
					])
				} else {
					app.search_artists_fts('artist', q_text, artist_cnt, artist_off)
				}
			} else {
				[]ArtistRow{}
			}
			if is_json {
				return send_json(mut ctx, encode_sub_search_json(&song_rows, &album_rows,
					&artist_rows, rated, method == 'search2'))
			}
			mut r := map[string]json2.Any{}
			r['song'] = songs(song_rows)
			r['album'] = albums_json(rated, album_rows)
			mut artists := []json2.Any{}
			for row in artist_rows {
				mut a_obj := map[string]json2.Any{}
				a_obj['id'] = artist_id(row.name)
				a_obj['name'] = or_unknown(row.name, 'Artist')
				a_obj['albumCount'] = row.albums
				a_obj['coverArt'] = row.first_id.str()
				artists << a_obj
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
			sums := app.playlist_summaries()
			if is_json {
				return send_json(mut ctx, encode_sub_playlists_json(&sums))
			}
			mut l := map[string]json2.Any{}
			l['playlist'] = sums.map(sub_playlist_summary(it))
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
		'star', 'unstar' {
			sub_star(mut app, p, q, method == 'star') or {
				return sub_error(mut ctx, q, 70, err.msg())
			}
		}
		'savePlayQueue' {
			ids := q.get_all('id').map(it.int()).filter(it > 0)
			cur := (q.get('current') or { '0' }).int()
			pos := (q.get('position') or { '0' }).i64()
			app.save_play_queue(p, ids, cur, pos, p.name) or {
				return sub_error(mut ctx, q, 0, err.msg())
			}
		}
		'getPlayQueue' {
			if pq := app.get_play_queue() {
				id_strs := pq.item_ids.map(it.str())
				mut by_id := map[int]Item{}
				for it in app.items('where ${audio} and id in (${qmarks(id_strs.len)})',
					id_strs) {
					by_id[it.id] = it
				}
				mut entries := []Item{}
				for item_id in pq.item_ids {
					if item_id in by_id {
						entries << by_id[item_id]
					}
				}
				if entries.len > 0 {
					mut qobj := map[string]json2.Any{}
					if pq.current_id > 0 {
						qobj['current'] = pq.current_id.str()
					}
					qobj['position'] = pq.position_ms
					qobj['username'] = pq.changed_by
					qobj['changed'] = iso(pq.updated_at)
					qobj['changedBy'] = pq.changed_by
					qobj['entry'] = songs(entries)
					out['playQueue'] = qobj
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
			t['discNumber'] = it.disc_no
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

fn sub_star(mut app App, p Principal, q urllib.Values, starred bool) ! {
	for raw_id in q.get_all('id') {
		if raw_id.starts_with('al-') {
			parts := decode_id(raw_id)
			if parts.len != 2 {
				return error('Album not found.')
			}
			app.set_star(p, 'album', '${parts[0]}\x1f${parts[1]}', starred)!
		} else if raw_id.starts_with('ar-') {
			parts := decode_id(raw_id)
			app.set_star(p, 'artist', parts[0], starred)!
		} else {
			it := app.item(raw_id.int()) or { return error('Song not found.') }
			app.set_star(p, 'item', it.id.str(), starred)!
		}
	}
	for aid in q.get_all('albumId') {
		parts := decode_id(aid)
		if !aid.starts_with('al-') || parts.len != 2 {
			return error('Album not found.')
		}
		app.set_star(p, 'album', '${parts[0]}\x1f${parts[1]}', starred)!
	}
	for arid in q.get_all('artistId') {
		parts := decode_id(arid)
		if !arid.starts_with('ar-') || parts.len == 0 {
			return error('Artist not found.')
		}
		app.set_star(p, 'artist', parts[0], starred)!
	}
}

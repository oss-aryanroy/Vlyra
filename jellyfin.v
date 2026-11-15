module main

import crypto.md5
import net.urllib
import os
import veb
import x.json2

const jf_view = '0f000000000000000000000000000001'
const jf_ticks = i64(10_000_000)

fn jf_item_id(id int) string {
	return '1${id:031}'
}

fn jf_playlist_id(id int) string {
	return '2${id:031}'
}

fn jf_user_id(app_id int) string {
	return '3${app_id:031}'
}

fn jf_album_id(artist string, album string) string {
	return md5.hexhash('al\x1f${artist}\x1f${album}')
}

fn jf_artist_id(artist string) string {
	return md5.hexhash('ar\x1f${artist}')
}

fn jf_row(id string, kind u8) int {
	if id.len != 32 || id[0] != kind || id[1..22] != '0'.repeat(21) {
		return 0
	}
	return id[22..].int()
}

fn jf_norm(id string) string {
	return id.replace('-', '').to_lower()
}

fn jf_names(artist string) []json2.Any {
	mut o := map[string]json2.Any{}
	o['Name'] = or_unknown(artist, 'Artist')
	o['Id'] = jf_artist_id(artist)
	return [json2.Any(o)]
}

fn jf_userdata(key string) json2.Any {
	mut u := map[string]json2.Any{}
	u['PlaybackPositionTicks'] = 0
	u['PlayCount'] = 0
	u['IsFavorite'] = false
	u['Played'] = false
	u['Key'] = key
	return u
}

fn jf_image(first_id int) json2.Any {
	mut t := map[string]json2.Any{}
	t['Primary'] = first_id.str()
	return t
}

fn (app &App) jf_server_id() string {
	return md5.hexhash('vlyra\x1f${app.data_dir}')
}

fn (app &App) jf_song(it Item) json2.Any {
	ext := os.file_ext(it.path).to_lower().trim_left('.')
	id := jf_item_id(it.id)
	mut stream := map[string]json2.Any{}
	stream['Type'] = 'Audio'
	stream['Codec'] = ext
	stream['Index'] = 0
	stream['IsDefault'] = true
	mut src := map[string]json2.Any{}
	src['Id'] = id
	src['Name'] = it.title
	src['Protocol'] = 'File'
	src['Type'] = 'Default'
	src['Container'] = ext
	src['Size'] = it.size
	src['RunTimeTicks'] = i64(it.duration) * jf_ticks
	src['SupportsDirectPlay'] = true
	src['SupportsDirectStream'] = true
	src['SupportsTranscoding'] = false
	src['IsRemote'] = false
	src['MediaStreams'] = [json2.Any(stream)]
	mut s := map[string]json2.Any{}
	s['Name'] = it.title
	s['ServerId'] = app.jf_server_id()
	s['Id'] = id
	s['Type'] = 'Audio'
	s['MediaType'] = 'Audio'
	s['IsFolder'] = false
	s['LocationType'] = 'FileSystem'
	s['Container'] = ext
	s['RunTimeTicks'] = i64(it.duration) * jf_ticks
	s['IndexNumber'] = it.track_no
	s['ProductionYear'] = it.year
	s['Album'] = or_unknown(it.album, 'Album')
	s['AlbumId'] = jf_album_id(it.album_artist, it.album)
	s['ParentId'] = jf_album_id(it.album_artist, it.album)
	s['AlbumArtist'] = or_unknown(it.artist, 'Artist')
	s['AlbumArtists'] = jf_names(it.artist)
	s['Artists'] = [json2.Any(or_unknown(it.artist, 'Artist'))]
	s['ArtistItems'] = jf_names(it.artist)
	s['Genres'] = if it.genre != '' { [json2.Any(it.genre)] } else { []json2.Any{} }
	s['DateCreated'] = iso(it.added_at)
	s['ImageTags'] = jf_image(it.id)
	s['AlbumPrimaryImageTag'] = it.id.str()
	s['UserData'] = jf_userdata(id)
	s['MediaSources'] = [json2.Any(src)]
	return s
}

fn (app &App) jf_album(al Album) json2.Any {
	id := jf_album_id(al.artist, al.name)
	mut a := map[string]json2.Any{}
	a['Name'] = or_unknown(al.name, 'Album')
	a['ServerId'] = app.jf_server_id()
	a['Id'] = id
	a['Type'] = 'MusicAlbum'
	a['IsFolder'] = true
	a['ParentId'] = jf_view
	a['AlbumArtist'] = or_unknown(al.artist, 'Artist')
	a['AlbumArtists'] = jf_names(al.artist)
	a['Artists'] = [json2.Any(or_unknown(al.artist, 'Artist'))]
	a['ArtistItems'] = jf_names(al.artist)
	a['ProductionYear'] = al.year
	a['ChildCount'] = al.songs
	a['RunTimeTicks'] = i64(al.duration) * jf_ticks
	a['Genres'] = if al.genre != '' { [json2.Any(al.genre)] } else { []json2.Any{} }
	a['DateCreated'] = iso(al.added_at)
	a['ImageTags'] = jf_image(al.first_id)
	a['UserData'] = jf_userdata(id)
	return a
}

fn (app &App) jf_artist(ar ArtistRow) json2.Any {
	id := jf_artist_id(ar.name)
	mut a := map[string]json2.Any{}
	a['Name'] = or_unknown(ar.name, 'Artist')
	a['ServerId'] = app.jf_server_id()
	a['Id'] = id
	a['Type'] = 'MusicArtist'
	a['IsFolder'] = true
	a['AlbumCount'] = ar.albums
	a['ImageTags'] = jf_image(ar.first_id)
	a['UserData'] = jf_userdata(id)
	return a
}

fn (app &App) jf_playlist(pl Playlist) json2.Any {
	items := app.playlist_items(pl.id)
	mut total := 0
	for it in items {
		total += it.duration
	}
	id := jf_playlist_id(pl.id)
	mut o := map[string]json2.Any{}
	o['Name'] = pl.name
	o['ServerId'] = app.jf_server_id()
	o['Id'] = id
	o['Type'] = 'Playlist'
	o['MediaType'] = 'Audio'
	o['IsFolder'] = true
	o['ChildCount'] = items.len
	o['RunTimeTicks'] = i64(total) * jf_ticks
	o['DateCreated'] = iso(pl.created_at)
	o['ImageTags'] = if items.len > 0 {
		jf_image(items[0].id)
	} else {
		json2.Any(map[string]json2.Any{})
	}
	o['UserData'] = jf_userdata(id)
	return o
}

fn (app &App) jf_view() json2.Any {
	mut v := map[string]json2.Any{}
	v['Name'] = 'Music'
	v['ServerId'] = app.jf_server_id()
	v['Id'] = jf_view
	v['Type'] = 'CollectionFolder'
	v['CollectionType'] = 'music'
	v['IsFolder'] = true
	v['ImageTags'] = map[string]json2.Any{}
	v['UserData'] = jf_userdata(jf_view)
	return v
}

fn (app &App) jf_user(p Principal) json2.Any {
	mut policy := map[string]json2.Any{}
	policy['IsAdministrator'] = false
	policy['IsHidden'] = true
	policy['IsDisabled'] = false
	policy['EnableAllFolders'] = true
	policy['EnableMediaPlayback'] = p.can('library:read')
	policy['EnableAudioPlaybackTranscoding'] = false
	policy['EnableVideoPlaybackTranscoding'] = false
	policy['EnablePlaybackRemuxing'] = false
	policy['EnableContentDownloading'] = p.can('library:read')
	policy['EnableContentDeletion'] = false
	policy['EnableRemoteAccess'] = true
	policy['AuthenticationProviderId'] = 'Vlyra'
	policy['PasswordResetProviderId'] = 'Vlyra'
	mut conf := map[string]json2.Any{}
	conf['PlayDefaultAudioTrack'] = true
	conf['SubtitleMode'] = 'Default'
	conf['EnableNextEpisodeAutoPlay'] = false
	mut u := map[string]json2.Any{}
	u['Name'] = p.name
	u['ServerId'] = app.jf_server_id()
	u['Id'] = jf_user_id(p.app_id)
	u['HasPassword'] = true
	u['HasConfiguredPassword'] = true
	u['HasConfiguredEasyPassword'] = false
	u['EnableAutoLogin'] = false
	u['Policy'] = policy
	u['Configuration'] = conf
	return u
}

fn jf_page(items []json2.Any, total int, start int) json2.Any {
	mut o := map[string]json2.Any{}
	o['Items'] = items
	o['TotalRecordCount'] = total
	o['StartIndex'] = start
	return o
}

fn jf_slice(all []json2.Any, start int, limit int) json2.Any {
	from := if start < all.len { start } else { all.len }
	to := if from + limit < all.len { from + limit } else { all.len }
	return jf_page(all[from..to], all.len, start)
}

fn (app &App) jf_find_album(id string) ?Album {
	for al in app.album_rows('group by ${album_group}', []) {
		if jf_album_id(al.artist, al.name) == id {
			return al
		}
	}
	return none
}

fn (app &App) jf_find_artist(id string) ?ArtistRow {
	for ar in app.artist_rows('group by artist', []) {
		if jf_artist_id(ar.name) == id {
			return ar
		}
	}
	return none
}

fn (app &App) jf_lookup(id string) ?json2.Any {
	if id == jf_view {
		return app.jf_view()
	}
	if n := app.item(jf_row(id, `1`)) {
		return app.jf_song(n)
	}
	if pl := app.playlist(jf_row(id, `2`)) {
		return app.jf_playlist(pl)
	}
	if al := app.jf_find_album(id) {
		return app.jf_album(al)
	}
	if ar := app.jf_find_artist(id) {
		return app.jf_artist(ar)
	}
	return none
}

fn (app &App) jf_cover(id string) ?Item {
	if it := app.item(jf_row(id, `1`)) {
		return it
	}
	if jf_row(id, `2`) > 0 {
		items := app.playlist_items(jf_row(id, `2`))
		return if items.len > 0 { items[0] } else { none }
	}
	if al := app.jf_find_album(id) {
		return app.item(al.first_id)
	}
	if ar := app.jf_find_artist(id) {
		return app.item(ar.first_id)
	}
	return none
}

fn (app &App) jf_songs(where string, params []string, order string, start int, limit int) json2.Any {
	total := app.reader().exec_param_many('select count(*) from items where ${audio} ${where}',
		params) or { return jf_page([], 0, start) }
	mut all := params.clone()
	all << [limit.str(), start.str()]
	found := app.items('where ${audio} ${where} order by ${order} limit ? offset ?', all)
	return jf_page(found.map(app.jf_song(it)), total[0].vals[0].int(), start)
}

fn (app &App) jf_items(p Principal, q map[string]string) json2.Any {
	types := q['includeitemtypes'].to_lower()
	parent := jf_norm(q['parentid'])
	start := if q['startindex'].int() > 0 { q['startindex'].int() } else { 0 }
	limit := if q['limit'].int() > 0 { q['limit'].int() } else { 1000000 }
	sort_by := q['sortby'].to_lower()
	dir := if q['sortorder'].to_lower().starts_with('desc') { 'desc' } else { 'asc' }
	pattern := '%' + q['searchterm'] + '%'
	nothing := jf_page([], 0, start)

	if q['filters'].to_lower().contains('isfavorite') || q['isfavorite'] == 'true' {
		return nothing
	}
	if q['ids'] != '' {
		mut out := []json2.Any{}
		for raw in q['ids'].split(',') {
			out << app.jf_lookup(jf_norm(raw)) or { continue }
		}
		return jf_page(out, out.len, 0)
	}
	if jf_row(parent, `2`) > 0 {
		if !p.can('playlists:read') {
			return nothing
		}
		return jf_slice(app.playlist_items(jf_row(parent, `2`)).map(app.jf_song(it)), start, limit)
	}

	song_order := if sort_by.contains('random') {
		'random()'
	} else if sort_by.contains('datecreated') {
		'added_at ${dir}'
	} else if sort_by.starts_with('sortname') || sort_by.starts_with('name') {
		'title collate nocase ${dir}'
	} else {
		'artist collate nocase, album collate nocase, track_no'
	}
	album_order := if sort_by.contains('random') {
		'random()'
	} else if sort_by.contains('datecreated') {
		'max(added_at) ${dir}'
	} else if sort_by.contains('productionyear') || sort_by.contains('premieredate') {
		'max(year) ${dir}, album collate nocase'
	} else {
		'album collate nocase ${dir}'
	}

	album_ref := jf_norm(if q['albumids'] != '' { q['albumids'].all_before(',') } else { parent })
	if album_ref !in ['', jf_view] {
		if al := app.jf_find_album(album_ref) {
			return app.jf_songs('and ${album_match}', [al.artist, al.name],
				'track_no, title collate nocase', start, limit)
		}
	}
	artist_ref := jf_norm((q['albumartistids'] + ',' + q['artistids'] + ',' +
		q['contributingartistids'] + ',' + parent).trim(',').all_before(','))
	if artist_ref !in ['', jf_view] {
		if ar := app.jf_find_artist(artist_ref) {
			if types.contains('audio') {
				return app.jf_songs('and artist = ?', [ar.name], song_order, start, limit)
			}
			return jf_slice(app.album_rows('and artist = ? group by ${album_group} order by ${album_order}', [
				ar.name,
			]).map(app.jf_album(it)), start, limit)
		}
	}

	genre := q['genres'].all_before('|')
	genre_filter := if genre != '' { 'and genre = ?' } else { '' }
	mut genre_param := []string{}
	if genre != '' {
		genre_param << genre
	}
	if types.contains('playlist') {
		if !p.can('playlists:read') {
			return nothing
		}
		found := sql app.db {
			select from Playlist order by name
		} or { []Playlist{} }
		return jf_slice(found.map(app.jf_playlist(it)), start, limit)
	}
	if types.contains('musicartist') {
		return jf_slice(app.artist_rows('and artist like ? group by artist order by artist collate nocase', [
			pattern,
		]).map(app.jf_artist(it)), start, limit)
	}
	if types.contains('musicalbum') || (types == '' && parent == jf_view && q['searchterm'] == '') {
		mut params := [pattern, pattern]
		params << genre_param
		return jf_slice(app.album_rows('and (album like ? or album_artist like ?) ${genre_filter} group by ${album_group} order by ${album_order}',
			params).map(app.jf_album(it)), start, limit)
	}
	if types.contains('audio') || q['searchterm'] != '' {
		mut params := [pattern, pattern, pattern]
		params << genre_param
		return app.jf_songs('and (title like ? or artist like ? or album like ?) ${genre_filter}',
			params, song_order, start, limit)
	}
	if types == '' && parent == '' {
		return jf_page([app.jf_view()], 1, 0)
	}
	return nothing
}

fn jf_send(mut ctx Context, v json2.Any) veb.Result {
	return ctx.send_response_to_client('application/json', v.json_str())
}

fn jf_token(ctx &Context, q map[string]string) string {
	for name in ['Authorization', 'X-Emby-Authorization'] {
		value := ctx.req.header.get_custom(name, exact: false) or { continue }
		if value.contains('Token="') {
			return value.find_between('Token="', '"')
		}
	}
	for name in ['X-Emby-Token', 'X-MediaBrowser-Token'] {
		return ctx.req.header.get_custom(name, exact: false) or { continue }
	}
	return if q['api_key'] != '' { q['api_key'] } else { q['apikey'] }
}

@['/:path...'; delete; get; post]
pub fn (mut app App) jellyfin(mut ctx Context, path string) veb.Result {
	if !app.protocol_on('jellyfin') {
		return ctx.not_found()
	}
	mut s := path.all_before('?').to_lower().trim('/').split('/')
	mut q := map[string]string{}
	if ctx.req.url.contains('?') {
		parsed := urllib.parse_query(ctx.req.url.all_after('?')) or { urllib.new_values() }
		for kv in parsed.data {
			q[kv.key.to_lower()] = kv.value
		}
	}
	route := s.join('/')
	b := body(ctx)
	text := fn [b] (key string) string {
		return (b[key] or { json2.Any('') }).str()
	}

	if route == 'system/info/public' {
		mut o := map[string]json2.Any{}
		o['LocalAddress'] = 'http://' + (ctx.get_header(.host) or { 'localhost' })
		o['ServerName'] = 'Vlyra'
		o['ProductName'] = 'Vlyra'
		o['Version'] = '10.10.0'
		o['OperatingSystem'] = os.user_os()
		o['Id'] = app.jf_server_id()
		o['StartupWizardCompleted'] = true
		return jf_send(mut ctx, o)
	}
	if route == 'system/ping' {
		return jf_send(mut ctx, 'Vlyra')
	}
	if route == 'users/public' {
		return jf_send(mut ctx, []json2.Any{})
	}
	if route == 'quickconnect/enabled' {
		return jf_send(mut ctx, false)
	}
	if route.starts_with('branding/') {
		return jf_send(mut ctx, map[string]json2.Any{})
	}
	if route == 'users/authenticatebyname' {
		p := app.app_by_token(text('Pw')) or {
			ctx.res.set_status(.unauthorized)
			return ctx.text('Wrong username or password.')
		}
		if p.name.to_lower() != text('Username').to_lower() {
			ctx.res.set_status(.unauthorized)
			return ctx.text('Wrong username or password.')
		}
		mut session := map[string]json2.Any{}
		session['Id'] = md5.hexhash(text('Pw'))
		session['UserId'] = jf_user_id(p.app_id)
		session['UserName'] = p.name
		session['ServerId'] = app.jf_server_id()
		mut o := map[string]json2.Any{}
		o['User'] = app.jf_user(p)
		o['SessionInfo'] = session
		o['AccessToken'] = text('Pw')
		o['ServerId'] = app.jf_server_id()
		return jf_send(mut ctx, o)
	}
	// Jellyfin serves images without credentials and clients rely on it.
	if s.len >= 4 && s[0] == 'items' && s[2] == 'images' {
		it := app.jf_cover(jf_norm(s[1])) or { return ctx.not_found() }
		return send_artwork(mut ctx, app, it, if q['fillwidth'].int() > 0 {
			q['fillwidth'].int()
		} else {
			q['maxwidth'].int()
		})
	}

	p := app.app_by_token(jf_token(ctx, q)) or {
		ctx.res.set_status(.unauthorized)
		return ctx.text('Sign in with an app name and its Vlyra API token.')
	}
	forbidden := fn [mut ctx] (scope string) veb.Result {
		ctx.res.set_status(.forbidden)
		return ctx.text('This app has not been granted ${scope} in Vlyra.')
	}
	if s.len > 2 && s[0] == 'users' {
		s = s[2..].clone()
	}
	a := s[0]
	id := if s.len > 1 { jf_norm(s[1]) } else { '' }
	tail := if s.len > 2 { s[2] } else { '' }
	post := ctx.req.method == .post

	if a == 'users' {
		return jf_send(mut ctx, app.jf_user(p))
	}
	if a == 'system' {
		mut o := map[string]json2.Any{}
		o['ServerName'] = 'Vlyra'
		o['Version'] = '10.10.0'
		o['Id'] = app.jf_server_id()
		o['OperatingSystem'] = os.user_os()
		return jf_send(mut ctx, o)
	}
	if a == 'sessions' {
		if route == 'sessions/playing/stopped' && p.can('history:write') {
			if it := app.item(jf_row(jf_norm(text('ItemId')), `1`)) {
				position := (b['PositionTicks'] or { json2.Any(0) }).i64() / jf_ticks
				if it.duration > 0 && position * 2 >= it.duration {
					app.record_play(p, it.id, 0) or {}
				}
			}
		}
		return ctx.no_content()
	}
	if a in ['playeditems', 'userplayeditems'] {
		if !p.can('history:write') {
			return forbidden('history:write')
		}
		if post {
			app.record_play(p, jf_row(id, `1`), 0) or { return ctx.not_found() }
		}
		return jf_send(mut ctx, jf_userdata(id))
	}
	if a in ['favoriteitems', 'userfavoriteitems'] {
		return jf_send(mut ctx, jf_userdata(id))
	}
	if a == 'displaypreferences' {
		mut o := map[string]json2.Any{}
		o['Id'] = id
		o['SortBy'] = 'SortName'
		o['SortOrder'] = 'Ascending'
		o['CustomPrefs'] = map[string]json2.Any{}
		return jf_send(mut ctx, o)
	}
	if !p.can('library:read') {
		return forbidden('library:read')
	}
	if a in ['views', 'userviews'] {
		return jf_send(mut ctx, jf_page([app.jf_view()], 1, 0))
	}
	if a in ['genres', 'musicgenres'] {
		rows := app.db.exec("select distinct genre from items where ${audio} and genre != '' order by genre collate nocase") or {
			[]
		}
		mut list := []json2.Any{}
		for r in rows {
			mut g := map[string]json2.Any{}
			g['Name'] = r.vals[0]
			g['Id'] = md5.hexhash('ge\x1f' + r.vals[0])
			g['Type'] = 'MusicGenre'
			list << g
		}
		return jf_send(mut ctx, jf_page(list, list.len, 0))
	}
	if a == 'artists' && (id == '' || id == 'albumartists') {
		mut qq := q.clone()
		qq['includeitemtypes'] = 'MusicArtist'
		return jf_send(mut ctx, app.jf_items(p, qq))
	}
	if a in ['audio', 'videos'] || (a == 'items' && tail in ['download', 'file']) {
		if tail == 'lyrics' {
			if !p.can('lyrics:read') {
				return forbidden('lyrics:read')
			}
			lyr := structured_lyrics(app.lyrics(jf_row(id, `1`))).as_map()
			mut lines := []json2.Any{}
			for l in (lyr['line'] or { json2.Any([]json2.Any{}) }).as_array() {
				m := l.as_map()
				mut line := map[string]json2.Any{}
				line['Text'] = m['value'] or { json2.Any('') }
				if start := m['start'] {
					line['Start'] = start.i64() * (jf_ticks / 1000)
				}
				lines << line
			}
			mut o := map[string]json2.Any{}
			o['Metadata'] = map[string]json2.Any{}
			o['Lyrics'] = lines
			return jf_send(mut ctx, o)
		}
		it := app.item(jf_row(id, `1`)) or { return ctx.not_found() }
		return serve_media(mut ctx, it.path)
	}
	if a == 'playlists' {
		write := post || ctx.req.method == .delete
		if !p.can(if write { 'playlists:write' } else { 'playlists:read' }) {
			return forbidden(if write { 'playlists:write' } else { 'playlists:read' })
		}
		ids_param := fn (raw string) []int {
			return raw.split(',').map(jf_row(jf_norm(it), `1`)).filter(it > 0)
		}
		if id == '' && post {
			mut ids :=
				(b['Ids'] or { json2.Any([]json2.Any{}) }).as_array().map(jf_row(jf_norm(it.str()), `1`)).filter(it > 0)
			ids << ids_param(q['ids'])
			name := if text('Name') != '' { text('Name') } else { q['name'] }
			pid := app.save_playlist(p, 0, name, ids) or {
				ctx.res.set_status(.bad_request)
				return ctx.text(err.msg())
			}
			mut o := map[string]json2.Any{}
			o['Id'] = jf_playlist_id(pid)
			return jf_send(mut ctx, o)
		}
		pid := jf_row(id, `2`)
		pl := app.playlist(pid) or { return ctx.not_found() }
		current := app.playlist_items(pid)
		if tail == 'items' && post {
			mut ids := current.map(it.id)
			ids << ids_param(q['ids'])
			app.save_playlist(p, pid, '', ids) or { return ctx.not_found() }
			return ctx.no_content()
		}
		if tail == 'items' && ctx.req.method == .delete {
			gone := q['entryids'].split(',').map(jf_norm(it))
			app.save_playlist(p, pid, '', current.filter(jf_item_id(it.id) !in gone).map(it.id)) or {
				return ctx.not_found()
			}
			return ctx.no_content()
		}
		if tail == 'items' {
			mut entries := []json2.Any{}
			for it in current {
				mut e := app.jf_song(it).as_map()
				e['PlaylistItemId'] = jf_item_id(it.id)
				entries << e
			}
			return jf_send(mut ctx, jf_slice(entries, q['startindex'].int(), if q['limit'].int() > 0 {
				q['limit'].int()
			} else {
				1000000
			}))
		}
		return jf_send(mut ctx, app.jf_playlist(pl))
	}
	if a == 'items' {
		if id == '' {
			return jf_send(mut ctx, app.jf_items(p, q))
		}
		if id == 'latest' {
			limit := if q['limit'].int() > 0 { q['limit'].int() } else { 20 }
			return jf_send(mut ctx, app.album_rows('group by ${album_group} order by max(added_at) desc limit ?', [
				limit.str(),
			]).map(app.jf_album(it)))
		}
		if ctx.req.method == .delete {
			if !p.can('playlists:write') {
				return forbidden('playlists:write')
			}
			app.delete_playlist(p, jf_row(id, `2`)) or { return ctx.not_found() }
			return ctx.no_content()
		}
		if tail == 'playbackinfo' {
			it := app.item(jf_row(id, `1`)) or { return ctx.not_found() }
			mut o := map[string]json2.Any{}
			o['MediaSources'] = app.jf_song(it).as_map()['MediaSources'] or {
				json2.Any([]json2.Any{})
			}
			o['PlaySessionId'] = md5.hexhash(id + p.name)
			return jf_send(mut ctx, o)
		}
		if tail in ['similar', 'instantmix'] {
			found := app.random_items(if q['limit'].int() > 0 { q['limit'].int() } else { 50 })
			return jf_send(mut ctx, jf_page(found.map(app.jf_song(it)), found.len, 0))
		}
		if tail == 'lyrics' {
			return ctx.redirect('/Audio/${id}/Lyrics')
		}
		return jf_send(mut ctx, app.jf_lookup(id) or { return ctx.not_found() })
	}
	return ctx.not_found()
}

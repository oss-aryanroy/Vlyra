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

fn jf_userdata_fav(key string, plays int, last_played i64, fav bool) json2.Any {
	mut u := map[string]json2.Any{}
	u['PlaybackPositionTicks'] = 0
	u['PlayCount'] = plays
	u['IsFavorite'] = fav
	u['Played'] = plays > 0
	if last_played > 0 {
		u['LastPlayedDate'] = iso(last_played)
	}
	u['Key'] = key
	return u
}

fn jf_userdata(key string, plays int, last_played i64) json2.Any {
	return jf_userdata_fav(key, plays, last_played, false)
}

fn jf_image(first_id int) json2.Any {
	mut t := map[string]json2.Any{}
	t['Primary'] = first_id.str()
	return t
}

fn (app &App) jf_server_id() string {
	return app.server_id
}

fn (app &App) jf_song_ex(it Item, fav bool) json2.Any {
	ext := os.file_ext(it.path).to_lower().trim_left('.')
	id := jf_item_id(it.id)
	id_str := it.id.str()
	srv := app.server_id
	al_id := jf_album_id(it.album_artist, it.album)
	aa := if it.album_artist != '' { it.album_artist } else { it.artist }
	ar_name := or_unknown(it.artist, 'Artist')
	ar_items := jf_names(it.artist)
	aa_items := if aa == it.artist { ar_items } else { jf_names(aa) }
	mut stream := map[string]json2.Any{}
	stream['Type'] = 'Audio'
	stream['Codec'] = ext
	stream['Index'] = 0
	stream['IsDefault'] = true
	if it.bitrate > 0 {
		stream['BitRate'] = it.bitrate * 1000
	}
	if it.sample_rate > 0 {
		stream['SampleRate'] = it.sample_rate
	}
	if it.bit_depth > 0 {
		stream['BitDepth'] = it.bit_depth
	}
	if it.channels > 0 {
		stream['Channels'] = it.channels
	}
	mut src := map[string]json2.Any{}
	src['Id'] = id
	src['Name'] = it.title
	src['Protocol'] = 'File'
	src['Type'] = 'Default'
	src['Container'] = ext
	src['Size'] = it.size
	if it.bitrate > 0 {
		src['Bitrate'] = it.bitrate * 1000
	}
	src['RunTimeTicks'] = i64(it.duration) * jf_ticks
	src['SupportsDirectPlay'] = true
	src['SupportsDirectStream'] = true
	src['SupportsTranscoding'] = false
	src['IsRemote'] = false
	src['MediaStreams'] = [json2.Any(stream)]
	mut s := map[string]json2.Any{}
	s['Name'] = it.title
	s['ServerId'] = srv
	s['Id'] = id
	s['Type'] = 'Audio'
	s['MediaType'] = 'Audio'
	s['IsFolder'] = false
	s['LocationType'] = 'FileSystem'
	s['Container'] = ext
	s['RunTimeTicks'] = i64(it.duration) * jf_ticks
	s['IndexNumber'] = it.track_no
	if it.disc_no > 0 {
		s['ParentIndexNumber'] = it.disc_no
	}
	if it.rg_track_gain != 0 {
		s['NormalizationGain'] = it.rg_track_gain
	}
	s['ProductionYear'] = it.year
	s['Album'] = or_unknown(it.album, 'Album')
	s['AlbumId'] = al_id
	s['ParentId'] = al_id
	s['AlbumArtist'] = or_unknown(aa, 'Artist')
	s['AlbumArtists'] = aa_items
	s['Artists'] = [json2.Any(ar_name)]
	s['ArtistItems'] = ar_items
	s['Genres'] = if it.genre != '' { [json2.Any(it.genre)] } else { []json2.Any{} }
	s['DateCreated'] = iso(it.added_at)
	s['ImageTags'] = jf_image(it.id)
	s['AlbumPrimaryImageTag'] = id_str
	s['UserData'] = jf_userdata_fav(id, it.play_count, it.last_played, fav)
	s['MediaSources'] = [json2.Any(src)]
	return s
}

fn (app &App) jf_song(it Item) json2.Any {
	return app.jf_song_ex(it, app.is_starred('item', it.id.str()))
}

fn (app &App) jf_album_ex(al Album, fav bool) json2.Any {
	id := jf_album_id(al.artist, al.name)
	ar_name := or_unknown(al.artist, 'Artist')
	ar_items := jf_names(al.artist)
	mut a := map[string]json2.Any{}
	a['Name'] = or_unknown(al.name, 'Album')
	a['ServerId'] = app.server_id
	a['Id'] = id
	a['Type'] = 'MusicAlbum'
	a['IsFolder'] = true
	a['ParentId'] = jf_view
	a['AlbumArtist'] = ar_name
	a['AlbumArtists'] = ar_items
	a['Artists'] = [json2.Any(ar_name)]
	a['ArtistItems'] = ar_items
	a['ProductionYear'] = al.year
	a['ChildCount'] = al.songs
	a['RunTimeTicks'] = i64(al.duration) * jf_ticks
	a['Genres'] = if al.genre != '' { [json2.Any(al.genre)] } else { []json2.Any{} }
	a['DateCreated'] = iso(al.added_at)
	a['ImageTags'] = jf_image(al.first_id)
	a['UserData'] = jf_userdata_fav(id, al.play_count, al.last_played, fav)
	return a
}

fn (app &App) jf_album(al Album) json2.Any {
	return app.jf_album_ex(al, app.is_starred('album', '${al.artist}\x1f${al.name}'))
}

fn (app &App) jf_artist_ex(ar ArtistRow, fav bool) json2.Any {
	id := jf_artist_id(ar.name)
	mut a := map[string]json2.Any{}
	a['Name'] = or_unknown(ar.name, 'Artist')
	a['ServerId'] = app.jf_server_id()
	a['Id'] = id
	a['Type'] = 'MusicArtist'
	a['IsFolder'] = true
	a['AlbumCount'] = ar.albums
	a['ImageTags'] = jf_image(ar.first_id)
	a['UserData'] = jf_userdata_fav(id, 0, 0, fav)
	return a
}

fn (app &App) jf_artist(ar ArtistRow) json2.Any {
	return app.jf_artist_ex(ar, app.is_starred('artist', ar.name))
}

fn (app &App) jf_playlist_summary(ps PlaylistSummary) json2.Any {
	id := jf_playlist_id(ps.id)
	mut o := map[string]json2.Any{}
	o['Name'] = ps.name
	o['ServerId'] = app.server_id
	o['Id'] = id
	o['Type'] = 'Playlist'
	o['MediaType'] = 'Audio'
	o['IsFolder'] = true
	o['ChildCount'] = ps.songs
	o['RunTimeTicks'] = i64(ps.duration) * jf_ticks
	o['DateCreated'] = iso(ps.created_at)
	o['ImageTags'] = if ps.first_id > 0 {
		jf_image(ps.first_id)
	} else {
		json2.Any(map[string]json2.Any{})
	}
	o['UserData'] = jf_userdata(id, 0, 0)
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
	v['UserData'] = jf_userdata(jf_view, 0, 0)
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

fn jf_bounds(total int, start int, limit int) (int, int) {
	from := if start < 0 {
		0
	} else if start < total {
		start
	} else {
		total
	}
	to := if limit <= 0 || from + limit > total { total } else { from + limit }
	return from, to
}

fn (app &App) jf_find_album(id string) ?Album {
	return app.find_album_by_jf_id(id)
}

fn (app &App) jf_find_artist(id string) ?ArtistRow {
	return app.find_artist_by_jf_id(id)
}

fn (app &App) jf_lookup(id string) ?json2.Any {
	if id == jf_view {
		return app.jf_view()
	}
	if n := app.item(jf_row(id, `1`)) {
		return app.jf_song(n)
	}
	if ps := app.playlist_summary(jf_row(id, `2`)) {
		return app.jf_playlist_summary(ps)
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
	search_q := q['searchterm'].trim_space()
	nothing := jf_page([], 0, start)

	if q['filters'].to_lower().contains('isfavorite') || q['isfavorite'] == 'true' {
		if types.contains('musicalbum') {
			favs := app.starred_albums(false, limit, start)
			return jf_page(favs.map(app.jf_album_ex(it, true)), favs.len, start)
		}
		if types.contains('musicartist') {
			favs := app.starred_artists()
			from, to := jf_bounds(favs.len, start, limit)
			return jf_page(favs[from..to].map(app.jf_artist_ex(it, true)), favs.len, start)
		}
		favs := app.starred_items()
		from, to := jf_bounds(favs.len, start, limit)
		return jf_page(favs[from..to].map(app.jf_song_ex(it, true)), favs.len, start)
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
		raw := app.playlist_items(jf_row(parent, `2`))
		from, to := jf_bounds(raw.len, start, limit)
		return jf_page(raw[from..to].map(app.jf_song(it)), raw.len, start)
	}

	song_order := if sort_by.contains('random') {
		'random()'
	} else if sort_by.contains('datecreated') {
		'added_at ${dir}'
	} else if sort_by.contains('playcount') {
		'play_count ${dir}, title collate nocase'
	} else if sort_by.contains('dateplayed') {
		'last_played ${dir}, title collate nocase'
	} else if sort_by.starts_with('sortname') || sort_by.starts_with('name') {
		'title collate nocase ${dir}'
	} else {
		'artist collate nocase, album collate nocase, disc_no, track_no'
	}
	album_order := if sort_by.contains('random') {
		'random()'
	} else if sort_by.contains('datecreated') {
		'added_at ${dir}'
	} else if sort_by.contains('productionyear') || sort_by.contains('premieredate') {
		'year ${dir}, album collate nocase'
	} else if sort_by.contains('playcount') {
		'play_count ${dir}, album collate nocase'
	} else if sort_by.contains('dateplayed') {
		'last_played ${dir}, album collate nocase'
	} else if sort_by.contains('albumartist') {
		'album_artist collate nocase ${dir}, album collate nocase'
	} else if sort_by.contains('communityrating') {
		'rating ${dir}, album collate nocase'
	} else {
		'album collate nocase ${dir}'
	}

	album_ref := jf_norm(if q['albumids'] != '' { q['albumids'].all_before(',') } else { parent })
	if album_ref !in ['', jf_view] {
		if al := app.jf_find_album(album_ref) {
			return app.jf_songs('and ${album_match}', [al.artist, al.name],
				'disc_no, track_no, title collate nocase', start, limit)
		}
	}
	artist_ref := jf_norm((q['albumartistids'] + ',' + q['artistids'] + ',' +
		q['contributingartistids'] + ',' + parent).trim(',').all_before(','))
	if artist_ref !in ['', jf_view] {
		if ar := app.jf_find_artist(artist_ref) {
			if types.contains('audio') {
				return app.jf_songs('and (artist = ?1 or album_artist = ?1)', [ar.name],
					song_order, start, limit)
			}
			raw := app.albums_mat(false,
				"where album_artist = ?1 or exists (select 1 from items i where i.missing = 0 and i.kind = 'audio' and i.artist = ?1 and i.album_artist = albums.album_artist and i.album = albums.album) order by ${album_order}", [
				ar.name,
			])
			from, to := jf_bounds(raw.len, start, limit)
			return jf_page(raw[from..to].map(app.jf_album(it)), raw.len, start)
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
		raw := app.playlist_summaries()
		from, to := jf_bounds(raw.len, start, limit)
		return jf_page(raw[from..to].map(app.jf_playlist_summary(it)), raw.len, start)
	}
	if types.contains('musicartist') {
		kind := if q['_albumartists'] == '1' { 'album_artist' } else { 'artist' }
		total := if search_q == '' {
			app.artists_mat_count(kind, '', [])
		} else {
			app.search_artists_fts_count(kind, search_q)
		}
		rows := if search_q == '' {
			app.artists_mat(kind, 'order by name collate nocase limit ? offset ?', [
				limit.str(),
				start.str(),
			])
		} else {
			app.search_artists_fts(kind, search_q, limit, start)
		}
		return jf_page(rows.map(app.jf_artist(it)), total, start)
	}
	if types.contains('musicalbum') || (types == '' && parent == jf_view && search_q == '') {
		if sort_by.contains('random') && search_q == '' && genre == '' {
			total := app.albums_mat_count('', [])
			found := app.random_albums(false, limit)
			return jf_page(found.map(app.jf_album(it)), total, start)
		}
		if search_q == '' {
			where_genre := if genre != '' { 'where genre = ?' } else { '' }
			total := app.albums_mat_count(where_genre, genre_param)
			mut params := genre_param.clone()
			params << [limit.str(), start.str()]
			found := app.albums_mat(false, '${where_genre} order by ${album_order} limit ? offset ?',
				params)
			return jf_page(found.map(app.jf_album(it)), total, start)
		}
		total := app.search_albums_fts_count(search_q, genre)
		found := app.search_albums_fts(false, search_q, genre, limit, start)
		return jf_page(found.map(app.jf_album(it)), total, start)
	}
	if types.contains('audio') || search_q != '' {
		if search_q == '' {
			return app.jf_songs(genre_filter, genre_param, song_order, start, limit)
		}
		total := app.search_items_fts_count(search_q, 'title artist album', true, genre)
		found := app.search_items_fts(search_q, 'title artist album', true, genre, limit,
			start)
		return jf_page(found.map(app.jf_song(it)), total, start)
	}
	if types == '' && parent == '' {
		return jf_page([app.jf_view()], 1, 0)
	}
	return nothing
}

fn jf_send(mut ctx Context, v json2.Any) veb.Result {
	return send_json(mut ctx, v.json_str())
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
		it := app.item(jf_row(id, `1`))
		return jf_send(mut ctx, if x := it {
			jf_userdata(id, x.play_count, x.last_played)
		} else {
			jf_userdata(id, 0, 0)
		})
	}
	if a in ['favoriteitems', 'userfavoriteitems'] {
		write := post || ctx.req.method == .delete
		if write && !p.can('ratings:write') {
			return forbidden('ratings:write')
		}
		mut kind := ''
		mut key := ''
		mut plays := 0
		mut last_played := i64(0)
		if row_id := app.item(jf_row(id, `1`)) {
			kind = 'item'
			key = row_id.id.str()
			plays = row_id.play_count
			last_played = row_id.last_played
		} else if al := app.jf_find_album(id) {
			kind = 'album'
			key = '${al.artist}\x1f${al.name}'
			plays = al.play_count
			last_played = al.last_played
		} else if ar := app.jf_find_artist(id) {
			kind = 'artist'
			key = ar.name
		} else {
			return ctx.not_found()
		}
		if write {
			app.set_star(p, kind, key, post) or { return ctx.not_found() }
			return jf_send(mut ctx, jf_userdata_fav(id, plays, last_played, post))
		}
		return jf_send(mut ctx, jf_userdata_fav(id, plays, last_played, app.is_starred(kind,
			key)))
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
	if a == 'search' && id == 'hints' {
		term := q['searchterm'].trim_space()
		limit := if q['limit'].int() > 0 { q['limit'].int() } else { 20 }
		types := q['includeitemtypes'].to_lower()
		mut hints := []json2.Any{}
		if term != '' {
			want_song := types == '' || types.contains('audio')
			want_album := types == '' || types.contains('musicalbum')
			want_artist := types == '' || types.contains('musicartist')
			if want_song {
				for it in app.search_items_fts(term, 'title artist album', true, '', limit,
					0) {
					jid := jf_item_id(it.id)
					mut h := map[string]json2.Any{}
					h['ItemId'] = jid
					h['Id'] = jid
					h['Name'] = it.title
					h['Type'] = 'Audio'
					h['MediaType'] = 'Audio'
					h['Album'] = or_unknown(it.album, 'Album')
					h['AlbumId'] = jf_album_id(it.album_artist, it.album)
					h['AlbumArtist'] = or_unknown(if it.album_artist != '' {
						it.album_artist
					} else {
						it.artist
					}, 'Artist')
					h['Artists'] = [json2.Any(or_unknown(it.artist, 'Artist'))]
					h['ProductionYear'] = it.year
					h['RunTimeTicks'] = i64(it.duration) * jf_ticks
					h['PrimaryImageTag'] = it.id.str()
					hints << h
					if hints.len >= limit {
						break
					}
				}
			}
			if want_album && hints.len < limit {
				for al in app.search_albums_fts(false, term, '', limit - hints.len, 0) {
					mut h := map[string]json2.Any{}
					jid := jf_album_id(al.artist, al.name)
					h['ItemId'] = jid
					h['Id'] = jid
					h['Name'] = or_unknown(al.name, 'Album')
					h['Type'] = 'MusicAlbum'
					h['AlbumArtist'] = or_unknown(al.artist, 'Artist')
					h['Artists'] = [json2.Any(or_unknown(al.artist, 'Artist'))]
					h['ProductionYear'] = al.year
					h['RunTimeTicks'] = i64(al.duration) * jf_ticks
					h['ChildCount'] = al.songs
					h['PrimaryImageTag'] = al.first_id.str()
					hints << h
					if hints.len >= limit {
						break
					}
				}
			}
			if want_artist && hints.len < limit {
				for ar in app.search_artists_fts('artist', term, limit - hints.len, 0) {
					mut h := map[string]json2.Any{}
					jid := jf_artist_id(ar.name)
					h['ItemId'] = jid
					h['Id'] = jid
					h['Name'] = or_unknown(ar.name, 'Artist')
					h['Type'] = 'MusicArtist'
					h['SongCount'] = ar.albums
					h['PrimaryImageTag'] = ar.first_id.str()
					hints << h
					if hints.len >= limit {
						break
					}
				}
			}
		}
		mut o := map[string]json2.Any{}
		o['SearchHints'] = hints
		o['TotalRecordCount'] = hints.len
		return jf_send(mut ctx, o)
	}
	if a in ['views', 'userviews'] {
		return jf_send(mut ctx, jf_page([app.jf_view()], 1, 0))
	}
	if a in ['genres', 'musicgenres'] {
		mut list := []json2.Any{}
		for gr in app.genres_mat() {
			mut g := map[string]json2.Any{}
			g['Name'] = gr.name
			g['Id'] = md5.hexhash('ge\x1f' + gr.name)
			g['Type'] = 'MusicGenre'
			list << g
		}
		return jf_send(mut ctx, jf_page(list, list.len, 0))
	}
	if a == 'artists' && (id == '' || id == 'albumartists') {
		mut qq := q.clone()
		qq['includeitemtypes'] = 'MusicArtist'
		if id == 'albumartists' {
			qq['_albumartists'] = '1'
		}
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
		ps := app.playlist_summary(pid) or { return ctx.not_found() }
		if tail == 'items' {
			current := app.playlist_items(pid)
			if post {
				mut ids := current.map(it.id)
				ids << ids_param(q['ids'])
				app.save_playlist(p, pid, '', ids) or { return ctx.not_found() }
				return ctx.no_content()
			}
			if ctx.req.method == .delete {
				gone := q['entryids'].split(',').map(jf_norm(it))
				app.save_playlist(p, pid, '', current.filter(jf_item_id(it.id) !in gone).map(it.id)) or {
					return ctx.not_found()
				}
				return ctx.no_content()
			}
			pstart := if q['startindex'].int() > 0 { q['startindex'].int() } else { 0 }
			plimit := if q['limit'].int() > 0 { q['limit'].int() } else { 1000000 }
			from, to := jf_bounds(current.len, pstart, plimit)
			mut entries := []json2.Any{cap: to - from}
			for it in current[from..to] {
				mut e := app.jf_song(it).as_map()
				e['PlaylistItemId'] = jf_item_id(it.id)
				entries << e
			}
			return jf_send(mut ctx, jf_page(entries, current.len, pstart))
		}
		return jf_send(mut ctx, app.jf_playlist_summary(ps))
	}
	if a == 'items' {
		if id == 'counts' {
			song_cnt := app.fast_q_int('select count(*) from items where ${audio}', []) or { 0 }
			movie_cnt := app.fast_q_int("select count(*) from items where missing = 0 and kind = 'video'",
				[]) or { 0 }
			album_cnt := app.albums_mat_count('', [])
			artist_cnt := app.artists_mat_count('artist', '', [])
			mut o := map[string]json2.Any{}
			o['MovieCount'] = movie_cnt
			o['SeriesCount'] = 0
			o['EpisodeCount'] = 0
			o['ArtistCount'] = artist_cnt
			o['ProgramCount'] = 0
			o['TrailerCount'] = 0
			o['SongCount'] = song_cnt
			o['AlbumCount'] = album_cnt
			o['MusicVideoCount'] = 0
			o['BoxSetCount'] = 0
			o['BookCount'] = 0
			o['ItemCount'] = song_cnt + movie_cnt
			return jf_send(mut ctx, o)
		}
		if id == '' {
			return jf_send(mut ctx, app.jf_items(p, q))
		}
		if id == 'latest' {
			limit := if q['limit'].int() > 0 { q['limit'].int() } else { 20 }
			return jf_send(mut ctx, app.albums_mat(false, 'order by added_at desc limit ?', [
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

module main

import os
import crypto.md5
import crypto.sha256
import net.http
import veb
import x.json2

fn test_permissions_are_independent() {
	p := Principal{
		name:   'lyrics-bot'
		scopes: ['library:read', 'lyrics:write']
	}
	assert p.can('lyrics:write')
	assert !p.can('lyrics:read')
	assert !p.can('library:write')
	assert Principal{
		admin: true
	}.can('history:write')
	assert valid_scope('artwork:write')
	assert !valid_scope('artwork:delete')
	assert !valid_scope('admin')
}

fn test_subsonic_login() {
	assert sub_secret_ok('sesame', '', md5.hexhash('sesame' + 'salt'), 'salt')
	assert sub_secret_ok('sesame', 'sesame', '', '')
	assert sub_secret_ok('sesame', 'enc:736573616d65', '', '')
	assert !sub_secret_ok('sesame', 'wrong', '', '')
	assert !sub_secret_ok('sesame', '', '', '')
	assert !sub_secret_ok('', '', md5.hexhash('salt'), 'salt')
	assert !sub_secret_ok('', '', '', '')
}

fn test_writes_are_attributed_and_survive() {
	mut app := new_app(':memory:', '')!
	it := Item{
		path:  '/music/a.mp3'
		kind:  'audio'
		title: 'A'
	}
	sql app.db {
		insert it into Item
	}!
	bot := Principal{
		name:   'tagger'
		app_id: 7
	}
	app.set_item_field(bot, 1, 'genre', 'Jazz')!
	app.set_item_field(bot, 1, 'genre', 'Jazz')!
	app.set_item_field(bot, 1, 'year', '1957-03-01')!
	app.set_lyrics(bot, 1, 'la la')!
	app.set_item_field(bot, 1, 'path', '/etc/passwd') or {
		assert err.msg().contains('unknown field')
	}
	got := app.item(1)?
	assert got.genre == 'Jazz' && got.year == 1957 && got.path == '/music/a.mp3'
	log := sql app.db {
		select from Contribution order by id
	}!
	assert log.map(it.field) == ['genre', 'year', 'lyrics']
	assert log[0].app_name == 'tagger' && log[0].app_id == 7 && log[1].old_value == '0'

	pid := app.save_playlist(bot, 0, 'Mix', [1, 1])!
	assert app.playlist_items(pid).len == 2
	app.save_playlist(bot, pid, '', [1])!
	assert app.playlist_items(pid).len == 1 && app.playlist(pid)?.name == 'Mix'
}

fn test_jellyfin_ids() {
	assert jf_item_id(42).len == 32 && jf_row(jf_item_id(42), `1`) == 42
	assert jf_row(jf_playlist_id(7), `2`) == 7
	assert jf_row(jf_item_id(42), `2`) == 0
	assert jf_row(jf_album_id('A', 'B'), `1`) == 0
	assert jf_norm('0F000000-0000-0000-0000-000000000001') == jf_view
	assert jf_album_id('A', 'B') != jf_album_id('A', 'C')
}

fn test_xml_and_lyrics_shapes() {
	mut song := map[string]json2.Any{}
	song['id'] = '1'
	song['title'] = 'Tom & "Jerry"'
	mut album := map[string]json2.Any{}
	album['name'] = 'X'
	album['song'] = [json2.Any(song)]
	assert to_xml('album', album) == '<album name="X"><song id="1" title="Tom &amp; &quot;Jerry&quot;"></song></album>'

	lyr := structured_lyrics('[ar:Someone]\n[01:02.50]Hello\nplain').as_map()
	lines := (lyr['line'] or { panic('no lines') }).as_array()
	assert (lyr['synced'] or { json2.Any(false) }).bool()
	assert lines.len == 2
	assert (lines[0].as_map()['start'] or { json2.Any(0) }).int() == 62500
	assert album_id('AC/DC', 'Back in Black') != album_id('AC/DC', 'Back')
	assert decode_id(album_id('AC/DC', 'Back in Black')) == ['AC/DC', 'Back in Black']
}

fn test_native_mp3_tags() {
	mut title := [u8(1), 0xff, 0xfe]
	for c in [u8(`S`), `e`, 0xf1, `o`, `r`, `i`, `t`, `a`] {
		title << [c, u8(0)]
	}
	mut tag := 'APIC'.bytes()
	tag << [u8(0), 1, 0x86, 0xa0, 0, 0]
	tag << []u8{len: 100000, init: 0x55}
	tag << 'TIT2'.bytes()
	tag << [u8(0), 0, 0, u8(title.len), 0, 0]
	tag << title
	mut f := 'ID3'.bytes()
	f << [u8(3), 0, 0, u8(tag.len >> 21), u8(tag.len >> 14 & 0x7f), u8(tag.len >> 7 & 0x7f),
		u8(tag.len & 0x7f)]
	f << tag
	for _ in 0 .. 100 {
		f << [u8(0xff), 0xfb, 0x90, 0x00]
		f << []u8{len: 413}
	}
	path := os.join_path(os.temp_dir(), 'vlyra_tags_test.mp3')
	os.write_file_array(path, f)!
	defer {
		os.rm(path) or {}
	}
	t := native_tags(path, '.mp3') or { panic('no tags') }
	assert t.title == 'Señorita'
	assert t.duration == 2
	assert id3_genre('(52)') == 'Electronic'
}

fn test_rescan_keeps_edits() {
	dir := os.join_path(os.temp_dir(), 'vlyra_rescan_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(os.join_path(dir, 'media'))!
	defer {
		os.rmdir_all(dir) or {}
	}
	song := os.join_path(dir, 'media', 'a.mp3')
	v1 := fn (title string, artist string) []u8 {
		mut b := []u8{len: 4170}
		b << 'TAG'.bytes()
		b << title.bytes()
		b << []u8{len: 30 - title.len}
		b << artist.bytes()
		b << []u8{len: 95 - artist.len}
		return b
	}
	os.write_file_array(song, v1('One', 'Before'))!
	os.utime(song, 1000000000, 1000000000)!
	mut app := new_app(os.join_path(dir, 'vlyra.db'), dir)!
	app.set('media_dir', os.join_path(dir, 'media'))
	app.scan()
	id := app.items('', [])[0].id
	app.set_item_field(Principal{ name: 'admin', admin: true }, id, 'title', 'Mine')!
	os.write_file_array(song, v1('Two', 'After'))!
	os.utime(song, 1500000000, 1500000000)!
	app.scan()
	it := app.item(id) or { panic('gone') }
	assert it.title == 'Mine'
	assert it.artist == 'After'
	assert it.added_at == file_added(song)

	// Old databases stamped added_at with the scan time; the backfill corrects it.
	app.db.exec_param('update items set added_at = 2000000000 where id = ?', id.str())!
	app.set('added_from_files', '')
	app.scan()
	assert app.item(id)?.added_at == file_added(song)
}

fn test_albums_group_by_album_artist() {
	mut app := new_app(':memory:', os.temp_dir())!
	rows := [['Bad Bunny', 'Bad Bunny', 'YHLQMDLG'],
		['Bad Bunny & Anuel AA', 'Bad Bunny', 'YHLQMDLG'], ['Queen', 'Queen', 'Greatest Hits'],
		['ABBA', 'ABBA', 'Greatest Hits']]
	for i, r in rows {
		it := Item{
			path:         '/m/${i}.flac'
			kind:         'audio'
			title:        't'
			artist:       r[0]
			album_artist: r[1]
			album:        r[2]
		}
		sql app.db {
			insert it into Item
		}!
	}
	albums := app.album_rows('group by ${album_group} order by album, album_artist', [])
	assert albums.map('${it.artist}|${it.name}|${it.songs}') == [
		'ABBA|Greatest Hits|1',
		'Queen|Greatest Hits|1',
		'Bad Bunny|YHLQMDLG|2',
	]
	assert app.items('where ${album_match}', ['Bad Bunny', 'YHLQMDLG']).len == 2
}

fn test_album_ratings() {
	mut app := new_app(':memory:', os.temp_dir())!
	for i, album in ['Kind of Blue', 'Blue Train', 'Unrated'] {
		it := Item{
			path:         '/m/${i}.flac'
			kind:         'audio'
			title:        't'
			artist:       'A'
			album_artist: 'A'
			album:        album
		}
		sql app.db {
			insert it into Item
		}!
	}
	fan := Principal{
		name: 'player'
	}
	app.rate_album(fan, 'A', 'Kind of Blue', 5)!
	app.rate_album(fan, 'A', 'Blue Train', 2)!
	app.rate_album(fan, 'A', 'Blue Train', 4)!
	app.rate_album(fan, 'A', 'Blue Train', 4)!
	app.rate_album(fan, 'A', 'Unrated', 3)!
	app.rate_album(fan, 'A', 'Unrated', 0)!
	app.rate_album(fan, 'A', 'Kind of Blue', 6) or { assert err.msg().contains('0 to 5') }
	app.rate_album(fan, 'A', 'Nope', 3) or { assert err.msg() == 'no such album' }
	top := app.album_rows('group by ${album_group} having rating > 0 order by rating desc', [])
	assert top.map('${it.name}|${it.rating}') == ['Kind of Blue|5', 'Blue Train|4']
	assert app.album_rating('A', 'Unrated') == 0
	log := sql app.db {
		select from Contribution where field == 'rating' order by id
	}!
	assert log.map(it.new_value) == ['5', '2', '4', '3', '0']
	assert log[2].old_value == '2' && log[2].app_name == 'player' && log[2].entity == 'album'
}

fn test_scrobble_payloads() {
	assert lastfm_sig({
		'token':   'T'
		'api_key': 'K'
		'method':  'auth.getSession'
	}, 'S') == md5.hexhash('api_keyKmethodauth.getSessiontokenTS')
	listen := json2.decode[json2.Any](listen_json(Item{
		title:    'So What'
		artist:   'Miles Davis'
		album:    'Kind of Blue'
		duration: 545
	}, 1700000000))!.as_map()
	assert (listen['listen_type'] or { json2.Any('') }).str() == 'single'
	first := (listen['payload'] or { panic('no payload') }).as_array()[0].as_map()
	assert (first['listened_at'] or { json2.Any(0) }).i64() == 1700000000
	meta := (first['track_metadata'] or { panic('no metadata') }).as_map()
	assert (meta['artist_name'] or { json2.Any('') }).str() == 'Miles Davis'
	assert (meta['release_name'] or { json2.Any('') }).str() == 'Kind of Blue'
	mut app := new_app(':memory:', os.temp_dir())!
	it := Item{
		path:   '/m/a.flac'
		kind:   'audio'
		title:  'So What'
		artist: 'Miles Davis'
	}
	sql app.db {
		insert it into Item
	}!
	app.record_play(Principal{ name: 'player' }, 1, 0)!
	assert app.db.q_int('select count(*) from plays')! == 1
}

fn test_random_items() {
	mut app := new_app(':memory:', os.temp_dir())!
	for i in 0 .. 40 {
		it := Item{
			path:  '/m/${i}.mp3'
			kind:  if i % 10 == 0 { 'video' } else { 'audio' }
			title: 't${i}'
		}
		sql app.db {
			insert it into Item
		}!
	}
	got := app.random_items(10)
	assert got.len == 10
	assert got.all(it.kind == 'audio')
	mut seen := map[int]bool{}
	for it in got {
		assert it.id !in seen
		seen[it.id] = true
	}
	// More than the library holds: every audio track once, via the fallback.
	all := app.random_items(100)
	assert all.len == 36
	assert app.random_items(0).len == 0
}

fn test_caches_and_ratings_flag() {
	mut app := new_app(':memory:', os.temp_dir())!
	app.set('proto.subsonic', '0')
	assert app.get('proto.subsonic') == '0'
	app.db.exec_param_many('insert into settings (key, value) values (?, ?)', ['custom.key', 'v1'])!
	assert app.get('custom.key') == ''
	app.reload_settings()
	assert app.get('custom.key') == 'v1'

	tok := 'test-token-123'
	hash := sha256.hexhash(tok)
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'demo',
		hash,
		'subpass',
		'library:read ratings:read',
	])!
	app.reload_apps()
	found := app.cached_app_by_token(hash) or { panic('missing cached app by token') }
	assert found.name == 'demo'
	assert (app.cached_app_by_name('demo') or { panic('missing cached app by name') }).id == found.id

	p1 := app.principal_for(found)
	assert p1.name == 'demo' && p1.can('library:read')
	ls := app.live_last_seen(found.id, 0)
	assert ls > 0
	assert (app.db.q_int('select last_seen from apps where id = ${found.id}') or { 0 }) > 0
	// Second call within 60s must not touch SQLite last_seen.
	app.db.exec_param('update apps set last_seen = 123 where id = ?', found.id.str())!
	_ = app.principal_for(found)
	assert (app.db.q_int('select last_seen from apps where id = ${found.id}') or { 0 }) == 123

	app.db.exec_param('update apps set enabled = 0 where id = ?', found.id.str())!
	app.reload_apps()
	if _ := app.cached_app_by_token(hash) {
		assert false, 'disabled app should not remain in cache'
	}

	assert !app.has_ratings()
	it := Item{
		path:         '/m/r.flac'
		kind:         'audio'
		title:        'T'
		artist:       'A'
		album_artist: 'A'
		album:        'Al'
	}
	sql app.db {
		insert it into Item
	}!
	fan := Principal{
		name: 'demo'
	}
	app.rate_album(fan, 'A', 'Al', 4)!
	assert app.has_ratings()
	app.rate_album(fan, 'A', 'Al', 0)!
	assert !app.has_ratings()
}

fn test_jellyfin_album_artist_and_bounds() {
	mut app := new_app(':memory:', os.temp_dir())!
	assert app.server_id != '' && app.jf_server_id() == app.server_id
	from0, to0 := jf_bounds(10, 0, 3)
	assert from0 == 0 && to0 == 3
	from1, to1 := jf_bounds(10, 8, 5)
	assert from1 == 8 && to1 == 10
	from2, to2 := jf_bounds(10, 20, 5)
	assert from2 == 10 && to2 == 10
	from3, to3 := jf_bounds(10, -2, 0)
	assert from3 == 0 && to3 == 10

	for i, ar in ['Bad Bunny', 'Bad Bunny & Anuel AA'] {
		it := Item{
			path:         '/m/${i}.flac'
			kind:         'audio'
			title:        'Track ${i}'
			artist:       ar
			album_artist: 'Bad Bunny'
			album:        'YHLQMDLG'
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()
	song_map := app.jf_song(app.item(2) or { panic('missing item 2') }).as_map()
	assert (song_map['AlbumArtist'] or { json2.Any('') }).str() == 'Bad Bunny'
	assert (song_map['Artists'] or { json2.Any([]json2.Any{}) }).as_array()[0].str() == 'Bad Bunny & Anuel AA'
	aa_items := (song_map['AlbumArtists'] or { json2.Any([]json2.Any{}) }).as_array()
	assert (aa_items[0].as_map()['Name'] or { json2.Any('') }).str() == 'Bad Bunny'

	admin := Principal{
		name:  'admin'
		admin: true
	}
	albums_res := app.jf_items(admin, {
		'includeitemtypes': 'MusicAlbum'
		'startindex':       '0'
		'limit':            '1'
	}).as_map()
	assert (albums_res['TotalRecordCount'] or { json2.Any(0) }).int() == 1
	assert (albums_res['Items'] or { json2.Any([]json2.Any{}) }).as_array().len == 1

	aa_res := app.jf_items(admin, {
		'includeitemtypes': 'MusicArtist'
		'_albumartists':    '1'
	}).as_map()
	assert (aa_res['TotalRecordCount'] or { json2.Any(0) }).int() == 1
	aa_list := (aa_res['Items'] or { json2.Any([]json2.Any{}) }).as_array()
	assert (aa_list[0].as_map()['Name'] or { json2.Any('') }).str() == 'Bad Bunny'
}

fn test_subsonic_formpost_and_empty_search() {
	mut app := new_app(':memory:', os.temp_dir())!
	tok := 'tok-search'
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'client',
		sha256.hexhash(tok),
		'pass',
		'library:read ratings:read',
	])!
	app.reload_apps()
	for i in 0 .. 3 {
		it := Item{
			path:         '/m/s${i}.mp3'
			kind:         'audio'
			title:        'Song ${i}'
			artist:       'Artist ${i}'
			album_artist: 'Artist ${i}'
			album:        'Album ${i}'
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	mut ctx_ext := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getOpenSubsonicExtensions?u=client&p=pass&f=json'
			}
		}
	}
	app.subsonic(mut ctx_ext, 'getOpenSubsonicExtensions')
	ext_json := json2.decode[json2.Any](ctx_ext.res.body)!.as_map()
	ext_list := (ext_json['subsonic-response'] or { json2.Any(map[string]json2.Any{}) }).as_map()['openSubsonicExtensions'] or {
		json2.Any([]json2.Any{})
	}
	ext_names := ext_list.as_array().map((it.as_map()['name'] or { json2.Any('') }).str())
	assert 'formPost' in ext_names && 'songLyrics' in ext_names && 'vlyraTags' in ext_names

	mut ctx_s := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/search3?u=client&p=pass&f=json&query=&songCount=0&albumCount=2&artistCount=0'
			}
		}
	}
	app.subsonic(mut ctx_s, 'search3')
	s_json := json2.decode[json2.Any](ctx_s.res.body)!.as_map()
	sr3 := (s_json['subsonic-response'] or { json2.Any(map[string]json2.Any{}) }).as_map()['searchResult3'] or {
		json2.Any(map[string]json2.Any{})
	}
	sr3_m := sr3.as_map()
	assert (sr3_m['song'] or { json2.Any([]json2.Any{}) }).as_array().len == 0
	assert (sr3_m['album'] or { json2.Any([]json2.Any{}) }).as_array().len == 2
	assert (sr3_m['artist'] or { json2.Any([]json2.Any{}) }).as_array().len == 0

	mut h := http.new_header(key: .authorization, value: 'Bearer ${tok}')
	mut ctx_api := Context{
		Context: veb.Context{
			req:   http.Request{
				method: .get
				url:    '/api/v1/items?limit=2&offset=0'
				header: h
			}
			query: {
				'limit':  '2'
				'offset': '0'
			}
		}
	}
	app.list_items(mut ctx_api)
	page := json2.decode[json2.Any](ctx_api.res.body)!.as_map()
	assert (page['total'] or { json2.Any(0) }).int() == 3
	assert (page['items'] or { json2.Any([]json2.Any{}) }).as_array().len == 2
}

fn test_materialized_catalog_and_jf_lookups() {
	mut app := new_app(':memory:', os.temp_dir())!
	rows := [
		['Artist A', 'Artist A', 'First', 'Rock', '2001'],
		['Artist A feat. Guest', 'Artist A', 'First', 'Rock', '2001'],
		['Artist B', 'Artist B', 'Second', 'Jazz', '2010'],
	]
	for i, r in rows {
		it := Item{
			path:         '/m/cat_${i}.flac'
			kind:         'audio'
			title:        'T${i}'
			artist:       r[0]
			album_artist: r[1]
			album:        r[2]
			genre:        r[3]
			year:         r[4].int()
			duration:     120
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	als := app.albums_mat(false, 'order by album collate nocase', [])
	assert als.len == 2 && als[0].name == 'First' && als[0].songs == 2 && als[0].duration == 240
	assert app.artists_mat('artist', '', []).len == 3
	assert app.artists_mat('album_artist', '', []).len == 2
	genres := app.genres_mat()
	assert genres.map(it.name) == ['Jazz', 'Rock']

	al := app.find_album_by_jf_id(jf_album_id('Artist A', 'First')) or {
		panic('album jf_id lookup failed')
	}
	assert al.songs == 2
	ar := app.find_artist_by_jf_id(jf_artist_id('Artist A feat. Guest')) or {
		panic('artist jf_id lookup failed')
	}
	assert ar.name == 'Artist A feat. Guest'
	assert app.random_albums(false, 2).len == 2

	admin := Principal{
		name:  'admin'
		admin: true
	}
	app.set_item_field(admin, 3, 'genre', 'Electronic')!
	assert app.genres_mat().map(it.name) == ['Electronic', 'Rock']
}

fn test_fts5_search_and_diacritics() {
	mut app := new_app(':memory:', os.temp_dir())!
	assert fts_query('AC/DC') == '"AC"* "DC"*'
	assert fts_query('R&B') == '"R"* "B"*'
	assert fts_query('  ***  ') == ''

	items := [
		Item{
			path:         '/m/f1.mp3'
			kind:         'audio'
			title:        'Señorita'
			artist:       'Björk'
			album_artist: 'Björk'
			album:        'Vespertine'
			genre:        'Electronic'
			tags:         'chill'
		},
		Item{
			path:         '/m/f2.mp3'
			kind:         'audio'
			title:        'Back in Black'
			artist:       'AC/DC'
			album_artist: 'AC/DC'
			album:        'Back in Black'
			genre:        'senorita_genre'
			tags:         'senorita_tag'
		},
	]
	for it in items {
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	// Diacritic folding + column scoping: 'senorita' in title matches #1 only when scoped to title/artist/album.
	scoped := app.search_items_fts('senorita', 'title artist album', true, '', 20, 0)
	assert scoped.len == 1 && scoped[0].id == 1

	// Native /api/v1/items search covers tags/genre too -> matches both #1 and #2.
	unscoped := app.search_items_fts('senorita', '', false, '', 20, 0)
	assert unscoped.len == 2

	assert app.search_artists_fts('artist', 'bjork', 20, 0).len == 1
	assert app.search_artists_fts('artist', 'AC/DC', 20, 0).len == 1
	assert app.search_albums_fts(false, 'vespertine', '', 20, 0).len == 1

	// Punctuation-only query falls back safely to LIKE without FTS5 syntax errors.
	assert app.search_items_fts('&', 'title artist album', true, '', 20, 0).len == 0
}

fn test_real_play_stats_and_playlists_summary() {
	mut app := new_app(':memory:', os.temp_dir())!
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'player',
		sha256.hexhash('tok-play'),
		'pass',
		'library:read playlists:read history:write ratings:read',
	])!
	app.reload_apps()
	for i, yr in [1995, 2005, 2015] {
		it := Item{
			path:         '/m/p${i}.flac'
			kind:         'audio'
			title:        'Track ${i}'
			artist:       'Artist ${i}'
			album_artist: 'Artist ${i}'
			album:        'Album ${i}'
			year:         yr
			duration:     100 + i * 10
			added_at:     1700000000 + i64(i) * 100
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	p := Principal{
		name:   'player'
		app_id: 1
		scopes: ['library:read', 'playlists:read', 'history:write', 'ratings:read']
	}
	// Album 1 played twice (oldest timestamp 1700000500), Album 2 played once (newest timestamp 1700001000).
	app.record_play(p, 1, 1700000500)!
	app.record_play(p, 1, 1700000600)!
	app.record_play(p, 2, 1700001000)!

	it1 := app.item(1) or { panic('missing 1') }
	assert it1.play_count == 2 && it1.last_played == 1700000600
	s_map := song(it1).as_map()
	assert (s_map['playCount'] or { json2.Any(0) }).int() == 2
	assert (s_map['played'] or { json2.Any('') }).str() != ''

	jf_m := app.jf_song(it1).as_map()
	ud := (jf_m['UserData'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	assert (ud['PlayCount'] or { json2.Any(0) }).int() == 2
	assert (ud['Played'] or { json2.Any(false) }).bool()

	// Frequent -> Album 0 (2 plays) before Album 1 (1 play); Album 2 (0 plays) excluded.
	mut ctx_freq := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getAlbumList2?u=player&p=pass&f=json&type=frequent&size=10'
			}
		}
	}
	app.subsonic(mut ctx_freq, 'getAlbumList2')
	freq_json := json2.decode[json2.Any](ctx_freq.res.body)!.as_map()
	freq_als := ((freq_json['subsonic-response'] or { json2.Any(map[string]json2.Any{}) }).as_map()['albumList2'] or {
		json2.Any(map[string]json2.Any{})
	}).as_map()['album'] or { json2.Any([]json2.Any{}) }
	assert freq_als.as_array().map((it.as_map()['name'] or { json2.Any('') }).str()) == [
		'Album 0',
		'Album 1',
	]

	// Recent -> Album 1 (1700001000) before Album 0 (1700000600).
	mut ctx_rec := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getAlbumList2?u=player&p=pass&f=json&type=recent&size=10'
			}
		}
	}
	app.subsonic(mut ctx_rec, 'getAlbumList2')
	rec_json := json2.decode[json2.Any](ctx_rec.res.body)!.as_map()
	rec_als := ((rec_json['subsonic-response'] or { json2.Any(map[string]json2.Any{}) }).as_map()['albumList2'] or {
		json2.Any(map[string]json2.Any{})
	}).as_map()['album'] or { json2.Any([]json2.Any{}) }
	assert rec_als.as_array().map((it.as_map()['name'] or { json2.Any('') }).str()) == [
		'Album 1',
		'Album 0',
	]

	// byYear descending (fromYear=2020 & toYear=2000 -> 2015, 2005).
	mut ctx_yr := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getAlbumList2?u=player&p=pass&f=json&type=byYear&fromYear=2020&toYear=2000'
			}
		}
	}
	app.subsonic(mut ctx_yr, 'getAlbumList2')
	yr_json := json2.decode[json2.Any](ctx_yr.res.body)!.as_map()
	yr_als := ((yr_json['subsonic-response'] or { json2.Any(map[string]json2.Any{}) }).as_map()['albumList2'] or {
		json2.Any(map[string]json2.Any{})
	}).as_map()['album'] or { json2.Any([]json2.Any{}) }
	assert yr_als.as_array().map((it.as_map()['name'] or { json2.Any('') }).str()) == [
		'Album 2',
		'Album 1',
	]

	// Playlist summary single-JOIN check.
	pid := app.save_playlist(p, 0, 'Roadtrip', [2, 3])!
	sums := app.playlist_summaries()
	assert sums.len == 1 && sums[0].id == pid && sums[0].songs == 2 && sums[0].duration == 230
		&& sums[0].first_id == 2
}

fn test_jsonbuf_parity() {
	items := [
		Item{
			id:           1
			path:         '/music/"A"\\track\t1.mp3'
			kind:         'audio'
			title:        'Line1\nLine2\r\x07'
			artist:       'Björk'
			album:        'Vespertine'
			genre:        'Electronic'
			year:         2001
			track_no:     1
			duration:     245
			tags:         'chill'
			size:         1234567
			added_at:     1700000000
			missing:      false
			mtime:        0
			album_artist: 'Björk'
			play_count:   3
			last_played:  1700000500
		},
		Item{
			id:           2
			path:         '/music/2.flac'
			kind:         'audio'
			title:        'Plain'
			artist:       ''
			album:        ''
			genre:        ''
			year:         0
			track_no:     0
			duration:     180
			tags:         ''
			size:         999
			added_at:     1700000100
			missing:      true
			mtime:        -99
			album_artist: ''
			play_count:   0
			last_played:  0
		},
	]
	assert encode_item_page_json(&items, 42, 4) == json2.encode(ItemPage{
		items:  items
		total:  42
		rating: 4
	})

	albums := [
		Album{
			artist:      'Björk'
			name:        'Vespertine'
			songs:       10
			duration:    3200
			year:        2001
			genre:       'Electronic'
			first_id:    1
			added_at:    1700000000
			rating:      5
			play_count:  7
			last_played: 1700000900
		},
		Album{
			artist:      ''
			name:        'No Play'
			songs:       1
			duration:    180
			year:        0
			genre:       ''
			first_id:    2
			added_at:    1700000100
			rating:      0
			play_count:  0
			last_played: 0
		},
	]
	assert encode_albums_json(&albums) == json2.encode(albums)

	sub_al_json := encode_sub_album_list_json(&albums, true, false)
	sub_al_parsed := json2.decode[json2.Any](sub_al_json)!.as_map()
	al_list := ((sub_al_parsed['subsonic-response'] or { json2.Any('') }).as_map()['albumList2'] or {
		json2.Any('')
	}).as_map()['album'] or { json2.Any('') }
	arr := al_list.as_array()
	assert arr.len == 2
	m0 := arr[0].as_map()
	m1 := arr[1].as_map()
	assert (m0['isDir'] or { json2.Any(false) }).bool() == true
	assert (m0['userRating'] or { json2.Any(0) }).int() == 5
	assert (m0['playCount'] or { json2.Any(0) }).int() == 7
	assert (m0['played'] or { json2.Any('') }).str() != ''
	assert 'userRating' !in m1 && 'playCount' !in m1 && 'played' !in m1

	sub_det_parsed := json2.decode[json2.Any](encode_sub_album_detail_json(unsafe { &albums[0] },
		&items, true))!.as_map()
	det_al := ((sub_det_parsed['subsonic-response'] or { json2.Any('') }).as_map()['album'] or {
		json2.Any('')
	}).as_map()
	det_songs := (det_al['song'] or { json2.Any('') }).as_array()
	assert det_songs.len == 2
	ds0 := det_songs[0].as_map()
	ds1 := det_songs[1].as_map()
	assert (ds0['title'] or { json2.Any('') }).str() == 'Line1\nLine2\r\x07'
	assert (ds0['isDir'] or { json2.Any(true) }).bool() == false
	assert (ds0['isVideo'] or { json2.Any(true) }).bool() == false
	assert (ds0['playCount'] or { json2.Any(0) }).int() == 3
	assert 'played' in ds0 && 'playCount' !in ds1 && 'played' !in ds1

	artists := [
		ArtistRow{
			name:     'Björk'
			albums:   1
			first_id: 1
		},
		ArtistRow{
			name:     ''
			albums:   1
			first_id: 2
		},
	]
	ar_parsed := json2.decode[json2.Any](encode_sub_artists_json(&artists, true))!.as_map()
	idx_arr := ((ar_parsed['subsonic-response'] or { json2.Any('') }).as_map()['artists'] or {
		json2.Any('')
	}).as_map()['index'] or { json2.Any('') }
	assert idx_arr.as_array().len == 2
	assert (idx_arr.as_array()[0].as_map()['name'] or { json2.Any('') }).str() == 'B'
	assert (idx_arr.as_array()[1].as_map()['name'] or { json2.Any('') }).str() == '#'
}

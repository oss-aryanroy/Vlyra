module main

import compress.gzip
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

fn be16(n int) []u8 {
	return [u8(n >> 8), u8(n)]
}

fn be32(n int) []u8 {
	return [u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)]
}

fn mp4_box(typ string, body []u8) []u8 {
	mut out := []u8{cap: 8 + body.len}
	out << be32(8 + body.len)
	out << typ.bytes()
	out << body
	return out
}

fn make_tagged_mp3(title string, jpg []u8, png []u8) []u8 {
	mut tit2 := []u8{cap: 1 + title.len}
	tit2 << u8(3) // UTF-8
	tit2 << title.bytes()
	mut frames := []u8{}
	frames << 'TIT2'.bytes()
	frames << be32(tit2.len)
	frames << [u8(0), 0]
	frames << tit2

	// Non-front picture first (type 4 = back cover), then front cover (type 3) to verify preference.
	if png.len > 0 {
		mut apic_back := []u8{}
		apic_back << u8(0)
		apic_back << 'image/png'.bytes()
		apic_back << u8(0)
		apic_back << u8(4)
		apic_back << u8(0)
		apic_back << png
		frames << 'APIC'.bytes()
		frames << be32(apic_back.len)
		frames << [u8(0), 0]
		frames << apic_back
	}
	mut apic := []u8{}
	apic << u8(0)
	apic << 'image/jpeg'.bytes()
	apic << u8(0)
	apic << u8(3)
	apic << u8(0)
	apic << jpg
	frames << 'APIC'.bytes()
	frames << be32(apic.len)
	frames << [u8(0), 0]
	frames << apic

	// Pad beyond 64 KB so MP3 frame detection uses b.seg beyond head.
	pad := 70000
	tag_sz := frames.len + pad
	ss := [u8((tag_sz >> 21) & 0x7f), u8((tag_sz >> 14) & 0x7f), u8((tag_sz >> 7) & 0x7f),
		u8(tag_sz & 0x7f)]
	mut out := []u8{cap: 10 + tag_sz + 417 * 4}
	out << 'ID3'.bytes()
	out << [u8(3), 0, 0]
	out << ss
	out << frames
	out << []u8{len: pad}
	// MPEG-1 Layer III 128 kbps 44.1 kHz CBR frame (417 bytes).
	for _ in 0 .. 4 {
		out << [u8(0xff), 0xfb, 0x90, 0x00]
		out << []u8{len: 413}
	}
	return out
}

fn test_bin_buffered_tags_and_native_artwork() {
	dir := os.join_path(os.temp_dir(), 'vlyra_b3_tags_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}

	jpg := [u8(0xff), 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
		0x00, 0x01, 0xff, 0xd9]
	png := [u8(0x89), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48,
		0x44, 0x52]

	// 1. MP3 with ID3v2 > 64 KB + APIC preference.
	mp3_path := os.join_path(dir, 'track.mp3')
	mp3_bytes := make_tagged_mp3('Art Song', jpg, png)
	os.write_file_array(mp3_path, mp3_bytes)!
	fm := file_meta(mp3_path)
	assert fm.size == mp3_bytes.len && fm.mtime > 0 && fm.added_at > 0
	mt := native_tags_sized(mp3_path, '.mp3', fm.size) or { panic('mp3 tags missing') }
	assert mt.title == 'Art Song' && mt.duration == 0 // 417*4 bytes at 128 kbps is < 1s
	assert native_artwork(mp3_path, '.mp3') == jpg

	// 2. FLAC with 70 KB padding block before METADATA_BLOCK_PICTURE.
	flac_path := os.join_path(dir, 'track.flac')
	mut si := []u8{len: 34}
	// 44100 Hz (0x0ac44) + 441000 samples (10s)
	si[10] = 0x0a
	si[11] = 0xc4
	si[12] = 0x40
	si[15] = 0x06
	si[16] = 0xba
	si[17] = 0xa8
	mut vc := []u8{}
	vc << [u8(1), 0, 0, 0, `x`] // vendor 'x'
	vc << [u8(1), 0, 0, 0] // 1 comment
	c := 'TITLE=Flac Art'
	vc << [u8(c.len), 0, 0, 0]
	vc << c.bytes()
	mut pic := []u8{}
	pic << be32(3)
	pic << be32(9)
	pic << 'image/png'.bytes()
	pic << be32(0) // description
	pic << be32(1) // w
	pic << be32(1) // h
	pic << be32(24) // depth
	pic << be32(0) // colors
	pic << be32(png.len)
	pic << png
	pad_len := 70000
	mut flac := 'fLaC'.bytes()
	flac << [u8(0), 0, 0, u8(si.len)]
	flac << si
	flac << [u8(4), 0, 0, u8(vc.len)]
	flac << vc
	flac << [u8(1), u8(pad_len >> 16), u8(pad_len >> 8), u8(pad_len)]
	flac << []u8{len: pad_len}
	flac << [u8(0x86), 0, 0, u8(pic.len)]
	flac << pic
	os.write_file_array(flac_path, flac)!
	ft := native_tags_sized(flac_path, '.flac', i64(flac.len)) or { panic('flac tags missing') }
	assert ft.title == 'Flac Art' && ft.duration == 10
	assert native_artwork(flac_path, '.flac') == png

	// 3. MP4 with moov past 64 KB exercising load_window + covr extraction.
	m4a_path := os.join_path(dir, 'track.m4a')
	ftyp := mp4_box('ftyp', 'M4A '.bytes())
	mdat := mp4_box('mdat', []u8{len: 70000})
	mut mvhd := []u8{len: 20}
	mvhd[12] = 0x00
	mvhd[13] = 0x00
	mvhd[14] = 0x03
	mvhd[15] = 0xe8 // timescale = 1000
	mvhd[16] = 0x00
	mvhd[17] = 0x00
	mvhd[18] = 0x3a
	mvhd[19] = 0x98 // duration = 15000 (15s)
	mut nam_data := []u8{}
	nam_data << be32(1)
	nam_data << be32(0)
	nam_data << 'Mp4 Art'.bytes()
	nam_box := mp4_box('\xa9nam', mp4_box('data', nam_data))
	mut covr_data := []u8{}
	covr_data << be32(13)
	covr_data << be32(0)
	covr_data << jpg
	covr_box := mp4_box('covr', mp4_box('data', covr_data))
	mut ilst_body := []u8{}
	ilst_body << nam_box
	ilst_body << covr_box
	mut meta_body := [u8(0), 0, 0, 0]
	meta_body << mp4_box('ilst', ilst_body)
	udta := mp4_box('udta', mp4_box('meta', meta_body))
	mut moov_body := mp4_box('mvhd', mvhd)
	moov_body << udta
	moov := mp4_box('moov', moov_body)
	mut m4a := []u8{}
	m4a << ftyp
	m4a << mdat
	m4a << moov
	os.write_file_array(m4a_path, m4a)!
	qt := native_tags_sized(m4a_path, '.m4a', i64(m4a.len)) or { panic('mp4 tags missing') }
	assert qt.title == 'Mp4 Art' && qt.duration == 15
	assert native_artwork(m4a_path, '.m4a') == jpg
}

fn test_artwork_content_dedup_and_etag() {
	dir := os.join_path(os.temp_dir(), 'vlyra_b3_art_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(os.join_path(dir, 'art'))!
	defer {
		os.rmdir_all(dir) or {}
	}
	jpg := [u8(0xff), 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
		0x00, 0x01, 0xff, 0xd9]
	p1 := os.join_path(dir, 'a1.mp3')
	p2 := os.join_path(dir, 'a2.mp3')
	os.write_file_array(p1, make_tagged_mp3('T1', jpg, []u8{}))!
	os.write_file_array(p2, make_tagged_mp3('T2', jpg, []u8{}))!

	mut app := new_app(os.join_path(dir, 'v.db'), dir)!
	for p in [p1, p2] {
		it := Item{
			path:  p
			kind:  'audio'
			title: 'T'
		}
		sql app.db {
			insert it into Item
		}!
	}
	items := app.items('', [])
	assert items.len == 2

	mut ctx1 := Context{}
	send_artwork(mut ctx1, app, items[0], 0)
	assert ctx1.res.body.bytes() == jpg
	etag1 := ctx1.res.header.get(.etag) or { panic('missing etag') }
	assert etag1.starts_with('"h_') && etag1.ends_with('"')

	mut ctx2 := Context{}
	send_artwork(mut ctx2, app, items[1], 0)
	assert ctx2.res.body.bytes() == jpg
	etag2 := ctx2.res.header.get(.etag) or { panic('missing etag') }
	assert etag2 == etag1

	art_files := os.ls(os.join_path(dir, 'art'))!
	assert art_files.filter(it.starts_with('h_')).len == 1
	assert '${items[0].id}.h' in art_files && '${items[1].id}.h' in art_files

	mut ctx304 := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				header: http.new_header(key: .if_none_match, value: etag1)
			}
		}
	}
	send_artwork(mut ctx304, app, items[0], 0)
	assert ctx304.res.status() == .not_modified && ctx304.res.body == ''
}

fn test_scan_fast_directory_skip() {
	dir := os.join_path(os.temp_dir(), 'vlyra_b3_scanfast_test')
	os.rmdir_all(dir) or {}
	media := os.join_path(dir, 'media')
	sub1 := os.join_path(media, 'sub1')
	sub2 := os.join_path(media, 'sub2')
	os.mkdir_all(sub1)!
	os.mkdir_all(sub2)!
	defer {
		os.rmdir_all(dir) or {}
	}
	mp3_bytes := make_tagged_mp3('Fast1', [u8(0xff), 0xd8, 0xff, 0xd9], []u8{})
	s1 := os.join_path(sub1, 's1.mp3')
	os.write_file_array(s1, mp3_bytes)!
	os.utime(s1, 1000000000, 1000000000)!
	os.utime(sub2, 1000000000, 1000000000)!

	mut app := new_app(os.join_path(dir, 'v.db'), dir)!
	app.set('media_dir', media)
	app.scan()
	assert app.items('', []).len == 1

	// Clear items without touching directory mtimes: scan_fast() must skip cleanly.
	app.db.exec('delete from items')!
	app.scan_fast()
	assert app.items('', []).len == 0

	// Touch sub2 by adding a new file -> scan_fast() detects mtime change and rescans.
	s2 := os.join_path(sub2, 's2.mp3')
	os.write_file_array(s2, mp3_bytes)!
	os.utime(s2, 1000000000, 1000000000)!
	app.scan_fast()
	assert app.items('', []).len == 2
}

fn test_catalog_etag_and_gzip() {
	mut app := new_app(':memory:', os.temp_dir())!
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'player',
		sha256.hexhash('tok-b3'),
		'pass',
		'library:read playlists:read history:write ratings:read',
	])!
	app.reload_apps()
	for i in 0 .. 40 {
		it := Item{
			path:         '/m/g${i}.flac'
			kind:         'audio'
			title:        'Gzip Track Title Number ${i} Extra Padding Words'
			artist:       'Artist ${i % 10}'
			album_artist: 'Artist ${i % 10}'
			album:        'Album ${i % 8}'
			genre:        'Genre ${i % 4}'
			year:         2000 + (i % 10)
			duration:     200
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	// 1. /api/v1/items returns ETag + gzip when payload >= 1400 bytes.
	mut c_items := Context{
		Context: veb.Context{
			req:   http.Request{
				method: .get
				url:    '/api/v1/items?limit=100'
				header: http.new_header_from_map({
					.authorization:   'Bearer tok-b3'
					.accept_encoding: 'gzip, deflate'
				})
			}
			query: {
				'limit': '100'
			}
		}
	}
	app.list_items(mut c_items)
	assert (c_items.res.header.get(.content_encoding) or { '' }) == 'gzip'
	assert (c_items.res.header.get(.vary) or { '' }) == 'Accept-Encoding'
	etag := c_items.res.header.get(.etag) or { panic('missing items etag') }
	plain_items := gzip.decompress(c_items.res.body.bytes())!.bytestr()
	assert plain_items.contains('Gzip Track Title Number 0')

	// 2. Matching If-None-Match returns 304 Not Modified with empty body.
	mut c_304 := Context{
		Context: veb.Context{
			req:   http.Request{
				method: .get
				url:    '/api/v1/items?limit=100'
				header: http.new_header_from_map({
					.authorization: 'Bearer tok-b3'
					.if_none_match: etag
				})
			}
			query: {
				'limit': '100'
			}
		}
	}
	app.list_items(mut c_304)
	assert c_304.res.status() == .not_modified && c_304.res.body == ''

	// 3. Mutating catalog invalidates ETag.
	p := Principal{
		name:   'player'
		app_id: 1
		scopes: ['library:read', 'ratings:read']
	}
	app.rate_album(p, 'Artist 0', 'Album 0', 5)!
	mut c_new := Context{
		Context: veb.Context{
			req:   http.Request{
				method: .get
				url:    '/api/v1/items?limit=100'
				header: http.new_header_from_map({
					.authorization: 'Bearer tok-b3'
					.if_none_match: etag
				})
			}
			query: {
				'limit': '100'
			}
		}
	}
	app.list_items(mut c_new)
	assert c_new.res.status() != .not_modified
	assert (c_new.res.header.get(.etag) or { '' }) != etag

	// 4. Subsonic getArtists ETag + 304.
	mut c_sub := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getArtists?u=player&p=pass&f=json'
			}
		}
	}
	app.subsonic(mut c_sub, 'getArtists')
	sub_etag := c_sub.res.header.get(.etag) or { panic('missing sub etag') }
	mut c_sub_304 := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getArtists?u=player&p=pass&f=json'
				header: http.new_header(key: .if_none_match, value: sub_etag)
			}
		}
	}
	app.subsonic(mut c_sub_304, 'getArtists')
	assert c_sub_304.res.status() == .not_modified && c_sub_304.res.body == ''
}

fn id3_frame(id string, payload []u8) []u8 {
	mut out := []u8{cap: 10 + payload.len}
	out << id.bytes()
	out << be32(payload.len)
	out << [u8(0), 0]
	out << payload
	return out
}

fn test_rich_metadata_and_embedded_lyrics() {
	dir := os.join_path(os.temp_dir(), 'vlyra_b4_meta_test')
	os.rmdir_all(dir) or {}
	media := os.join_path(dir, 'media')
	os.mkdir_all(media)!
	defer {
		os.rmdir_all(dir) or {}
	}

	// 1. MP3 with TPOS, TXXX ReplayGain, USLT, SYLT (preferred), and valid CBR MPEG frames.
	mut frames := []u8{}
	frames << id3_frame('TIT2', [u8(3), `R`, `i`, `c`, `h`])
	mut tpos := [u8(3)]
	tpos << '2/2'.bytes()
	frames << id3_frame('TPOS', tpos)
	mut txxx := [u8(0)]
	txxx << 'REPLAYGAIN_TRACK_GAIN\x00-6.52 dB'.bytes()
	frames << id3_frame('TXXX', txxx)
	mut txxxp := [u8(0)]
	txxxp << 'REPLAYGAIN_TRACK_PEAK\x000.9876'.bytes()
	frames << id3_frame('TXXX', txxxp)
	mut uslt := [u8(3)]
	uslt << 'eng'.bytes()
	uslt << u8(0)
	uslt << 'Unsynced'.bytes()
	frames << id3_frame('USLT', uslt)
	mut sylt := [u8(3)]
	sylt << 'eng'.bytes()
	sylt << [u8(2), 1, 0] // ms, lyrics, empty descriptor
	sylt << 'First line'.bytes()
	sylt << u8(0)
	sylt << be32(1500)
	sylt << 'Second line'.bytes()
	sylt << u8(0)
	sylt << be32(5000)
	frames << id3_frame('SYLT', sylt)

	ss := [u8((frames.len >> 21) & 0x7f), u8((frames.len >> 14) & 0x7f),
		u8((frames.len >> 7) & 0x7f), u8(frames.len & 0x7f)]
	mut mp3 := 'ID3'.bytes()
	mp3 << [u8(3), 0, 0]
	mp3 << ss
	mp3 << frames
	for _ in 0 .. 4 {
		mp3 << [u8(0xff), 0xfb, 0x90, 0x00] // MPEG-1 L3 128kbps 44.1kHz stereo
		mp3 << []u8{len: 413}
	}
	mp3_path := os.join_path(dir, 'rich.mp3')
	os.write_file_array(mp3_path, mp3)!
	mt := native_tags_sized(mp3_path, '.mp3', i64(mp3.len)) or { panic('mp3 missing') }
	assert mt.disc == '2/2' && mt.bitrate == 128 && mt.sample_rate == 44100 && mt.channels == 2
	assert mt.rg_track_gain == -6.52 && mt.rg_track_peak == 0.9876
	assert mt.lyrics == '[00:01.50]First line\n[00:05.00]Second line'

	// 2. FLAC with STREAMINFO (44100Hz, 2ch, 16bit, 10s), DISCNUMBER, LYRICS, REPLAYGAIN_ALBUM_GAIN.
	mut si := []u8{len: 34}
	si[10] = 0x0a
	si[11] = 0xc4
	si[12] = 0x42 // sr=44100, channels=(1+1)=2, bps_hi=0
	si[13] = 0xf0 // bps_lo=15 -> bps=16
	si[15] = 0x06
	si[16] = 0xba
	si[17] = 0xa8
	mut vc := []u8{}
	vc << [u8(1), 0, 0, 0, `x`]
	comments := ['TITLE=Flac Rich', 'ARTIST=Singer', 'ALBUM=Record', 'DISCNUMBER=3',
		'REPLAYGAIN_ALBUM_GAIN=-4.25 dB', 'LYRICS=Line one\nLine two']
	vc << [u8(comments.len), 0, 0, 0]
	for cm in comments {
		vc << [u8(cm.len), 0, 0, 0]
		vc << cm.bytes()
	}
	mut flac := 'fLaC'.bytes()
	flac << [u8(0), 0, 0, u8(si.len)]
	flac << si
	flac << [u8(0x84), 0, 0, u8(vc.len)]
	flac << vc
	flac << []u8{len: 2000}
	flac_path := os.join_path(media, 'rich.flac')
	os.write_file_array(flac_path, flac)!
	os.utime(flac_path, 1000000000, 1000000000)!
	ft := native_tags_sized(flac_path, '.flac', i64(flac.len)) or { panic('flac missing') }
	assert ft.disc == '3' && ft.sample_rate == 44100 && ft.channels == 2 && ft.bit_depth == 16
	assert ft.bitrate > 0 && ft.rg_album_gain == -4.25 && ft.lyrics == 'Line one\nLine two'

	// 3. MP4 with stsd (alac 48kHz 2ch 24bit), disk=2, ©lyr, ---- replaygain_track_gain.
	mut stsd := []u8{len: 48}
	stsd[7] = 1 // entry_count=1
	copy(mut stsd[12..16], 'alac'.bytes())
	stsd[32] = 0
	stsd[33] = 2 // channels
	stsd[34] = 0
	stsd[35] = 24 // sample size
	stsd[40] = 0xbb
	stsd[41] = 0x80 // 48000 Hz
	stsd_box := mp4_box('stsd', stsd)
	trak := mp4_box('trak', mp4_box('mdia', mp4_box('minf', mp4_box('stbl', stsd_box))))
	mut mvhd := []u8{len: 20}
	copy(mut mvhd[12..16], be32(1000))
	copy(mut mvhd[16..20], be32(10000))
	mut disk_data := []u8{}
	disk_data << be32(0)
	disk_data << be32(0)
	disk_data << [u8(0), 0, 0, 2, 0, 2, 0, 0]
	mut lyr_data := []u8{}
	lyr_data << be32(1)
	lyr_data << be32(0)
	lyr_data << 'Mp4 lyrics'.bytes()
	mut ff_name := [u8(0), 0, 0, 0]
	ff_name << 'replaygain_track_gain'.bytes()
	mut ff_val := [u8(0), 0, 0, 0, 0, 0, 0, 0]
	ff_val << '-3.10 dB'.bytes()
	mut ff_body := mp4_box('name', ff_name)
	ff_body << mp4_box('data', ff_val)
	ff_box := mp4_box('----', ff_body)
	mut ilst := []u8{}
	ilst << mp4_box('disk', mp4_box('data', disk_data))
	ilst << mp4_box('\xa9lyr', mp4_box('data', lyr_data))
	ilst << ff_box
	mut meta := [u8(0), 0, 0, 0]
	meta << mp4_box('ilst', ilst)
	mut moov_body := mp4_box('mvhd', mvhd)
	moov_body << trak
	moov_body << mp4_box('udta', mp4_box('meta', meta))
	mut m4a := mp4_box('ftyp', 'M4A '.bytes())
	m4a << mp4_box('mdat', []u8{len: 4000})
	m4a << mp4_box('moov', moov_body)
	m4a_path := os.join_path(dir, 'rich.m4a')
	os.write_file_array(m4a_path, m4a)!
	qt := native_tags_sized(m4a_path, '.m4a', i64(m4a.len)) or { panic('mp4 missing') }
	assert qt.disc == '2' && qt.channels == 2 && qt.bit_depth == 24 && qt.sample_rate == 48000
	assert qt.bitrate > 0 && qt.rg_track_gain == -3.1 && qt.lyrics == 'Mp4 lyrics'

	// 4. Scan saves embedded lyrics cleanly, and rescan never clobbers user-edited lyrics + float json parity.
	mut app := new_app(os.join_path(dir, 'v.db'), dir)!
	app.set('media_dir', media)
	app.scan()
	got := app.items('', [])[0]
	assert got.disc_no == 3 && got.rg_album_gain == -4.25
	assert app.lyrics(got.id) == 'Line one\nLine two'
	assert encode_item_page_json(&[got], 1, 0) == json2.encode(ItemPage{
		items:  [got]
		total:  1
		rating: 0
	})

	app.set_lyrics(Principal{ name: 'admin', admin: true }, got.id, 'User Edited Lyrics')!
	os.utime(flac_path, 1500000000, 1500000000)!
	app.scan()
	assert app.lyrics(got.id) == 'User Edited Lyrics'
}

fn test_subsonic_star_playqueue_and_apikey() {
	mut app := new_app(':memory:', os.temp_dir())!
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'apiuser',
		sha256.hexhash('key-b4'),
		'pass',
		'library:read ratings:read ratings:write history:write',
	])!
	app.reload_apps()
	for i in 1 .. 4 {
		it := Item{
			path:          '/m/s${i}.flac'
			kind:          'audio'
			title:         'Star ${i}'
			artist:        'Star Artist'
			album_artist:  'Star Artist'
			album:         'Star Album'
			track_no:      i
			disc_no:       2
			duration:      180
			bitrate:       950
			sample_rate:   44100
			bit_depth:     16
			channels:      2
			rg_track_gain: -5.5
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	// Bad apiKey -> code 44.
	mut c_bad := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/ping?apiKey=wrong&f=json'
			}
		}
	}
	app.subsonic(mut c_bad, 'ping')
	bad_m := json2.decode[json2.Any](c_bad.res.body)!.as_map()['subsonic-response'] or {
		json2.Any('')
	}.as_map()
	assert ((bad_m['error'] or { json2.Any('') }).as_map()['code'] or { json2.Any(0) }).int() == 44

	// Extensions advertise apiKeyAuthentication + apiKey auth succeeds.
	mut c_ext := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getOpenSubsonicExtensions?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_ext, 'getOpenSubsonicExtensions')
	assert c_ext.res.body.contains('apiKeyAuthentication')

	// Star item 1, album, artist.
	al_id := album_id('Star Artist', 'Star Album')
	ar_id := artist_id('Star Artist')
	mut c_star := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/star?apiKey=key-b4&f=json&id=1&albumId=${al_id}&artistId=${ar_id}'
			}
		}
	}
	app.subsonic(mut c_star, 'star')
	assert c_star.res.body.contains('"status":"ok"')

	// getStarred2 + getAlbumList2?type=starred.
	mut c_gs := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getStarred2?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_gs, 'getStarred2')
	gs := (json2.decode[json2.Any](c_gs.res.body)!.as_map()['subsonic-response'] or { json2.Any('') }).as_map()['starred2'] or {
		json2.Any('')
	}.as_map()
	gs_songs := (gs['song'] or { json2.Any([]json2.Any{}) }).as_array()
	assert gs_songs.len == 1
	s0 := gs_songs[0].as_map()
	assert (s0['discNumber'] or { json2.Any(0) }).int() == 2
		&& (s0['bitRate'] or { json2.Any(0) }).int() == 950
		&& (s0['samplingRate'] or { json2.Any(0) }).int() == 44100
		&& 'replayGain' in s0 && 'starred' in s0
	assert (gs['album'] or { json2.Any([]json2.Any{}) }).as_array().len == 1
	assert (gs['artist'] or { json2.Any([]json2.Any{}) }).as_array().len == 1

	mut c_gal := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getAlbumList2?apiKey=key-b4&f=json&type=starred'
			}
		}
	}
	app.subsonic(mut c_gal, 'getAlbumList2')
	assert c_gal.res.body.contains('Star Album')

	// Unstar song 1 -> gone from starred songs.
	mut c_us := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/unstar?apiKey=key-b4&f=json&id=1'
			}
		}
	}
	app.subsonic(mut c_us, 'unstar')
	mut c_gs2 := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getStarred2?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_gs2, 'getStarred2')
	gs2 := (json2.decode[json2.Any](c_gs2.res.body)!.as_map()['subsonic-response'] or {
		json2.Any('')
	}).as_map()['starred2'] or { json2.Any('') }.as_map()
	assert (gs2['song'] or { json2.Any([]json2.Any{}) }).as_array().len == 0

	// savePlayQueue & getPlayQueue + clear.
	mut c_spq := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/savePlayQueue?apiKey=key-b4&f=json&id=3&id=1&current=1&position=42000'
			}
		}
	}
	app.subsonic(mut c_spq, 'savePlayQueue')
	mut c_gpq := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getPlayQueue?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_gpq, 'getPlayQueue')
	pq := (json2.decode[json2.Any](c_gpq.res.body)!.as_map()['subsonic-response'] or {
		json2.Any('')
	}).as_map()['playQueue'] or { json2.Any('') }.as_map()
	assert (pq['current'] or { json2.Any('') }).str() == '1'
		&& (pq['position'] or { json2.Any(0) }).i64() == 42000
	entries := (pq['entry'] or { json2.Any([]json2.Any{}) }).as_array()
	assert entries.len == 2 && (entries[0].as_map()['id'] or { json2.Any('') }).str() == '3'
		&& (entries[1].as_map()['id'] or { json2.Any('') }).str() == '1'

	mut c_cpq := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/savePlayQueue?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_cpq, 'savePlayQueue')
	mut c_gpq2 := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/rest/getPlayQueue?apiKey=key-b4&f=json'
			}
		}
	}
	app.subsonic(mut c_gpq2, 'getPlayQueue')
	assert !c_gpq2.res.body.contains('playQueue')
}

fn test_jellyfin_search_hints_counts_and_favorites() {
	mut app := new_app(':memory:', os.temp_dir())!
	app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, 1700000000, 0)', [
		'jfuser',
		sha256.hexhash('jf-tok'),
		'',
		'library:read ratings:read ratings:write',
	])!
	app.reload_apps()
	it := Item{
		path:          '/m/v1.flac'
		kind:          'audio'
		title:         'Vessel Theme'
		artist:        'Harbour'
		album_artist:  'Harbour'
		album:         'Vessel Album'
		disc_no:       2
		bitrate:       800
		sample_rate:   48000
		bit_depth:     24
		channels:      2
		rg_track_gain: -2.5
		duration:      200
	}
	sql app.db {
		insert it into Item
	}!
	app.rebuild_catalog()

	mut c_cnt := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/Items/Counts?api_key=jf-tok'
			}
		}
	}
	app.jellyfin(mut c_cnt, 'Items/Counts')
	cnt := json2.decode[json2.Any](c_cnt.res.body)!.as_map()
	assert (cnt['SongCount'] or { json2.Any(0) }).int() == 1
		&& (cnt['AlbumCount'] or { json2.Any(0) }).int() == 1
		&& (cnt['ArtistCount'] or { json2.Any(0) }).int() == 1

	mut c_hints := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/Search/Hints?searchTerm=Vessel&api_key=jf-tok'
			}
		}
	}
	app.jellyfin(mut c_hints, 'Search/Hints')
	hints := (json2.decode[json2.Any](c_hints.res.body)!.as_map()['SearchHints'] or {
		json2.Any([]json2.Any{})
	}).as_array()
	assert hints.len >= 2

	jid := jf_item_id(1)
	mut c_fav := Context{
		Context: veb.Context{
			req: http.Request{
				method: .post
				url:    '/Users/u/FavoriteItems/${jid}?api_key=jf-tok'
			}
		}
	}
	app.jellyfin(mut c_fav, 'Users/u/FavoriteItems/${jid}')
	assert (json2.decode[json2.Any](c_fav.res.body)!.as_map()['IsFavorite'] or { json2.Any(false) }).bool()

	mut c_list := Context{
		Context: veb.Context{
			req: http.Request{
				method: .get
				url:    '/Items?Filters=IsFavorite&IncludeItemTypes=Audio&api_key=jf-tok'
			}
		}
	}
	app.jellyfin(mut c_list, 'Items')
	fav_items := (json2.decode[json2.Any](c_list.res.body)!.as_map()['Items'] or {
		json2.Any([]json2.Any{})
	}).as_array()
	assert fav_items.len == 1
	assert (fav_items[0].as_map()['ParentIndexNumber'] or { json2.Any(0) }).int() == 2

	mut c_unfav := Context{
		Context: veb.Context{
			req: http.Request{
				method: .delete
				url:    '/Users/u/FavoriteItems/${jid}?api_key=jf-tok'
			}
		}
	}
	app.jellyfin(mut c_unfav, 'Users/u/FavoriteItems/${jid}')
	assert !(json2.decode[json2.Any](c_unfav.res.body)!.as_map()['IsFavorite'] or { json2.Any(true) }).bool()
}

fn test_sqlite_stmt_cache_pool() {
	dir := os.join_path(os.temp_dir(), 'vlyra_b4_pool_test')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	mut app := new_app(os.join_path(dir, 'v.db'), dir)!
	assert app.read_pool.len >= 4
	for i in 1 .. 5 {
		it := Item{
			path:         '/m/p${i}.flac'
			kind:         'audio'
			title:        'Pool ${i}'
			artist:       'Pool Artist'
			album_artist: 'Pool Artist'
			album:        'Pool Album ${i % 2}'
			genre:        'Jazz'
			track_no:     i
			disc_no:      1
			duration:     120
			bitrate:      900
			sample_rate:  44100
			bit_depth:    16
			channels:     2
		}
		sql app.db {
			insert it into Item
		}!
	}
	app.rebuild_catalog()

	// Run enough times to exercise statement cache hits across all connections in read_pool.
	for _ in 0 .. 20 {
		als := app.albums_mat(false, 'order by album collate nocase', [])
		assert als.len == 2
		ars := app.artists_mat('artist', 'order by name collate nocase', [])
		assert ars.len == 1
		grs := app.genres_mat()
		assert grs.len == 1 && grs[0].songs == 4
		its := app.items('where ${audio} order by disc_no, track_no', [])
		assert its.len == 4 && its[0].bitrate == 900
		one := app.item(1) or { panic('item 1 missing') }
		assert one.sample_rate == 44100 && one.bit_depth == 16
	}
	mut cached := 0
	for rc in app.read_pool {
		cached += rc.stmts.len
	}
	assert cached >= app.read_pool.len
}

module main

import os
import crypto.md5
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

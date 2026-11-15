module main

import db.sqlite
import rand
import time

@[table: 'items']
pub struct Item {
pub mut:
	id           int    @[primary; sql: serial]
	path         string @[unique]
	kind         string
	title        string
	artist       string
	album        string
	genre        string
	year         int
	track_no     int
	duration     int
	tags         string
	size         i64
	added_at     i64
	missing      bool
	mtime        i64
	album_artist string
}

@[table: 'apps']
pub struct ClientApp {
pub mut:
	id         int    @[primary; sql: serial]
	name       string @[unique]
	token_hash string @[unique]
	// Readable, as Subsonic's salted-md5 login needs it. Only works on /rest; empty = no Subsonic sign-in.
	subsonic_password string
	scopes            string
	enabled           bool
	created_at        i64
	last_seen         i64
}

@[table: 'contributions']
pub struct Contribution {
pub mut:
	id        int @[primary; sql: serial]
	app_id    int
	app_name  string
	entity    string
	entity_id int
	label     string
	field     string
	old_value string
	new_value string
	at        i64
}

@[table: 'playlists']
pub struct Playlist {
pub mut:
	id         int @[primary; sql: serial]
	name       string
	owner      string
	created_at i64
}

@[table: 'plays']
pub struct Play {
pub mut:
	id       int @[primary; sql: serial]
	item_id  int
	app_name string
	at       i64
}

const item_fields = ['title', 'artist', 'album_artist', 'album', 'genre', 'year', 'track_no', 'tags']
const item_cols = 'id, path, kind, title, artist, album, genre, year, track_no, duration, tags, size, added_at, missing, album_artist'

fn (mut app App) migrate() ! {
	sql app.db {
		create table Item
		create table ClientApp
		create table Contribution
		create table Playlist
		create table Play
	}!
	for q in [
		'create table if not exists settings (key text primary key, value text not null)',
		'create table if not exists sessions (token text primary key, expires integer not null)',
		'create table if not exists lyrics (item_id integer primary key, text text not null)',
		'create table if not exists playlist_items (playlist_id integer not null, pos integer not null, item_id integer not null, primary key (playlist_id, pos))',
		'create table if not exists album_ratings (album_artist text not null, album text not null, rating integer not null, primary key (album_artist, album))',
	] {
		app.db.exec(q)!
	}
	app.db.exec('alter table items add column mtime integer not null default 0') or {}
	app.db.exec("alter table items add column album_artist text not null default ''") or {}
	app.db.exec("update items set album_artist = artist where album_artist = ''")!
	// Cover the album and artist aggregates, so grouping reads the index alone.
	app.db.exec('create index if not exists items_album on items (album_artist, album, missing, kind, duration, year, genre, added_at)')!
	app.db.exec('create index if not exists items_artist on items (artist, album, missing, kind)')!
}

fn (app &App) get(key string) string {
	rows := app.db.exec_param('select value from settings where key = ?', key) or { return '' }
	return if rows.len > 0 { rows[0].vals[0] } else { '' }
}

fn (app &App) set(key string, value string) {
	app.db.exec_param_many('insert into settings (key, value) values (?, ?) on conflict(key) do update set value = excluded.value', [
		key,
		value,
	]) or { eprintln('settings: ${err}') }
}

fn item_from(r sqlite.Row) Item {
	v := r.vals
	return Item{
		id:           v[0].int()
		path:         v[1]
		kind:         v[2]
		title:        v[3]
		artist:       v[4]
		album:        v[5]
		genre:        v[6]
		year:         v[7].int()
		track_no:     v[8].int()
		duration:     v[9].int()
		tags:         v[10]
		size:         v[11].i64()
		added_at:     v[12].i64()
		missing:      v[13] == '1'
		album_artist: v[14]
	}
}

// `tail` must be a code constant; user input only ever goes in `params`.
fn (app &App) items(tail string, params []string) []Item {
	rows := app.reader().exec_param_many('select ${item_cols} from items ${tail}', params) or {
		eprintln('items: ${err}')
		return []
	}
	return rows.map(item_from(it))
}

// Ids are drawn here, not with ORDER BY random(): SQLite's random() takes a
// process-wide lock per row, which stalls parallel requests.
fn (app &App) random_items(n int) []Item {
	top := app.reader().q_int('select max(id) from items') or { 0 }
	if top <= 0 || n <= 0 {
		return []
	}
	mut ids := []string{cap: n * 3}
	for _ in 0 .. n * 3 {
		ids << (rand.intn(top) or { 0 } + 1).str()
	}
	mut found := app.items('where ${audio} and id in (${ids.map('?').join(',')})', ids)
	if found.len < n {
		found = app.items('where ${audio} order by random() limit ?', [
			n.str(),
		])
	}
	rand.shuffle(mut found) or {}
	return found[..if found.len < n {
		found.len
	} else {
		n
	}]
}

fn (app &App) item(id int) ?Item {
	found := app.items('where id = ?', [id.str()])
	return if found.len > 0 { found[0] } else { none }
}

pub struct Album {
pub:
	artist   string
	name     string
	songs    int
	duration int
	year     int
	genre    string
	first_id int
	added_at i64
	rating   int
}

pub struct ArtistRow {
pub:
	name     string
	albums   int
	first_id int
}

const audio = "missing = 0 and kind = 'audio'"

const album_group = 'album_artist, album'
const album_match = 'album_artist = ? and album = ?'

// `tail` must be a code constant.
fn (app &App) album_rows(tail string, params []string) []Album {
	rows := app.reader().exec_param_many('select album_artist, album, count(*), sum(duration), max(year), max(genre), min(id), max(added_at), coalesce((select rating from album_ratings r where r.album_artist = items.album_artist and r.album = items.album), 0) as rating from items where ${audio} ${tail}',
		params) or {
		eprintln('albums: ${err}')
		return []
	}
	return rows.map(Album{
		artist:   it.vals[0]
		name:     it.vals[1]
		songs:    it.vals[2].int()
		duration: it.vals[3].int()
		year:     it.vals[4].int()
		genre:    it.vals[5]
		first_id: it.vals[6].int()
		added_at: it.vals[7].i64()
		rating:   it.vals[8].int()
	})
}

// `tail` must be a code constant.
fn (app &App) artist_rows(tail string, params []string) []ArtistRow {
	rows := app.reader().exec_param_many('select artist, count(distinct album), min(id) from items where ${audio} ${tail}',
		params) or {
		eprintln('artists: ${err}')
		return []
	}
	return rows.map(ArtistRow{
		name:     it.vals[0]
		albums:   it.vals[1].int()
		first_id: it.vals[2].int()
	})
}

fn (mut app App) log(p Principal, entity string, entity_id int, label string, field string, old string, new string) {
	c := Contribution{
		app_id:    p.app_id
		app_name:  p.name
		entity:    entity
		entity_id: entity_id
		label:     label
		field:     field
		old_value: old
		new_value: new
		at:        time.now().unix()
	}
	sql app.db {
		insert c into Contribution
	} or {
		eprintln('log: ${err}')
		0
	}
}

fn (mut app App) set_item_field(p Principal, id int, field string, value string) ! {
	if field !in item_fields {
		return error('unknown field "${field}"')
	}
	it := app.item(id) or { return error('no such item') }
	// `field` is allowlisted above, so it is safe as a column name.
	old := app.db.exec_param('select ${field} from items where id = ?', id.str())![0].vals[0]
	new := if field in ['year', 'track_no'] { value.int().str() } else { value.trim_space() }
	if old == new {
		return
	}
	app.db.exec_param_many('update items set ${field} = ? where id = ?', [new, id.str()])!
	app.log(p, 'item', id, it.title, field, old, new)
}

fn (app &App) lyrics(id int) string {
	rows := app.db.exec_param('select text from lyrics where item_id = ?', id.str()) or {
		return ''
	}
	return if rows.len > 0 { rows[0].vals[0] } else { '' }
}

fn (mut app App) set_lyrics(p Principal, id int, text string) ! {
	it := app.item(id) or { return error('no such item') }
	old := app.lyrics(id)
	if old == text {
		return
	}
	app.db.exec_param_many('insert into lyrics (item_id, text) values (?, ?) on conflict(item_id) do update set text = excluded.text', [
		id.str(),
		text,
	])!
	app.log(p, 'item', id, it.title, 'lyrics', old, text)
}

fn (mut app App) record_play(p Principal, id int, at i64) ! {
	it := app.item(id) or { return error('no such item') }
	play := Play{
		item_id:  id
		app_name: p.name
		at:       if at > 0 { at } else { time.now().unix() }
	}
	sql app.db {
		insert play into Play
	}!
	spawn app.forward_play(it, play.at)
}

fn (app &App) album_rating(artist string, album string) int {
	rows := app.db.exec_param_many('select rating from album_ratings where ${album_match}', [
		artist,
		album,
	]) or { return 0 }
	return if rows.len > 0 { rows[0].vals[0].int() } else { 0 }
}

fn (mut app App) rate_album(p Principal, artist string, album string, rating int) ! {
	if rating < 0 || rating > 5 {
		return error('rating must be 0 to 5')
	}
	if app.items('where ${audio} and ${album_match} limit 1', [artist, album]).len == 0 {
		return error('no such album')
	}
	old := app.album_rating(artist, album)
	if old == rating {
		return
	}
	if rating == 0 {
		app.db.exec_param_many('delete from album_ratings where ${album_match}', [
			artist,
			album,
		])!
	} else {
		app.db.exec_param_many('insert into album_ratings (album_artist, album, rating) values (?, ?, ?) on conflict(album_artist, album) do update set rating = excluded.rating', [
			artist,
			album,
			rating.str(),
		])!
	}
	app.log(p, 'album', 0, or_unknown(album, 'Album'), 'rating', old.str(), rating.str())
}

fn (app &App) playlist(id int) ?Playlist {
	found := sql app.db {
		select from Playlist where id == id
	} or { return none }
	return if found.len > 0 { found[0] } else { none }
}

fn (app &App) playlist_items(id int) []Item {
	return app.items('join playlist_items pi on pi.item_id = items.id where pi.playlist_id = ? order by pi.pos', [
		id.str(),
	])
}

fn (mut app App) save_playlist(p Principal, id int, name string, item_ids []int) !int {
	mut pid := id
	clean := name.trim_space()
	if pid == 0 {
		if clean == '' {
			return error('playlist needs a name')
		}
		// `returning`, not last_insert_rowid(): the connection is shared between threads.
		pid = app.db.exec_param_many('insert into playlists (name, owner, created_at) values (?, ?, ?) returning id', [
			clean,
			p.name,
			time.now().unix().str(),
		])![0].vals[0].int()
		app.log(p, 'playlist', pid, clean, 'created', '', '${item_ids.len} items')
	} else {
		old := app.playlist(pid) or { return error('no such playlist') }
		if clean != '' && clean != old.name {
			app.db.exec_param_many('update playlists set name = ? where id = ?', [
				clean,
				pid.str(),
			])!
			app.log(p, 'playlist', pid, clean, 'name', old.name, clean)
		}
		before := app.playlist_items(pid).map(it.id)
		if before != item_ids {
			app.log(p, 'playlist', pid, if clean != '' { clean } else { old.name }, 'items',
				'${before.len} items', '${item_ids.len} items')
		}
	}
	app.db.exec_param('delete from playlist_items where playlist_id = ?', pid.str())!
	for pos, item_id in item_ids {
		app.db.exec_param_many('insert into playlist_items (playlist_id, pos, item_id) values (?, ?, ?)', [
			pid.str(),
			pos.str(),
			item_id.str(),
		])!
	}
	return pid
}

fn (mut app App) delete_playlist(p Principal, id int) ! {
	old := app.playlist(id) or { return error('no such playlist') }
	app.db.exec_param('delete from playlist_items where playlist_id = ?', id.str())!
	app.db.exec_param('delete from playlists where id = ?', id.str())!
	app.log(p, 'playlist', id, old.name, 'deleted', old.name, '')
}

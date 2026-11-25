module main

import db.sqlite
import rand
import sync.stdatomic
import time

fn (app &App) catalog_version() u64 {
	return stdatomic.load_u64(&app.catalog_gen)
}

fn (app &App) bump_catalog_gen() {
	stdatomic.add_u64(&app.catalog_gen, 1)
}

@[table: 'items']
pub struct Item {
pub mut:
	id            int    @[primary; sql: serial]
	path          string @[unique]
	kind          string
	title         string
	artist        string
	album         string
	genre         string
	year          int
	track_no      int
	duration      int
	tags          string
	size          i64
	added_at      i64
	missing       bool
	mtime         i64
	album_artist  string
	play_count    int
	last_played   i64
	disc_no       int
	bitrate       int
	sample_rate   int
	bit_depth     int
	channels      int
	rg_track_gain f64
	rg_album_gain f64
	rg_track_peak f64
	rg_album_peak f64
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

const item_fields = ['title', 'artist', 'album_artist', 'album', 'genre', 'year', 'track_no',
	'disc_no', 'tags']
const item_cols = 'id, path, kind, title, artist, album, genre, year, track_no, duration, tags, size, added_at, album_artist, play_count, last_played, disc_no, bitrate, sample_rate, bit_depth, channels, rg_track_gain, rg_album_gain, rg_track_peak, rg_album_peak'
const item_cols_i = 'i.id, i.path, i.kind, i.title, i.artist, i.album, i.genre, i.year, i.track_no, i.duration, i.tags, i.size, i.added_at, i.album_artist, i.play_count, i.last_played, i.disc_no, i.bitrate, i.sample_rate, i.bit_depth, i.channels, i.rg_track_gain, i.rg_album_gain, i.rg_track_peak, i.rg_album_peak'

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
		'create table if not exists stars (kind text not null, key text not null, at integer not null, primary key (kind, key))',
		'create table if not exists play_queue (id integer primary key check (id = 1), item_ids text not null, current_id integer not null, position_ms integer not null, changed_by text not null, updated_at integer not null)',
		'create table if not exists albums (id integer primary key, album_artist text not null, album text not null, songs integer not null, duration integer not null, year integer not null, genre text not null, first_id integer not null, added_at integer not null, rating integer not null default 0, play_count integer not null default 0, last_played integer not null default 0, jf_id text not null, unique (album_artist, album))',
		'create table if not exists artists (id integer primary key, kind text not null, name text not null, albums integer not null, first_id integer not null, jf_id text not null, unique (kind, name))',
		'create table if not exists genres (name text primary key, songs integer not null, albums integer not null)',
	] {
		app.db.exec(q)!
	}
	for col_ddl in [
		'alter table items add column mtime integer not null default 0',
		"alter table items add column album_artist text not null default ''",
		'alter table items add column play_count integer not null default 0',
		'alter table items add column last_played integer not null default 0',
		'alter table items add column disc_no integer not null default 0',
		'alter table items add column bitrate integer not null default 0',
		'alter table items add column sample_rate integer not null default 0',
		'alter table items add column bit_depth integer not null default 0',
		'alter table items add column channels integer not null default 0',
		'alter table items add column rg_track_gain real not null default 0.0',
		'alter table items add column rg_album_gain real not null default 0.0',
		'alter table items add column rg_track_peak real not null default 0.0',
		'alter table items add column rg_album_peak real not null default 0.0',
	] {
		app.db.exec(col_ddl) or {}
	}
	app.db.exec("update items set album_artist = artist where album_artist = ''")!
	app.db.exec('update items set play_count = (select count(*) from plays p where p.item_id = items.id), last_played = coalesce((select max(p.at) from plays p where p.item_id = items.id), 0) where play_count = 0 and id in (select distinct item_id from plays)')!
	// Cover the album and artist aggregates, so grouping reads the index alone.
	app.db.exec('create index if not exists items_album on items (album_artist, album, missing, kind, duration, year, genre, added_at)')!
	app.db.exec('create index if not exists items_artist on items (artist, album, missing, kind)')!
	app.db.exec("create index if not exists items_audio_album_tracks on items (album_artist, album, track_no, title collate nocase) where missing = 0 and kind = 'audio'")!
	app.db.exec("create index if not exists items_audio_album_disc on items (album_artist, album, disc_no, track_no, title collate nocase) where missing = 0 and kind = 'audio'")!
	app.db.exec('create index if not exists items_list_order on items (artist collate nocase, album collate nocase, track_no, title collate nocase) where missing = 0')!
	app.db.exec('create index if not exists items_list_order_disc on items (artist collate nocase, album collate nocase, disc_no, track_no, title collate nocase) where missing = 0')!
	app.db.exec('create index if not exists contributions_entity on contributions (entity, entity_id, id desc)')!
	app.db.exec('create index if not exists contributions_app on contributions (app_id, id desc)')!
	app.db.exec('create index if not exists plays_item on plays (item_id, at desc)')!
	for q in [
		'create index if not exists albums_added on albums (added_at desc, album collate nocase)',
		'create index if not exists albums_name on albums (album collate nocase)',
		'create index if not exists albums_artist_year on albums (album_artist collate nocase, year, album collate nocase)',
		'create index if not exists albums_year on albums (year, album collate nocase)',
		'create index if not exists albums_genre on albums (genre, album collate nocase)',
		'create index if not exists albums_rating on albums (rating desc, album collate nocase)',
		'create index if not exists albums_plays on albums (play_count desc, album collate nocase)',
		'create index if not exists albums_recent on albums (last_played desc, album collate nocase)',
		'create index if not exists albums_jf on albums (jf_id)',
		'create index if not exists artists_kind_name on artists (kind, name collate nocase, albums, first_id)',
		'create index if not exists artists_jf on artists (jf_id, kind)',
		"create virtual table if not exists items_fts using fts5(title, artist, album, genre, tags, content='items', content_rowid='id', tokenize='unicode61 remove_diacritics 2')",
		"create virtual table if not exists albums_fts using fts5(album, album_artist, content='albums', content_rowid='id', tokenize='unicode61 remove_diacritics 2')",
		"create virtual table if not exists artists_fts using fts5(name, content='artists', content_rowid='id', tokenize='unicode61 remove_diacritics 2')",
		'create trigger if not exists items_ai after insert on items begin insert into items_fts(rowid, title, artist, album, genre, tags) values (new.id, new.title, new.artist, new.album, new.genre, new.tags); end',
		"create trigger if not exists items_ad after delete on items begin insert into items_fts(items_fts, rowid, title, artist, album, genre, tags) values ('delete', old.id, old.title, old.artist, old.album, old.genre, old.tags); end",
		"create trigger if not exists items_au after update of title, artist, album, genre, tags on items begin insert into items_fts(items_fts, rowid, title, artist, album, genre, tags) values ('delete', old.id, old.title, old.artist, old.album, old.genre, old.tags); insert into items_fts(rowid, title, artist, album, genre, tags) values (new.id, new.title, new.artist, new.album, new.genre, new.tags); end",
	] {
		app.db.exec(q)!
	}
}

fn (app &App) reload_settings() {
	rows := app.reader().exec('select key, value from settings') or { return }
	mut next := map[string]string{}
	for r in rows {
		next[r.vals[0]] = r.vals[1]
	}
	unsafe {
		mut c := app.cache
		c.mu.lock()
		c.settings = next.move()
		c.mu.unlock()
	}
}

fn (app &App) get(key string) string {
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		val := c.settings[key]
		c.mu.runlock()
		return val
	}
}

fn (app &App) set(key string, value string) {
	app.db.exec_param_many('insert into settings (key, value) values (?, ?) on conflict(key) do update set value = excluded.value', [
		key,
		value,
	]) or {
		eprintln('settings: ${err}')
		return
	}
	unsafe {
		mut c := app.cache
		c.mu.lock()
		c.settings[key] = value
		c.mu.unlock()
	}
}

fn (app &App) reload_ratings_flag() {
	has := (app.fast_q_int('select exists(select 1 from album_ratings)', []) or { 0 }) == 1
	unsafe {
		mut c := app.cache
		c.mu.lock()
		c.has_ratings = has
		c.mu.unlock()
	}
}

fn (app &App) has_ratings() bool {
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		has := c.has_ratings
		c.mu.runlock()
		return has
	}
}

fn item_from(r sqlite.Row) Item {
	v := r.vals
	return Item{
		id:            v[0].int()
		path:          v[1]
		kind:          v[2]
		title:         v[3]
		artist:        v[4]
		album:         v[5]
		genre:         v[6]
		year:          v[7].int()
		track_no:      v[8].int()
		duration:      v[9].int()
		tags:          v[10]
		size:          v[11].i64()
		added_at:      v[12].i64()
		album_artist:  v[13]
		play_count:    v[14].int()
		last_played:   v[15].i64()
		disc_no:       v[16].int()
		bitrate:       v[17].int()
		sample_rate:   v[18].int()
		bit_depth:     v[19].int()
		channels:      v[20].int()
		rg_track_gain: v[21].f64()
		rg_album_gain: v[22].f64()
		rg_track_peak: v[23].f64()
		rg_album_peak: v[24].f64()
		missing:       v.len > 25 && v[25] == '1'
	}
}

fn qmarks(n int) string {
	if n <= 0 {
		return ''
	}
	mut b := []u8{len: n * 2 - 1}
	for i in 0 .. n {
		b[i * 2] = `?`
		if i + 1 < n {
			b[i * 2 + 1] = `,`
		}
	}
	return b.bytestr()
}

fn unique_random_ids(top int, want int) []string {
	target := if want < top { want } else { top }
	mut picked := []int{cap: target}
	for picked.len < target {
		candidate := (rand.intn(top) or { 0 }) + 1
		mut seen := false
		for p in picked {
			if p == candidate {
				seen = true
				break
			}
		}
		if !seen {
			picked << candidate
		}
	}
	mut ids := []string{cap: picked.len}
	for p in picked {
		ids << p.str()
	}
	return ids
}

// `tail` must be a code constant; user input only ever goes in `params`.
fn (app &App) items(tail string, params []string) []Item {
	return app.fast_items('select ${item_cols} from items ${tail}', params, false)
}

// Ids are drawn here, not with ORDER BY random(): SQLite's random() takes a
// process-wide lock per row, which stalls parallel requests.
fn (app &App) random_items(n int) []Item {
	top := app.fast_q_int('select max(id) from items', []) or { 0 }
	if top <= 0 || n <= 0 {
		return []
	}
	want := n + n / 5 + 8
	mut found := if want * 2 >= top {
		app.items('where ${audio} order by random() limit ?', [n.str()])
	} else {
		ids := unique_random_ids(top, want)
		mut rows := app.items('where ${audio} and id in (${qmarks(ids.len)})', ids)
		if rows.len < n {
			rows = app.items('where ${audio} order by random() limit ?', [n.str()])
		}
		rows
	}
	rand.shuffle(mut found) or {}
	return found[..if found.len < n {
		found.len
	} else {
		n
	}]
}

fn (app &App) item(id int) ?Item {
	return app.fast_item_one('select ${item_cols}, missing from items where id = ?', [
		id.str(),
	], true)
}

pub struct Album {
pub:
	artist      string
	name        string
	songs       int
	duration    int
	year        int
	genre       string
	first_id    int
	added_at    i64
	rating      int
	play_count  int
	last_played i64
}

pub struct ArtistRow {
pub:
	name     string
	albums   int
	first_id int
}

pub struct GenreRow {
pub:
	name   string
	songs  int
	albums int
}

pub struct PlaylistSummary {
pub:
	id         int
	name       string
	owner      string
	created_at i64
	songs      int
	duration   int
	first_id   int
}

const audio = "missing = 0 and kind = 'audio'"

const album_group = 'album_artist, album'
const album_match = 'album_artist = ? and album = ?'
const album_mat_cols = 'album_artist, album, songs, duration, year, genre, first_id, added_at, rating, play_count, last_played'
const album_mat_cols_a = 'a.album_artist, a.album, a.songs, a.duration, a.year, a.genre, a.first_id, a.added_at, a.rating, a.play_count, a.last_played'

fn album_from_mat(r sqlite.Row, with_rating bool) Album {
	v := r.vals
	return Album{
		artist:      v[0]
		name:        v[1]
		songs:       v[2].int()
		duration:    v[3].int()
		year:        v[4].int()
		genre:       v[5]
		first_id:    v[6].int()
		added_at:    v[7].i64()
		rating:      if with_rating { v[8].int() } else { 0 }
		play_count:  v[9].int()
		last_played: v[10].i64()
	}
}

fn (app &App) ensure_catalog_ready() {
	items_cnt := app.reader().q_int('select count(*) from items') or { 0 }
	fts_cnt := app.reader().q_int('select count(*) from items_fts_docsize') or { 0 }
	if items_cnt > 0 && fts_cnt == 0 {
		unsafe {
			mut c := app.cache
			c.tx_mu.lock()
			app.db.exec("insert into items_fts(items_fts) values('rebuild')") or {
				eprintln('items_fts rebuild: ${err}')
			}
			c.tx_mu.unlock()
		}
	}
	audio_cnt := app.reader().q_int('select count(*) from items where ${audio}') or { 0 }
	mat_songs := app.reader().q_int('select coalesce(sum(songs), 0) from albums') or { 0 }
	mat_artists := app.reader().q_int('select count(*) from artists') or { 0 }
	if (audio_cnt > 0 && (mat_songs != audio_cnt || mat_artists == 0))
		|| (audio_cnt == 0 && (mat_songs > 0 || mat_artists > 0)) {
		app.rebuild_catalog()
	}
}

fn (app &App) rebuild_catalog() {
	al_rows := app.reader().exec('select album_artist, album, count(*), sum(duration), max(year), max(genre), min(id), max(added_at), sum(play_count), max(last_played), coalesce((select rating from album_ratings r where r.album_artist = items.album_artist and r.album = items.album), 0) from items where ${audio} group by ${album_group}') or {
		eprintln('rebuild albums: ${err}')
		return
	}
	ar_rows := app.reader().exec('select artist, count(distinct album), min(id) from items where ${audio} group by artist') or {
		eprintln('rebuild artists: ${err}')
		return
	}
	aa_rows := app.reader().exec('select album_artist, count(distinct album), min(id) from items where ${audio} group by album_artist') or {
		eprintln('rebuild album_artists: ${err}')
		return
	}
	ge_rows := app.reader().exec("select genre, count(*), count(distinct album_artist || char(31) || album) from items where ${audio} and genre != '' group by genre") or {
		eprintln('rebuild genres: ${err}')
		return
	}
	mut al_jfs := []string{cap: al_rows.len}
	for r in al_rows {
		al_jfs << jf_album_id(r.vals[0], r.vals[1])
	}
	mut ar_jfs := []string{cap: ar_rows.len}
	for r in ar_rows {
		ar_jfs << jf_artist_id(r.vals[0])
	}
	mut aa_jfs := []string{cap: aa_rows.len}
	for r in aa_rows {
		aa_jfs << jf_artist_id(r.vals[0])
	}

	unsafe {
		mut c := app.cache
		c.tx_mu.lock()
	}
	defer {
		unsafe {
			mut c := app.cache
			c.tx_mu.unlock()
		}
	}
	app.db.exec('begin immediate') or {
		eprintln('rebuild begin: ${err}')
		return
	}
	mut failed := false
	app.db.exec('delete from albums') or { failed = true }
	if !failed {
		for i, r in al_rows {
			v := r.vals
			app.db.exec_param_many('insert into albums (id, album_artist, album, songs, duration, year, genre, first_id, added_at, play_count, last_played, rating, jf_id) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', [
				(i + 1).str(),
				v[0],
				v[1],
				v[2],
				v[3],
				v[4],
				v[5],
				v[6],
				v[7],
				v[8],
				v[9],
				v[10],
				al_jfs[i],
			]) or {
				failed = true
				break
			}
		}
	}
	if !failed {
		app.db.exec('delete from artists') or { failed = true }
	}
	if !failed {
		mut aid := 1
		for i, r in ar_rows {
			v := r.vals
			app.db.exec_param_many('insert into artists (id, kind, name, albums, first_id, jf_id) values (?, ?, ?, ?, ?, ?)', [
				aid.str(),
				'artist',
				v[0],
				v[1],
				v[2],
				ar_jfs[i],
			]) or {
				failed = true
				break
			}
			aid++
		}
		if !failed {
			for i, r in aa_rows {
				v := r.vals
				app.db.exec_param_many('insert into artists (id, kind, name, albums, first_id, jf_id) values (?, ?, ?, ?, ?, ?)', [
					aid.str(),
					'album_artist',
					v[0],
					v[1],
					v[2],
					aa_jfs[i],
				]) or {
					failed = true
					break
				}
				aid++
			}
		}
	}
	if !failed {
		app.db.exec('delete from genres') or { failed = true }
	}
	if !failed {
		for r in ge_rows {
			v := r.vals
			app.db.exec_param_many('insert into genres (name, songs, albums) values (?, ?, ?)', [
				v[0],
				v[1],
				v[2],
			]) or {
				failed = true
				break
			}
		}
	}
	if !failed {
		app.db.exec("insert into albums_fts(albums_fts) values('rebuild')") or { failed = true }
	}
	if !failed {
		app.db.exec("insert into artists_fts(artists_fts) values('rebuild')") or { failed = true }
	}
	if failed {
		app.db.exec('rollback') or {}
		eprintln('rebuild catalog failed; rolled back')
		return
	}
	app.db.exec('commit') or { eprintln('rebuild commit: ${err}') }
	app.bump_catalog_gen()
}

// `tail` must be a code constant.
fn (app &App) albums_mat(with_rating bool, tail string, params []string) []Album {
	return app.fast_albums(with_rating, 'select ${album_mat_cols} from albums ${tail}',
		params)
}

// `tail` must be a code constant.
fn (app &App) albums_mat_count(tail string, params []string) int {
	return app.fast_q_int('select count(*) from albums ${tail}', params) or { 0 }
}

fn (app &App) random_albums(with_rating bool, n int) []Album {
	top := app.fast_q_int('select max(id) from albums', []) or { 0 }
	if top <= 0 || n <= 0 {
		return []
	}
	mut found := if n * 2 >= top {
		app.albums_mat(with_rating, 'order by random() limit ?', [n.str()])
	} else {
		ids := unique_random_ids(top, n)
		mut rows := app.albums_mat(with_rating, 'where id in (${qmarks(ids.len)})', ids)
		if rows.len < n {
			rows = app.albums_mat(with_rating, 'order by random() limit ?', [n.str()])
		}
		rows
	}
	rand.shuffle(mut found) or {}
	return found[..if found.len < n {
		found.len
	} else {
		n
	}]
}

fn (app &App) find_album_by_jf_id(jf_id string) ?Album {
	rows := app.fast_albums(false, 'select ${album_mat_cols} from albums where jf_id = ? limit 1',
		[jf_id])
	return if rows.len > 0 { rows[0] } else { none }
}

// `tail` must be a code constant.
fn (app &App) artists_mat(kind string, tail string, params []string) []ArtistRow {
	mut all := [kind]
	all << params
	return app.fast_artists('select name, albums, first_id from artists where kind = ? ${tail}',
		all)
}

// `tail` must be a code constant.
fn (app &App) artists_mat_count(kind string, tail string, params []string) int {
	mut all := [kind]
	all << params
	return app.fast_q_int('select count(*) from artists where kind = ? ${tail}', all) or { 0 }
}

fn (app &App) find_artist_by_jf_id(jf_id string) ?ArtistRow {
	rows := app.fast_artists("select name, albums, first_id from artists where jf_id = ? order by case when kind = 'artist' then 0 else 1 end limit 1",
		[jf_id])
	return if rows.len > 0 { rows[0] } else { none }
}

fn (app &App) genres_mat() []GenreRow {
	return app.fast_genres('select name, songs, albums from genres order by name collate nocase')
}

fn (app &App) playlist_summaries() []PlaylistSummary {
	return app.fast_playlists('select p.id, p.name, p.owner, p.created_at, count(i.id), coalesce(sum(i.duration), 0), coalesce((select pi2.item_id from playlist_items pi2 where pi2.playlist_id = p.id order by pi2.pos limit 1), 0) from playlists p left join playlist_items pi on pi.playlist_id = p.id left join items i on i.id = pi.item_id group by p.id order by p.name',
		[])
}

fn (app &App) playlist_summary(id int) ?PlaylistSummary {
	rows := app.fast_playlists('select p.id, p.name, p.owner, p.created_at, count(i.id), coalesce(sum(i.duration), 0), coalesce((select pi2.item_id from playlist_items pi2 where pi2.playlist_id = p.id order by pi2.pos limit 1), 0) from playlists p left join playlist_items pi on pi.playlist_id = p.id left join items i on i.id = pi.item_id where p.id = ? group by p.id',
		[id.str()])
	return if rows.len > 0 { rows[0] } else { none }
}

fn fts_query(raw string) string {
	mut tokens := []string{}
	mut cur := []u8{}
	for b in raw.bytes() {
		if b >= 128 || (b >= `a` && b <= `z`) || (b >= `A` && b <= `Z`)
			|| (b >= `0` && b <= `9`) || b == `_` {
			cur << b
		} else if cur.len > 0 {
			tokens << '"${cur.bytestr()}"*'
			cur.clear()
		}
	}
	if cur.len > 0 {
		tokens << '"${cur.bytestr()}"*'
	}
	return tokens.join(' ')
}

fn fts_cols_query(cols string, raw string) string {
	q := fts_query(raw)
	if q == '' {
		return ''
	}
	if cols == '' {
		return q
	}
	return '{${cols}} : (${q})'
}

fn (app &App) search_items_fts(raw string, cols string, audio_only bool, genre string, limit int, offset int) []Item {
	fq := fts_cols_query(cols, raw)
	base := if audio_only { "i.missing = 0 and i.kind = 'audio'" } else { 'i.missing = 0' }
	genre_cond := if genre != '' { ' and i.genre = ?' } else { '' }
	if fq != '' {
		mut params := [fq]
		if genre != '' {
			params << genre
		}
		params << [limit.str(), offset.str()]
		return app.fast_items('select ${item_cols_i} from items_fts f join items i on i.id = f.rowid where items_fts match ? and ${base}${genre_cond} limit ? offset ?',
			params, false)
	}
	pattern := '%' + raw + '%'
	base_plain := if audio_only { audio } else { 'missing = 0' }
	like_cond := if cols == 'title artist album' {
		'(title like ?1 or artist like ?1 or album like ?1)'
	} else {
		'(title like ?1 or artist like ?1 or album like ?1 or genre like ?1 or tags like ?1)'
	}
	if genre != '' {
		return app.items('where ${base_plain} and ${like_cond} and genre = ?2 order by artist collate nocase, album collate nocase, disc_no, track_no, title collate nocase limit ?3 offset ?4', [
			pattern,
			genre,
			limit.str(),
			offset.str(),
		])
	}
	return app.items('where ${base_plain} and ${like_cond} order by artist collate nocase, album collate nocase, disc_no, track_no, title collate nocase limit ?2 offset ?3', [
		pattern,
		limit.str(),
		offset.str(),
	])
}

fn (app &App) search_items_fts_count(raw string, cols string, audio_only bool, genre string) int {
	fq := fts_cols_query(cols, raw)
	base := if audio_only { "i.missing = 0 and i.kind = 'audio'" } else { 'i.missing = 0' }
	genre_cond := if genre != '' { ' and i.genre = ?' } else { '' }
	if fq != '' {
		mut params := [fq]
		if genre != '' {
			params << genre
		}
		return app.fast_q_int('select count(*) from items_fts f join items i on i.id = f.rowid where items_fts match ? and ${base}${genre_cond}',
			params) or { 0 }
	}
	pattern := '%' + raw + '%'
	base_plain := if audio_only { audio } else { 'missing = 0' }
	like_cond := if cols == 'title artist album' {
		'(title like ?1 or artist like ?1 or album like ?1)'
	} else {
		'(title like ?1 or artist like ?1 or album like ?1 or genre like ?1 or tags like ?1)'
	}
	mut params := [pattern]
	g_clause := if genre != '' {
		params << genre
		' and genre = ?2'
	} else {
		''
	}
	return app.fast_q_int('select count(*) from items where ${base_plain} and ${like_cond}${g_clause}',
		params) or { 0 }
}

fn (app &App) search_albums_fts(with_rating bool, raw string, genre string, limit int, offset int) []Album {
	fq := fts_query(raw)
	genre_cond := if genre != '' { ' and a.genre = ?' } else { '' }
	if fq != '' {
		mut params := [fq]
		if genre != '' {
			params << genre
		}
		params << [limit.str(), offset.str()]
		return app.fast_albums(with_rating, 'select ${album_mat_cols_a} from albums_fts f join albums a on a.id = f.rowid where albums_fts match ?${genre_cond} limit ? offset ?',
			params)
	}
	pattern := '%' + raw + '%'
	mut params := [pattern, pattern]
	g_clause := if genre != '' {
		params << genre
		' and genre = ?'
	} else {
		''
	}
	params << [limit.str(), offset.str()]
	return app.albums_mat(with_rating, 'where (album like ? or album_artist like ?)${g_clause} order by album collate nocase limit ? offset ?',
		params)
}

fn (app &App) search_albums_fts_count(raw string, genre string) int {
	fq := fts_query(raw)
	genre_cond := if genre != '' { ' and a.genre = ?' } else { '' }
	if fq != '' {
		mut params := [fq]
		if genre != '' {
			params << genre
		}
		return app.fast_q_int('select count(*) from albums_fts f join albums a on a.id = f.rowid where albums_fts match ?${genre_cond}',
			params) or { 0 }
	}
	pattern := '%' + raw + '%'
	mut params := [pattern, pattern]
	g_clause := if genre != '' {
		params << genre
		' and genre = ?'
	} else {
		''
	}
	return app.albums_mat_count('where (album like ? or album_artist like ?)${g_clause}',
		params)
}

fn (app &App) search_artists_fts(kind string, raw string, limit int, offset int) []ArtistRow {
	fq := fts_query(raw)
	if fq != '' {
		return app.fast_artists('select a.name, a.albums, a.first_id from artists_fts f join artists a on a.id = f.rowid where artists_fts match ? and a.kind = ? limit ? offset ?', [
			fq,
			kind,
			limit.str(),
			offset.str(),
		])
	}
	return app.artists_mat(kind, 'and name like ? order by name collate nocase limit ? offset ?', [
		'%' + raw + '%',
		limit.str(),
		offset.str(),
	])
}

fn (app &App) search_artists_fts_count(kind string, raw string) int {
	fq := fts_query(raw)
	if fq != '' {
		return app.fast_q_int('select count(*) from artists_fts f join artists a on a.id = f.rowid where artists_fts match ? and a.kind = ?', [
			fq,
			kind,
		]) or { 0 }
	}
	return app.artists_mat_count(kind, 'and name like ?', ['%' + raw + '%'])
}

// `tail` must be a code constant.
fn (app &App) album_rows_opt(with_rating bool, tail string, params []string) []Album {
	rating_expr := if with_rating && app.has_ratings() {
		'coalesce((select rating from album_ratings r where r.album_artist = items.album_artist and r.album = items.album), 0) as rating'
	} else {
		'0 as rating'
	}
	rows := app.reader().exec_param_many('select album_artist, album, count(*), sum(duration), max(year), max(genre), min(id), max(added_at), ${rating_expr} from items where ${audio} ${tail}',
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
fn (app &App) album_rows(tail string, params []string) []Album {
	return app.album_rows_opt(true, tail, params)
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
	new := if field in ['year', 'track_no', 'disc_no'] {
		value.int().str()
	} else {
		value.trim_space()
	}
	if old == new {
		return
	}
	app.db.exec_param_many('update items set ${field} = ? where id = ?', [new, id.str()])!
	app.log(p, 'item', id, it.title, field, old, new)
	if field in ['artist', 'album_artist', 'album', 'genre', 'year'] {
		app.rebuild_catalog()
	} else {
		app.bump_catalog_gen()
	}
}

fn (app &App) lyrics(id int) string {
	return app.fast_q_str('select text from lyrics where item_id = ?', [id.str()]) or { '' }
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
	app.db.exec_param_many('update items set play_count = play_count + 1, last_played = max(last_played, ?) where id = ?', [
		play.at.str(),
		id.str(),
	]) or {}
	app.db.exec_param_many('update albums set play_count = play_count + 1, last_played = max(last_played, ?) where ${album_match}', [
		play.at.str(),
		it.album_artist,
		it.album,
	]) or {}
	app.bump_catalog_gen()
	spawn app.forward_play(it, play.at)
}

fn (app &App) album_rating(artist string, album string) int {
	if !app.has_ratings() {
		return 0
	}
	return app.fast_q_int('select rating from album_ratings where ${album_match}', [
		artist,
		album,
	]) or { 0 }
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
		app.reload_ratings_flag()
	} else {
		app.db.exec_param_many('insert into album_ratings (album_artist, album, rating) values (?, ?, ?) on conflict(album_artist, album) do update set rating = excluded.rating', [
			artist,
			album,
			rating.str(),
		])!
		unsafe {
			mut c := app.cache
			c.mu.lock()
			c.has_ratings = true
			c.mu.unlock()
		}
	}
	app.db.exec_param_many('update albums set rating = ? where ${album_match}', [
		rating.str(),
		artist,
		album,
	]) or {}
	app.log(p, 'album', 0, or_unknown(album, 'Album'), 'rating', old.str(), rating.str())
	app.bump_catalog_gen()
}

fn (app &App) playlist(id int) ?Playlist {
	rows := app.reader().exec_param('select id, name, owner, created_at from playlists where id = ?',
		id.str()) or { return none }
	if rows.len == 0 {
		return none
	}
	v := rows[0].vals
	return Playlist{
		id:         v[0].int()
		name:       v[1]
		owner:      v[2]
		created_at: v[3].i64()
	}
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
	app.bump_catalog_gen()
	return pid
}

fn (mut app App) delete_playlist(p Principal, id int) ! {
	old := app.playlist(id) or { return error('no such playlist') }
	app.db.exec_param('delete from playlist_items where playlist_id = ?', id.str())!
	app.db.exec_param('delete from playlists where id = ?', id.str())!
	app.log(p, 'playlist', id, old.name, 'deleted', old.name, '')
	app.bump_catalog_gen()
}

struct JsonBuf {
mut:
	data &u8 = unsafe { nil }
	len  int
	cap  int
}

fn new_jbuf(cap int) &JsonBuf {
	c := if cap < 64 { 64 } else { cap }
	return &JsonBuf{
		data: unsafe { malloc_noscan(c + 1) }
		len:  0
		cap:  c
	}
}

@[inline]
fn (mut j JsonBuf) grow(add int) {
	if j.len + add > j.cap {
		mut nc := if j.cap > 0 { j.cap * 2 } else { 64 }
		for nc < j.len + add {
			nc *= 2
		}
		nd := unsafe { malloc_noscan(nc + 1) }
		if j.data != unsafe { nil } && j.len > 0 {
			unsafe { vmemcpy(nd, j.data, j.len) }
		}
		j.data = nd
		j.cap = nc
	}
}

@[inline]
fn (mut j JsonBuf) byte(c u8) {
	j.grow(1)
	unsafe {
		j.data[j.len] = c
	}
	j.len++
}

@[inline]
fn (mut j JsonBuf) raw(s string) {
	j.grow(s.len)
	if s.len > 0 {
		unsafe { vmemcpy(j.data + j.len, s.str, s.len) }
		j.len += s.len
	}
}

@[inline]
fn (mut j JsonBuf) jbool(v bool) {
	if v {
		j.raw('true')
	} else {
		j.raw('false')
	}
}

fn (mut j JsonBuf) jint(v i64) {
	if v == 0 {
		j.byte(`0`)
		return
	}
	mut buf := [24]u8{}
	mut pos := 24
	neg := v < 0
	mut u := if neg { u64(-(v + 1)) + 1 } else { u64(v) }
	for u > 0 {
		pos--
		buf[pos] = u8(`0` + u % 10)
		u /= 10
	}
	if neg {
		pos--
		buf[pos] = `-`
	}
	n := 24 - pos
	j.grow(n)
	unsafe { vmemcpy(j.data + j.len, &buf[pos], n) }
	j.len += n
}

fn (mut j JsonBuf) jf64(v f64) {
	if v == 0 {
		j.byte(`0`)
		return
	}
	s := v.str()
	if s.len > 2 && s[s.len - 2] == `.` && s[s.len - 1] == `0` {
		j.raw(s[..s.len - 2])
		return
	}
	j.raw(s)
}

fn (mut j JsonBuf) jstr(s string) {
	j.grow(s.len + 2)
	unsafe {
		j.data[j.len] = `"`
	}
	j.len++
	mut start := 0
	for i := 0; i < s.len; i++ {
		c := s[i]
		if c == `"` || c == `\\` || c < 0x20 {
			if i > start {
				n := i - start
				j.grow(n)
				unsafe { vmemcpy(j.data + j.len, s.str + start, n) }
				j.len += n
			}
			match c {
				`"` {
					j.raw('\\"')
				}
				`\\` {
					j.raw('\\\\')
				}
				`\b` {
					j.raw('\\b')
				}
				`\f` {
					j.raw('\\f')
				}
				`\n` {
					j.raw('\\n')
				}
				`\r` {
					j.raw('\\r')
				}
				`\t` {
					j.raw('\\t')
				}
				else {
					hex := '0123456789abcdef'
					j.grow(6)
					unsafe {
						j.data[j.len] = `\\`
						j.data[j.len + 1] = `u`
						j.data[j.len + 2] = `0`
						j.data[j.len + 3] = `0`
						j.data[j.len + 4] = hex[c >> 4]
						j.data[j.len + 5] = hex[c & 0xf]
					}
					j.len += 6
				}
			}
			start = i + 1
		}
	}
	if s.len > start {
		n := s.len - start
		j.grow(n)
		unsafe { vmemcpy(j.data + j.len, s.str + start, n) }
		j.len += n
	}
	j.byte(`"`)
}

fn (j &JsonBuf) finish() string {
	unsafe {
		j.data[j.len] = 0
		return j.data.vstring_with_len(j.len)
	}
}

fn encode_item_page_json(items &[]Item, total int, rating int) string {
	mut j := new_jbuf(items.len * 380 + 64)
	j.raw('{"items":[')
	for i := 0; i < items.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		it := unsafe { &(*items)[i] }
		j.raw('{"id":')
		j.jint(it.id)
		j.raw(',"path":')
		j.jstr(it.path)
		j.raw(',"kind":')
		j.jstr(it.kind)
		j.raw(',"title":')
		j.jstr(it.title)
		j.raw(',"artist":')
		j.jstr(it.artist)
		j.raw(',"album":')
		j.jstr(it.album)
		j.raw(',"genre":')
		j.jstr(it.genre)
		j.raw(',"year":')
		j.jint(it.year)
		j.raw(',"track_no":')
		j.jint(it.track_no)
		j.raw(',"duration":')
		j.jint(it.duration)
		j.raw(',"tags":')
		j.jstr(it.tags)
		j.raw(',"size":')
		j.jint(it.size)
		j.raw(',"added_at":')
		j.jint(it.added_at)
		j.raw(',"missing":')
		j.jbool(it.missing)
		j.raw(',"mtime":')
		j.jint(it.mtime)
		j.raw(',"album_artist":')
		j.jstr(it.album_artist)
		j.raw(',"play_count":')
		j.jint(it.play_count)
		j.raw(',"last_played":')
		j.jint(it.last_played)
		j.raw(',"disc_no":')
		j.jint(it.disc_no)
		j.raw(',"bitrate":')
		j.jint(it.bitrate)
		j.raw(',"sample_rate":')
		j.jint(it.sample_rate)
		j.raw(',"bit_depth":')
		j.jint(it.bit_depth)
		j.raw(',"channels":')
		j.jint(it.channels)
		j.raw(',"rg_track_gain":')
		j.jf64(it.rg_track_gain)
		j.raw(',"rg_album_gain":')
		j.jf64(it.rg_album_gain)
		j.raw(',"rg_track_peak":')
		j.jf64(it.rg_track_peak)
		j.raw(',"rg_album_peak":')
		j.jf64(it.rg_album_peak)
		j.byte(`}`)
	}
	j.raw('],"total":')
	j.jint(total)
	j.raw(',"rating":')
	j.jint(rating)
	j.byte(`}`)
	return j.finish()
}

fn encode_albums_json(albums &[]Album) string {
	mut j := new_jbuf(albums.len * 220 + 16)
	j.byte(`[`)
	for i := 0; i < albums.len; i++ {
		if i > 0 {
			j.byte(`,`)
		}
		al := unsafe { &(*albums)[i] }
		j.raw('{"artist":')
		j.jstr(al.artist)
		j.raw(',"name":')
		j.jstr(al.name)
		j.raw(',"songs":')
		j.jint(al.songs)
		j.raw(',"duration":')
		j.jint(al.duration)
		j.raw(',"year":')
		j.jint(al.year)
		j.raw(',"genre":')
		j.jstr(al.genre)
		j.raw(',"first_id":')
		j.jint(al.first_id)
		j.raw(',"added_at":')
		j.jint(al.added_at)
		j.raw(',"rating":')
		j.jint(al.rating)
		j.raw(',"play_count":')
		j.jint(al.play_count)
		j.raw(',"last_played":')
		j.jint(al.last_played)
		j.byte(`}`)
	}
	j.byte(`]`)
	return j.finish()
}

struct PlayQueue {
	item_ids    []int
	current_id  int
	position_ms i64
	changed_by  string
	updated_at  i64
}

fn (mut app App) set_star(p Principal, kind string, key string, starred bool) ! {
	if kind !in ['item', 'album', 'artist'] || key == '' {
		return error('invalid star target')
	}
	was := app.is_starred(kind, key)
	if was == starred {
		return
	}
	if starred {
		app.db.exec_param_many('insert or ignore into stars (kind, key, at) values (?, ?, ?)', [
			kind,
			key,
			time.now().unix().str(),
		])!
	} else {
		app.db.exec_param_many('delete from stars where kind = ? and key = ?', [kind, key])!
	}
	app.log(p, kind, if kind == 'item' { key.int() } else { 0 }, key, 'star', if was {
		'1'
	} else {
		''
	}, if starred { '1' } else { '' })
	app.bump_catalog_gen()
}

fn (app &App) is_starred(kind string, key string) bool {
	return (app.fast_q_int('select exists(select 1 from stars where kind = ? and key = ?)', [
		kind,
		key,
	]) or { 0 }) == 1
}

fn (app &App) starred_map(kind string) map[string]i64 {
	mut m := map[string]i64{}
	rows := app.reader().exec_param('select key, at from stars where kind = ?', kind) or {
		return m
	}
	for r in rows {
		m[r.vals[0]] = r.vals[1].i64()
	}
	return m
}

fn (app &App) starred_items() []Item {
	return app.items("where ${audio} and exists (select 1 from stars s where s.kind = 'item' and s.key = cast(items.id as text)) order by coalesce((select s.at from stars s where s.kind = 'item' and s.key = cast(items.id as text)), 0) desc, items.id",
		[])
}

fn (app &App) starred_albums(with_rating bool, limit int, offset int) []Album {
	return app.albums_mat(with_rating, "where exists (select 1 from stars s where s.kind = 'album' and s.key = (albums.album_artist || char(31) || albums.album)) order by coalesce((select s.at from stars s where s.kind = 'album' and s.key = (albums.album_artist || char(31) || albums.album)), 0) desc, albums.album collate nocase limit ? offset ?", [
		limit.str(),
		offset.str(),
	])
}

fn (app &App) starred_artists() []ArtistRow {
	return app.artists_mat('artist', "and exists (select 1 from stars s where s.kind = 'artist' and s.key = artists.name) order by coalesce((select s.at from stars s where s.kind = 'artist' and s.key = artists.name), 0) desc, artists.name collate nocase",
		[])
}

fn (mut app App) save_play_queue(p Principal, item_ids []int, current_id int, position_ms i64, changed_by string) ! {
	if item_ids.len == 0 {
		app.db.exec('delete from play_queue where id = 1')!
		return
	}
	ids_csv := item_ids.map(it.str()).join(',')
	by := if changed_by != '' { changed_by } else { p.name }
	app.db.exec_param_many('insert into play_queue (id, item_ids, current_id, position_ms, changed_by, updated_at) values (1, ?, ?, ?, ?, ?) on conflict(id) do update set item_ids = excluded.item_ids, current_id = excluded.current_id, position_ms = excluded.position_ms, changed_by = excluded.changed_by, updated_at = excluded.updated_at', [
		ids_csv,
		current_id.str(),
		position_ms.str(),
		by,
		time.now().unix().str(),
	])!
}

fn (app &App) get_play_queue() ?PlayQueue {
	rows := app.reader().exec('select item_ids, current_id, position_ms, changed_by, updated_at from play_queue where id = 1') or {
		return none
	}
	if rows.len == 0 {
		return none
	}
	v := rows[0].vals
	if v[0] == '' {
		return none
	}
	ids := v[0].split(',').filter(it != '').map(it.int()).filter(it > 0)
	if ids.len == 0 {
		return none
	}
	return PlayQueue{
		item_ids:    ids
		current_id:  v[1].int()
		position_ms: v[2].i64()
		changed_by:  v[3]
		updated_at:  v[4].i64()
	}
}

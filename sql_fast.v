module main

import db.sqlite
import sync
import sync.stdatomic

fn C.sqlite3_clear_bindings(&C.sqlite3_stmt) i32
fn C.sqlite3_exec(&C.sqlite3, &char, voidptr, voidptr, &&char) i32

const sqlite_open_readonly = 0x00000001
const sqlite_open_nomutex = 0x00008000
const sqlite_stmt_cache_max = 64

@[heap]
pub struct ReadConn {
mut:
	mu    sync.Mutex
	conn  &C.sqlite3 = unsafe { nil }
	stmts map[string]&C.sqlite3_stmt
}

fn open_read_conn(db_path string) !&ReadConn {
	mut conn := &C.sqlite3(unsafe { nil })
	rc_code := C.sqlite3_open_v2(&char(db_path.str), &conn, sqlite_open_readonly | sqlite_open_nomutex,
		unsafe { nil })
	if rc_code != sqlite.sqlite_ok || conn == unsafe { nil } {
		if conn != unsafe { nil } {
			C.sqlite3_close(conn)
		}
		return error('sqlite open_v2 failed (${rc_code})')
	}
	C.sqlite3_busy_timeout(conn, 5000)
	pragmas := c'pragma query_only = on; pragma temp_store = memory; pragma mmap_size = 268435456; pragma cache_size = -4000;'
	C.sqlite3_exec(conn, pragmas, unsafe { nil }, unsafe { nil }, unsafe { nil })
	mut rconn := &ReadConn{
		conn: conn
	}
	rconn.mu.init()
	return rconn
}

fn (mut rc ReadConn) acquire_stmt(query string) ?(&C.sqlite3_stmt, bool) {
	if s := rc.stmts[query] {
		return s, true
	}
	mut stmt := &C.sqlite3_stmt(unsafe { nil })
	code := C.sqlite3_prepare_v2(rc.conn, &char(query.str), query.len, &stmt, unsafe { nil })
	if code != sqlite.sqlite_ok || stmt == unsafe { nil } {
		return none
	}
	if rc.stmts.len < sqlite_stmt_cache_max && !query.contains(' in (?') {
		rc.stmts[query] = stmt
		return stmt, true
	}
	return stmt, false
}

fn stmt_bind(stmt &C.sqlite3_stmt, params []string) bool {
	for i, p in params {
		ptr := if p.len > 0 { &char(p.str) } else { c'' }
		if C.sqlite3_bind_text(stmt, i + 1, ptr, p.len, unsafe { nil }) != sqlite.sqlite_ok {
			return false
		}
	}
	return true
}

fn stmt_release(stmt &C.sqlite3_stmt, cached bool) {
	if cached {
		C.sqlite3_reset(stmt)
		C.sqlite3_clear_bindings(stmt)
	} else {
		C.sqlite3_finalize(stmt)
	}
}

@[inline]
fn stmt_str(stmt &C.sqlite3_stmt, col int) string {
	p := unsafe { &u8(C.sqlite3_column_text(stmt, col)) }
	if p == unsafe { nil } {
		return ''
	}
	n := int(C.sqlite3_column_bytes(stmt, col))
	if n <= 0 {
		return ''
	}
	unsafe {
		buf := malloc_noscan(n + 1)
		vmemcpy(buf, p, n)
		buf[n] = 0
		return buf.vstring_with_len(n)
	}
}

fn item_from_stmt(stmt &C.sqlite3_stmt, with_missing bool) Item {
	return Item{
		id:            int(C.sqlite3_column_int(stmt, 0))
		path:          stmt_str(stmt, 1)
		kind:          stmt_str(stmt, 2)
		title:         stmt_str(stmt, 3)
		artist:        stmt_str(stmt, 4)
		album:         stmt_str(stmt, 5)
		genre:         stmt_str(stmt, 6)
		year:          int(C.sqlite3_column_int(stmt, 7))
		track_no:      int(C.sqlite3_column_int(stmt, 8))
		duration:      int(C.sqlite3_column_int(stmt, 9))
		tags:          stmt_str(stmt, 10)
		size:          C.sqlite3_column_int64(stmt, 11)
		added_at:      C.sqlite3_column_int64(stmt, 12)
		album_artist:  stmt_str(stmt, 13)
		play_count:    int(C.sqlite3_column_int(stmt, 14))
		last_played:   C.sqlite3_column_int64(stmt, 15)
		disc_no:       int(C.sqlite3_column_int(stmt, 16))
		bitrate:       int(C.sqlite3_column_int(stmt, 17))
		sample_rate:   int(C.sqlite3_column_int(stmt, 18))
		bit_depth:     int(C.sqlite3_column_int(stmt, 19))
		channels:      int(C.sqlite3_column_int(stmt, 20))
		rg_track_gain: C.sqlite3_column_double(stmt, 21)
		rg_album_gain: C.sqlite3_column_double(stmt, 22)
		rg_track_peak: C.sqlite3_column_double(stmt, 23)
		rg_album_peak: C.sqlite3_column_double(stmt, 24)
		missing:       with_missing && C.sqlite3_column_int(stmt, 25) == 1
	}
}

fn album_from_stmt(stmt &C.sqlite3_stmt, with_rating bool) Album {
	return Album{
		artist:      stmt_str(stmt, 0)
		name:        stmt_str(stmt, 1)
		songs:       int(C.sqlite3_column_int(stmt, 2))
		duration:    int(C.sqlite3_column_int(stmt, 3))
		year:        int(C.sqlite3_column_int(stmt, 4))
		genre:       stmt_str(stmt, 5)
		first_id:    int(C.sqlite3_column_int(stmt, 6))
		added_at:    C.sqlite3_column_int64(stmt, 7)
		rating:      if with_rating { int(C.sqlite3_column_int(stmt, 8)) } else { 0 }
		play_count:  int(C.sqlite3_column_int(stmt, 9))
		last_played: C.sqlite3_column_int64(stmt, 10)
	}
}

fn artist_from_stmt(stmt &C.sqlite3_stmt) ArtistRow {
	return ArtistRow{
		name:     stmt_str(stmt, 0)
		albums:   int(C.sqlite3_column_int(stmt, 1))
		first_id: int(C.sqlite3_column_int(stmt, 2))
	}
}

fn genre_from_stmt(stmt &C.sqlite3_stmt) GenreRow {
	return GenreRow{
		name:   stmt_str(stmt, 0)
		songs:  int(C.sqlite3_column_int(stmt, 1))
		albums: int(C.sqlite3_column_int(stmt, 2))
	}
}

fn playlist_summary_from_stmt(stmt &C.sqlite3_stmt) PlaylistSummary {
	return PlaylistSummary{
		id:         int(C.sqlite3_column_int(stmt, 0))
		name:       stmt_str(stmt, 1)
		owner:      stmt_str(stmt, 2)
		created_at: C.sqlite3_column_int64(stmt, 3)
		songs:      int(C.sqlite3_column_int(stmt, 4))
		duration:   int(C.sqlite3_column_int(stmt, 5))
		first_id:   int(C.sqlite3_column_int(stmt, 6))
	}
}

fn (app &App) pick_read_conn() &ReadConn {
	return app.read_pool[stdatomic.add_u64(&app.next, 1) % u64(app.read_pool.len)]
}

fn (app &App) fast_q_int(query string, params []string) ?int {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or { return none }
		return if rows.len > 0 { rows[0].vals[0].int() } else { none }
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return none }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return none
	}
	if C.sqlite3_step(stmt) != sqlite.sqlite_row {
		return none
	}
	return int(C.sqlite3_column_int(stmt, 0))
}

fn (app &App) fast_q_str(query string, params []string) ?string {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or { return none }
		return if rows.len > 0 { rows[0].vals[0] } else { none }
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return none }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return none
	}
	if C.sqlite3_step(stmt) != sqlite.sqlite_row {
		return none
	}
	return stmt_str(stmt, 0)
}

fn (app &App) fast_items(query string, params []string, with_missing bool) []Item {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or {
			eprintln('items: ${err}')
			return []
		}
		return rows.map(item_from(it))
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return [] }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return []
	}
	mut out := []Item{}
	for C.sqlite3_step(stmt) == sqlite.sqlite_row {
		out << item_from_stmt(stmt, with_missing)
	}
	return out
}

fn (app &App) fast_item_one(query string, params []string, with_missing bool) ?Item {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or { return none }
		return if rows.len > 0 { item_from(rows[0]) } else { none }
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return none }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return none
	}
	if C.sqlite3_step(stmt) != sqlite.sqlite_row {
		return none
	}
	return item_from_stmt(stmt, with_missing)
}

fn (app &App) fast_albums(with_rating bool, query string, params []string) []Album {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or {
			eprintln('albums: ${err}')
			return []
		}
		return rows.map(album_from_mat(it, with_rating))
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return [] }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return []
	}
	mut out := []Album{}
	for C.sqlite3_step(stmt) == sqlite.sqlite_row {
		out << album_from_stmt(stmt, with_rating)
	}
	return out
}

fn (app &App) fast_artists(query string, params []string) []ArtistRow {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or {
			eprintln('artists: ${err}')
			return []
		}
		return rows.map(ArtistRow{
			name:     it.vals[0]
			albums:   it.vals[1].int()
			first_id: it.vals[2].int()
		})
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return [] }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return []
	}
	mut out := []ArtistRow{}
	for C.sqlite3_step(stmt) == sqlite.sqlite_row {
		out << artist_from_stmt(stmt)
	}
	return out
}

fn (app &App) fast_genres(query string) []GenreRow {
	if app.read_pool.len == 0 {
		rows := app.reader().exec(query) or { return [] }
		return rows.map(GenreRow{
			name:   it.vals[0]
			songs:  it.vals[1].int()
			albums: it.vals[2].int()
		})
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return [] }
	defer {
		stmt_release(stmt, cached)
	}
	mut out := []GenreRow{}
	for C.sqlite3_step(stmt) == sqlite.sqlite_row {
		out << genre_from_stmt(stmt)
	}
	return out
}

fn (app &App) fast_playlists(query string, params []string) []PlaylistSummary {
	if app.read_pool.len == 0 {
		rows := app.reader().exec_param_many(query, params) or { return [] }
		return rows.map(PlaylistSummary{
			id:         it.vals[0].int()
			name:       it.vals[1]
			owner:      it.vals[2]
			created_at: it.vals[3].i64()
			songs:      it.vals[4].int()
			duration:   it.vals[5].int()
			first_id:   it.vals[6].int()
		})
	}
	mut rc := app.pick_read_conn()
	rc.mu.@lock()
	defer {
		rc.mu.unlock()
	}
	stmt, cached := rc.acquire_stmt(query) or { return [] }
	defer {
		stmt_release(stmt, cached)
	}
	if !stmt_bind(stmt, params) {
		return []
	}
	mut out := []PlaylistSummary{}
	for C.sqlite3_step(stmt) == sqlite.sqlite_row {
		out << playlist_summary_from_stmt(stmt)
	}
	return out
}

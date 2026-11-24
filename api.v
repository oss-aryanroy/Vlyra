module main

import crypto.bcrypt
import crypto.sha256
import net
import net.http
import os
import rand
import time
import veb
import x.json2

const max_artwork = 10 * 1024 * 1024

fn fail(mut ctx Context, status http.Status, msg string) veb.Result {
	ctx.res.set_status(status)
	return ctx.json({
		'error': msg
	})
}

fn deny(mut ctx Context, err IError) veb.Result {
	status := if err.msg() == 'forbidden' { http.Status.forbidden } else { http.Status.unauthorized }
	return fail(mut ctx, status, err.msg())
}

fn ok(mut ctx Context) veb.Result {
	return ctx.json({
		'ok': true
	})
}

fn body(ctx &Context) map[string]json2.Any {
	parsed := json2.decode[json2.Any](ctx.req.data) or { return map[string]json2.Any{} }
	if parsed is map[string]json2.Any {
		return parsed
	}
	return map[string]json2.Any{}
}

fn serve_media(mut ctx Context, path string) veb.Result {
	if !os.exists(path) {
		return fail(mut ctx, .not_found, 'file is missing on disk')
	}
	mime := media_types[os.file_ext(path).to_lower()] or { 'application/octet-stream' }
	ctx.set_header(.accept_ranges, 'bytes')
	range := ctx.get_header(.range) or { '' }
	size := i64(os.file_size(path))
	if !range.starts_with('bytes=') || size == 0 {
		ctx.set_content_type(mime)
		return ctx.file(path)
	}
	spec := range[6..].all_before(',').split('-')
	mut start := spec[0].i64()
	mut end := if spec.len > 1 && spec[1] != '' { spec[1].i64() } else { size - 1 }
	if spec[0] == '' {
		start = if end < size { size - end } else { 0 }
		end = size - 1
	}
	if start < 0 || start >= size || end < start {
		ctx.set_header(.content_range, 'bytes */${size}')
		return fail(mut ctx, .requested_range_not_satisfiable, 'bad range')
	}
	if end > size - 1 {
		end = size - 1
	}
	// veb can only send whole files, so a range is streamed from disk on its own
	// thread; holding it in memory made memory grow with every listener.
	ctx.takeover_conn()
	spawn stream_range(mut ctx.conn, path, mime, start, end, size)
	return veb.no_result()
}

fn stream_range(mut conn net.TcpConn, path string, mime string, start i64, end i64, size i64) {
	defer {
		conn.close() or {}
	}
	mut f := os.open(path) or { return }
	defer {
		f.close()
	}
	conn.write_string('HTTP/1.1 206 Partial Content\r\nContent-Type: ${mime}\r\nContent-Length: ${
		end - start + 1}\r\nContent-Range: bytes ${start}-${end}/${size}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n') or {
		return
	}
	mut buf := []u8{len: 64 * 1024}
	mut pos := start
	for pos <= end {
		n := f.read_bytes_into(u64(pos), mut buf) or { return }
		if n <= 0 {
			return
		}
		want := if i64(n) > end - pos + 1 { int(end - pos + 1) } else { n }
		conn.write(buf[..want]) or { return }
		pos += want
	}
}

fn image_mime(data string) string {
	if data.starts_with('\xff\xd8') {
		return 'image/jpeg'
	}
	if data.starts_with('\x89PNG') {
		return 'image/png'
	}
	if data.starts_with('GIF8') {
		return 'image/gif'
	}
	if data.len > 12 && data.starts_with('RIFF') && data[8..12] == 'WEBP' {
		return 'image/webp'
	}
	return ''
}

fn (app &App) art_path(id int) string {
	return os.join_path(app.data_dir, 'art', id.str())
}

fn (app &App) artwork(it Item) ?string {
	own := app.art_path(it.id)
	if os.exists(own) && os.file_size(own) > 0 {
		return own
	}
	for name in ['cover.jpg', 'cover.png', 'folder.jpg', 'front.jpg'] {
		sidecar := os.join_path(os.dir(it.path), name)
		if os.exists(sidecar) {
			return sidecar
		}
	}
	if !os.exists(own) && app.ffmpeg != '' {
		app.ffmpeg_image(['-i', it.path, '-an'], own)
		if os.exists(own) && os.file_size(own) > 0 {
			return own
		}
		os.write_file(own, '') or {}
	}
	return none
}

fn (app &App) ffmpeg_image(input []string, out string) {
	tmp := '${out}.${rand.u32()}.tmp'
	mut args := ['-v', 'quiet', '-y']
	args << input
	args << ['-frames:v', '1', '-f', 'mjpeg', tmp]
	run(app.ffmpeg, args)
	if os.file_size(tmp) > 0 {
		os.mv(tmp, out) or {}
	}
	os.rm(tmp) or {}
}

const thumb_sizes = [128, 320, 640]

fn (app &App) thumb(path string, id int, want int) string {
	if want <= 0 || want > thumb_sizes.last() || app.ffmpeg == '' {
		return path
	}
	size := thumb_sizes.filter(it >= want)[0]
	out := '${app.art_path(id)}.${size}'
	if !os.exists(out) || os.file_last_mod_unix(out) < os.file_last_mod_unix(path) {
		app.ffmpeg_image(['-i', path, '-vf', "scale='min(${size},iw)':-2", '-q:v', '4'], out)
	}
	return if os.file_size(out) > 0 { out } else { path }
}

// Free functions on purpose: veb exposes every App method that takes a Context as a route.
fn send_artwork(mut ctx Context, app &App, it Item, size int) veb.Result {
	full := app.artwork(it) or { return fail(mut ctx, .not_found, 'no artwork') }
	path := app.thumb(full, it.id, size)
	data := os.read_file(path) or { return fail(mut ctx, .not_found, 'no artwork') }
	mime := image_mime(data)
	// public lets the CDN cache covers, which it then serves without sign-in.
	ctx.set_header(.cache_control, 'public, max-age=86400')
	return ctx.send_response_to_client(if mime != '' { mime } else { 'image/jpeg' }, data)
}

struct Me {
	setup_needed  bool
	authenticated bool
	name          string
	admin         bool
	scopes        []string
	version       string
}

@['/api/v1/me']
pub fn (mut app App) me(mut ctx Context) veb.Result {
	setup_needed := app.get('admin_hash') == ''
	p := app.identify(ctx) or {
		return ctx.json(Me{
			setup_needed: setup_needed
			version:      version
		})
	}
	return ctx.json(Me{
		authenticated: true
		name:          p.name
		admin:         p.admin
		scopes:        p.scopes
		version:       version
	})
}

fn start_session(mut ctx Context, mut app App) veb.Result {
	now := time.now().unix()
	token := new_token()
	lifetime := 30 * 86400
	app.db.exec_param('delete from sessions where expires < ?', now.str()) or {}
	app.db.exec_param_many('insert into sessions (token, expires) values (?, ?)', [
		sha256.hexhash(token),
		(now + lifetime).str(),
	]) or { return fail(mut ctx, .internal_server_error, err.msg()) }
	ctx.set_cookie(http.Cookie{
		name:      'vlyra_session'
		value:     token
		path:      '/'
		http_only: true
		same_site: .same_site_strict_mode
		max_age:   lifetime
	})
	return ok(mut ctx)
}

@['/api/v1/setup'; post]
pub fn (mut app App) setup(mut ctx Context) veb.Result {
	if app.get('admin_hash') != '' {
		return fail(mut ctx, .conflict, 'already set up')
	}
	password := (body(ctx)['password'] or { json2.Any('') }).str()
	if password.len < 8 {
		return fail(mut ctx, .bad_request, 'password must be at least 8 characters')
	}
	hash := bcrypt.generate_from_password(password.bytes(), 10) or {
		return fail(mut ctx, .internal_server_error, err.msg())
	}
	app.set('admin_hash', hash)
	return start_session(mut ctx, mut app)
}

@['/api/v1/session'; post]
pub fn (mut app App) login(mut ctx Context) veb.Result {
	password := (body(ctx)['password'] or { json2.Any('') }).str()
	hash := app.get('admin_hash')
	if hash == '' {
		return fail(mut ctx, .unauthorized, 'wrong password')
	}
	bcrypt.compare_hash_and_password(password.bytes(), hash.bytes()) or {
		return fail(mut ctx, .unauthorized, 'wrong password')
	}
	return start_session(mut ctx, mut app)
}

@['/api/v1/session'; delete]
pub fn (mut app App) logout(mut ctx Context) veb.Result {
	app.db.exec_param('delete from sessions where token = ?', sha256.hexhash(ctx.get_cookie('vlyra_session') or {
		''
	})) or {}
	return ok(mut ctx)
}

struct ItemPage {
	items  []Item
	total  int
	rating int
}

@['/api/v1/items']
pub fn (mut app App) list_items(mut ctx Context) veb.Result {
	p := app.auth(ctx, 'library:read') or { return deny(mut ctx, err) }
	mut limit := ctx.query['limit'].int()
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	if 'album' in ctx.query {
		found := app.items('where missing = 0 and ${album_match} order by track_no, title collate nocase', [
			ctx.query['artist'],
			ctx.query['album'],
		])
		rating := if p.can('ratings:read') {
			app.album_rating(ctx.query['artist'], ctx.query['album'])
		} else {
			0
		}
		return ctx.send_response_to_client('application/json', encode_item_page_json(&found,
			found.len, rating))
	}
	offset := if ctx.query['offset'].int() > 0 { ctx.query['offset'].int() } else { 0 }
	q_str := ctx.query['q'].trim_space()
	if q_str == '' {
		total := app.reader().q_int('select count(*) from items where missing = 0') or { 0 }
		found := app.items('where missing = 0 order by artist collate nocase, album collate nocase, track_no, title collate nocase limit ? offset ?', [
			limit.str(),
			offset.str(),
		])
		return ctx.send_response_to_client('application/json', encode_item_page_json(&found,
			total, 0))
	}
	found := app.search_items_fts(q_str, '', false, '', limit, offset)
	total := app.search_items_fts_count(q_str, '', false, '')
	return ctx.send_response_to_client('application/json', encode_item_page_json(&found,
		total, 0))
}

@['/api/v1/albums']
pub fn (mut app App) list_albums(mut ctx Context) veb.Result {
	p := app.auth(ctx, 'library:read') or { return deny(mut ctx, err) }
	q_str := ctx.query['q'].trim_space()
	rated := p.can('ratings:read')
	found := if q_str == '' {
		app.albums_mat(rated, 'order by album_artist collate nocase, year, album collate nocase',
			[])
	} else {
		app.search_albums_fts(rated, q_str, '', 100000, 0)
	}
	return ctx.send_response_to_client('application/json', encode_albums_json(&found))
}

@['/api/v1/albums/rating'; put]
pub fn (mut app App) put_album_rating(mut ctx Context) veb.Result {
	p := app.auth(ctx, 'ratings:write') or { return deny(mut ctx, err) }
	b := body(ctx)
	app.rate_album(p, (b['artist'] or { json2.Any('') }).str(),
		(b['album'] or { json2.Any('') }).str(), (b['rating'] or { json2.Any(-1) }).int()) or {
		return fail(mut ctx, if err.msg() == 'no such album' { .not_found } else { .bad_request },
			err.msg())
	}
	return ok(mut ctx)
}

@['/api/v1/items/:id']
pub fn (mut app App) get_item(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'library:read') or { return deny(mut ctx, err) }
	it := app.item(id) or { return fail(mut ctx, .not_found, 'no such item') }
	return ctx.json(it)
}

@['/api/v1/items/:id'; patch]
pub fn (mut app App) patch_item(mut ctx Context, id int) veb.Result {
	p := app.auth(ctx, 'library:write') or { return deny(mut ctx, err) }
	changes := body(ctx)
	for field, _ in changes {
		if field !in item_fields {
			return fail(mut ctx, .bad_request,
				'unknown field "${field}"; writable: ${item_fields.join(', ')}')
		}
	}
	for field, value in changes {
		app.set_item_field(p, id, field, value.str()) or {
			return fail(mut ctx, .not_found, err.msg())
		}
	}
	it := app.item(id) or { return fail(mut ctx, .not_found, 'no such item') }
	return ctx.json(it)
}

@['/api/v1/items/:id/stream']
pub fn (mut app App) stream_item(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'library:read') or { return deny(mut ctx, err) }
	it := app.item(id) or { return fail(mut ctx, .not_found, 'no such item') }
	return serve_media(mut ctx, it.path)
}

@['/api/v1/items/:id/lyrics']
pub fn (mut app App) get_lyrics(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'lyrics:read') or { return deny(mut ctx, err) }
	return ctx.json({
		'text': app.lyrics(id)
	})
}

@['/api/v1/items/:id/lyrics'; put]
pub fn (mut app App) put_lyrics(mut ctx Context, id int) veb.Result {
	p := app.auth(ctx, 'lyrics:write') or { return deny(mut ctx, err) }
	text :=
		(body(ctx)['text'] or { return fail(mut ctx, .bad_request, 'expected {"text": "..."}') }).str()
	app.set_lyrics(p, id, text) or { return fail(mut ctx, .not_found, err.msg()) }
	return ok(mut ctx)
}

@['/api/v1/items/:id/artwork']
pub fn (mut app App) get_artwork(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'artwork:read') or { return deny(mut ctx, err) }
	it := app.item(id) or { return fail(mut ctx, .not_found, 'no such item') }
	return send_artwork(mut ctx, app, it, ctx.query['size'].int())
}

@['/api/v1/items/:id/artwork'; put]
pub fn (mut app App) put_artwork(mut ctx Context, id int) veb.Result {
	p := app.auth(ctx, 'artwork:write') or { return deny(mut ctx, err) }
	app.set_artwork(p, id, ctx.req.data) or {
		return fail(mut ctx, if err.msg() == 'no such item' { .not_found } else { .bad_request },
			err.msg())
	}
	return ok(mut ctx)
}

fn (mut app App) set_artwork(p Principal, id int, data string) ! {
	it := app.item(id) or { return error('no such item') }
	if image_mime(data) == '' || data.len > max_artwork {
		return error('body must be a JPEG, PNG, WebP or GIF image up to 10 MB')
	}
	os.write_file(app.art_path(id), data)!
	for size in thumb_sizes {
		os.rm('${app.art_path(id)}.${size}') or {}
	}
	app.log(p, 'item', id, it.title, 'artwork', '', '${image_mime(data)}, ${data.len / 1024} KB')
}

struct PlaylistDetail {
	id         int
	name       string
	owner      string
	created_at i64
	items      []Item
}

fn (app &App) playlist_detail(id int) ?PlaylistDetail {
	pl := app.playlist(id)?
	return PlaylistDetail{
		id:         pl.id
		name:       pl.name
		owner:      pl.owner
		created_at: pl.created_at
		items:      app.playlist_items(id)
	}
}

fn int_list(v json2.Any) []int {
	return v.as_array().map(it.int())
}

@['/api/v1/playlists']
pub fn (mut app App) list_playlists(mut ctx Context) veb.Result {
	app.auth(ctx, 'playlists:read') or { return deny(mut ctx, err) }
	rows := app.reader().exec('select id, name, owner, created_at from playlists order by name') or {
		return ctx.json([]Playlist{})
	}
	return ctx.json(rows.map(Playlist{
		id:         it.vals[0].int()
		name:       it.vals[1]
		owner:      it.vals[2]
		created_at: it.vals[3].i64()
	}))
}

@['/api/v1/playlists'; post]
pub fn (mut app App) create_playlist(mut ctx Context) veb.Result {
	p := app.auth(ctx, 'playlists:write') or { return deny(mut ctx, err) }
	b := body(ctx)
	id := app.save_playlist(p, 0, (b['name'] or { json2.Any('') }).str(), int_list(b['item_ids'] or {
		json2.Any([]json2.Any{})
	})) or { return fail(mut ctx, .bad_request, err.msg()) }
	return ctx.json(app.playlist_detail(id) or { return fail(mut ctx, .not_found, 'gone') })
}

@['/api/v1/playlists/:id']
pub fn (mut app App) get_playlist(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'playlists:read') or { return deny(mut ctx, err) }
	return ctx.json(app.playlist_detail(id) or {
		return fail(mut ctx, .not_found, 'no such playlist')
	})
}

@['/api/v1/playlists/:id'; put]
pub fn (mut app App) put_playlist(mut ctx Context, id int) veb.Result {
	p := app.auth(ctx, 'playlists:write') or { return deny(mut ctx, err) }
	b := body(ctx)
	ids := if v := b['item_ids'] { int_list(v) } else { app.playlist_items(id).map(it.id) }
	app.save_playlist(p, id, (b['name'] or { json2.Any('') }).str(), ids) or {
		return fail(mut ctx, .not_found, err.msg())
	}
	return ctx.json(app.playlist_detail(id) or { return fail(mut ctx, .not_found, 'gone') })
}

@['/api/v1/playlists/:id'; delete]
pub fn (mut app App) remove_playlist(mut ctx Context, id int) veb.Result {
	p := app.auth(ctx, 'playlists:write') or { return deny(mut ctx, err) }
	app.delete_playlist(p, id) or { return fail(mut ctx, .not_found, err.msg()) }
	return ok(mut ctx)
}

struct PlayView {
	id       int
	item_id  int
	title    string
	artist   string
	app_name string
	at       i64
}

@['/api/v1/plays']
pub fn (mut app App) list_plays(mut ctx Context) veb.Result {
	app.auth(ctx, 'history:read') or { return deny(mut ctx, err) }
	rows := app.reader().exec('select p.id, p.item_id, i.title, i.artist, p.app_name, p.at from plays p join items i on i.id = p.item_id order by p.id desc limit 200') or {
		return fail(mut ctx, .internal_server_error, err.msg())
	}
	return ctx.json(rows.map(PlayView{
		id:       it.vals[0].int()
		item_id:  it.vals[1].int()
		title:    it.vals[2]
		artist:   it.vals[3]
		app_name: it.vals[4]
		at:       it.vals[5].i64()
	}))
}

@['/api/v1/plays'; post]
pub fn (mut app App) add_play(mut ctx Context) veb.Result {
	p := app.auth(ctx, 'history:write') or { return deny(mut ctx, err) }
	b := body(ctx)
	app.record_play(p, (b['item_id'] or { json2.Any(0) }).int(),
		(b['at'] or { json2.Any(0) }).i64()) or { return fail(mut ctx, .not_found, err.msg()) }
	return ok(mut ctx)
}

fn clean_scopes(v json2.Any) !string {
	mut out := []string{}
	for s in v.as_array() {
		scope := s.str()
		if !valid_scope(scope) {
			return error('unknown permission "${scope}"')
		}
		if scope !in out {
			out << scope
		}
	}
	return out.join(' ')
}

@['/api/v1/apps']
pub fn (mut app App) list_apps(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	rows := app.reader().exec('select id, name, subsonic_password, scopes, enabled, created_at, last_seen from apps order by name') or {
		return ctx.json([]ClientApp{})
	}
	return ctx.json(rows.map(ClientApp{
		id:                it.vals[0].int()
		name:              it.vals[1]
		token_hash:        ''
		subsonic_password: if it.vals[2] != '' { 'set' } else { '' }
		scopes:            it.vals[3]
		enabled:           it.vals[4] == '1'
		created_at:        it.vals[5].i64()
		last_seen:         app.live_last_seen(it.vals[0].int(), it.vals[6].i64())
	}))
}

struct NewApp {
	id                int
	name              string
	token             string
	subsonic_password string
}

@['/api/v1/apps'; post]
pub fn (mut app App) create_app(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	b := body(ctx)
	name := (b['name'] or { json2.Any('') }).str().trim_space()
	if name == '' || name.len > 64 || name == 'admin' {
		return fail(mut ctx, .bad_request, 'choose a name (up to 64 characters, not "admin")')
	}
	scopes := clean_scopes(b['scopes'] or { json2.Any([]json2.Any{}) }) or {
		return fail(mut ctx, .bad_request, err.msg())
	}
	secret := NewApp{
		name:              name
		token:             new_token()
		subsonic_password: if (b['subsonic'] or { json2.Any(false) }).bool() {
			new_token()[..24]
		} else {
			''
		}
	}
	rows := app.db.exec_param_many('insert into apps (name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen) values (?, ?, ?, ?, 1, ?, 0) returning id', [
		name,
		sha256.hexhash(secret.token),
		secret.subsonic_password,
		scopes,
		time.now().unix().str(),
	]) or { return fail(mut ctx, .conflict, 'an app named "${name}" already exists') }
	app.reload_apps()
	return ctx.json(NewApp{
		...secret
		id: rows[0].vals[0].int()
	})
}

@['/api/v1/apps/:id'; put]
pub fn (mut app App) update_app(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	b := body(ctx)
	if v := b['scopes'] {
		scopes := clean_scopes(v) or { return fail(mut ctx, .bad_request, err.msg()) }
		app.db.exec_param_many('update apps set scopes = ? where id = ?', [scopes, id.str()]) or {}
	}
	if v := b['enabled'] {
		app.db.exec_param_many('update apps set enabled = ? where id = ?', [
			if v.bool() { '1' } else { '0' },
			id.str(),
		]) or {}
	}
	app.reload_apps()
	return ok(mut ctx)
}

@['/api/v1/apps/:id'; delete]
pub fn (mut app App) delete_app(mut ctx Context, id int) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	app.db.exec_param('delete from apps where id = ?', id.str()) or {}
	app.reload_apps()
	return ok(mut ctx)
}

@['/api/v1/activity']
pub fn (mut app App) activity(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	item_id := ctx.query['item_id'].int()
	app_id := ctx.query['app_id'].int()
	const_cols := 'id, app_id, app_name, entity, entity_id, label, field, old_value, new_value, at'
	rows := if item_id > 0 {
		app.reader().exec_param("select ${const_cols} from contributions where entity = 'item' and entity_id = ? order by id desc limit 200",
			item_id.str()) or { [] }
	} else if 'app_id' in ctx.query {
		app.reader().exec_param('select ${const_cols} from contributions where app_id = ? order by id desc limit 200',
			app_id.str()) or { [] }
	} else {
		app.reader().exec('select ${const_cols} from contributions order by id desc limit 200') or {
			[]
		}
	}
	return ctx.json(rows.map(Contribution{
		id:        it.vals[0].int()
		app_id:    it.vals[1].int()
		app_name:  it.vals[2]
		entity:    it.vals[3]
		entity_id: it.vals[4].int()
		label:     it.vals[5]
		field:     it.vals[6]
		old_value: it.vals[7]
		new_value: it.vals[8]
		at:        it.vals[9].i64()
	}))
}

struct ProtocolInfo {
	id       string
	name     string
	enabled  bool
	endpoint string
	about    string
}

struct Settings {
	media_dir    string
	scanning     bool
	items        int
	ffprobe      bool
	version      string
	protocols    []ProtocolInfo
	listenbrainz string
	lastfm       string
}

@['/api/v1/settings']
pub fn (mut app App) get_settings(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	return ctx.json(Settings{
		media_dir:    app.get('media_dir')
		scanning:     app.scanning
		items:        app.reader().q_int('select count(*) from items where missing = 0') or { 0 }
		ffprobe:      app.ffprobe != ''
		version:      version
		listenbrainz: app.get('listenbrainz.user')
		lastfm:       app.get('lastfm.user')
		protocols:    [
			ProtocolInfo{'native', 'Vlyra API', app.protocol_on('native'), '/api/v1', 'Full read and write access for integrations, using a bearer token.'},
			ProtocolInfo{'jellyfin', 'Jellyfin', app.protocol_on('jellyfin'), '/', 'For Jellyfin music clients. Sign in with an app name as the username and its API token as the password. Like Jellyfin itself, cover images are served without sign-in while this is on.'},
			ProtocolInfo{'subsonic', 'Subsonic', app.protocol_on('subsonic'), '/rest', "For Subsonic and OpenSubsonic clients. Sign in with an app name as the username and that app's Subsonic password."},
		]
	})
}

@['/api/v1/settings'; put]
pub fn (mut app App) put_settings(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	b := body(ctx)
	if v := b['media_dir'] {
		dir := os.real_path(v.str().trim_space())
		if !os.is_dir(dir) {
			return fail(mut ctx, .bad_request, 'not a folder on this server: ${v.str()}')
		}
		app.set('media_dir', dir)
		spawn app.scan()
	}
	if v := b['protocols'] {
		for name, on in v.as_map() {
			if name !in protocols {
				return fail(mut ctx, .bad_request, 'unknown protocol "${name}"')
			}
			app.set('proto.${name}', if on.bool() { '1' } else { '0' })
		}
	}
	return ok(mut ctx)
}

@['/api/v1/scan'; post]
pub fn (mut app App) start_scan(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	spawn app.scan()
	return ok(mut ctx)
}

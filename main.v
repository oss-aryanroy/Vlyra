module main

import db.sqlite
import flag
import os
import runtime
import sync.stdatomic
import veb

const version = '0.1.0'

const web_index = $embed_file('web/index.html')
const web_css = $embed_file('web/app.css')
const web_js = $embed_file('web/app.js')

pub struct Context {
	veb.Context
}

pub struct App {
pub mut:
	db       sqlite.DB
	reads    []sqlite.DB
	next     u64
	data_dir string
	ffprobe  string
	ffmpeg   string
	scanning bool
}

fn new_app(db_path string, data_dir string) !&App {
	mut app := &App{
		// fullmutex: veb serves requests on several threads over this one connection.
		db:       sqlite.connect_full(db_path, [.readwrite, .create, .fullmutex], '')!
		data_dir: data_dir
		ffprobe:  os.find_abs_path_of_executable('ffprobe') or { '' }
		ffmpeg:   os.find_abs_path_of_executable('ffmpeg') or { '' }
	}
	app.db.busy_timeout(5000)
	if db_path != ':memory:' {
		// It holds Subsonic passwords.
		os.chmod(db_path, 0o600)!
	}
	app.migrate()!
	if db_path != ':memory:' {
		app.db.exec('pragma journal_mode = wal')!
		app.db.exec('pragma synchronous = normal')!
		for _ in 0 .. runtime.nr_cpus() {
			mut r := sqlite.connect_full(db_path, [.readonly, .fullmutex], '')!
			r.busy_timeout(5000)
			app.reads << r
		}
	}
	return app
}

// Reads spread over the pool so they run in parallel; writes stay on app.db.
fn (app &App) reader() sqlite.DB {
	if app.reads.len == 0 {
		return app.db
	}
	return app.reads[stdatomic.add_u64(&app.next, 1) % u64(app.reads.len)]
}

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	return ctx.html(web_index.to_string())
}

@['/app.css']
pub fn (mut app App) css(mut ctx Context) veb.Result {
	return ctx.send_response_to_client('text/css', web_css.to_string())
}

@['/app.js']
pub fn (mut app App) js(mut ctx Context) veb.Result {
	return ctx.send_response_to_client('text/javascript', web_js.to_string())
}

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('vlyra')
	fp.version(version)
	fp.description('Open, protocol-independent media server.')
	fp.skip_executable()
	port := fp.int('port', `p`, 4040, 'port to listen on')
	host := fp.string('host', 0, '0.0.0.0', 'address to bind')
	data_dir := os.real_path(fp.string('data', `d`, 'data',
		'directory for the database and artwork'))
	media := fp.string('media', `m`, '', 'media folder (can also be set in the web UI)')
	fp.finalize() or {
		eprintln(err)
		exit(1)
	}
	os.mkdir_all(os.join_path(data_dir, 'art')) or { panic(err) }
	mut app := new_app(os.join_path(data_dir, 'vlyra.db'), data_dir) or { panic(err) }
	if media != '' {
		app.set('media_dir', os.real_path(media))
	}
	if app.ffprobe == '' {
		eprintln('warning: ffprobe not found, videos and some exotic formats will have no tags or duration')
	}
	spawn app.watch()
	veb.run_at[App, Context](mut app, host: host, port: port) or { panic(err) }
}

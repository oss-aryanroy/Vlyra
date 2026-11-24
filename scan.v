module main

import os
import runtime
import time
import x.json2

const media_types = {
	'.mp3':  'audio/mpeg'
	'.flac': 'audio/flac'
	'.m4a':  'audio/mp4'
	'.aac':  'audio/aac'
	'.ogg':  'audio/ogg'
	'.opus': 'audio/ogg'
	'.wav':  'audio/wav'
	'.oga':  'audio/ogg'
	'.m4b':  'audio/mp4'
	'.aiff': 'audio/aiff'
	'.aif':  'audio/aiff'
	'.wma':  'audio/x-ms-wma'
	'.wv':   'audio/x-wavpack'
	'.ape':  'audio/x-ape'
	'.mka':  'audio/x-matroska'
	'.mp4':  'video/mp4'
	'.m4v':  'video/mp4'
	'.webm': 'video/webm'
	'.mkv':  'video/x-matroska'
	'.mov':  'video/quicktime'
}

#flag linux -D_GNU_SOURCE
#include <sys/stat.h>
#include <fcntl.h>

struct C.statx_timestamp {
	tv_sec i64
}

struct C.statx {
	stx_mask  u32
	stx_btime C.statx_timestamp
}

fn C.statx(dirfd int, path &char, flags int, mask u32, buf &C.statx) int

// When the file arrived on this disk: its birth time where the filesystem
// records one, else its mtime. Never later than now (bad clocks, future mtimes).
fn file_added(path string) i64 {
	mut t := os.file_last_mod_unix(path)
	$if linux {
		mut sx := C.statx{}
		if C.statx(C.AT_FDCWD, &char(path.str), 0, C.STATX_BTIME, &sx) == 0
			&& sx.stx_mask & C.STATX_BTIME != 0 && sx.stx_btime.tv_sec > 0 {
			t = sx.stx_btime.tv_sec
		}
	} $else $if macos {
		mut st := C.stat{}
		if unsafe { C.stat(&char(path.str), &st) } == 0 && st.st_birthtime > 0 {
			t = st.st_birthtime
		}
	}
	now := time.now().unix()
	return if t > 0 && t < now { t } else { now }
}

// os.exec, not os.Process: Process forks and runs V code in the child, which
// deadlocks if another thread held the allocator lock at that moment.
fn run(exe string, args []string) string {
	mut argv := [exe]
	argv << args
	return os.exec(argv).output
}

fn probe_file(ffprobe string, path string) Item {
	ext := os.file_ext(path).to_lower()
	mut it := Item{
		path:     path
		kind:     if media_types[ext].starts_with('video') { 'video' } else { 'audio' }
		title:    os.file_name(path).all_before_last('.')
		size:     i64(os.file_size(path))
		added_at: file_added(path)
		mtime:    os.file_last_mod_unix(path)
	}
	if it.kind == 'audio' {
		if nt := native_tags(path, ext) {
			it.duration = nt.duration
			if nt.title != '' {
				it.title = nt.title
			}
			it.artist = nt.artist
			it.album_artist = if nt.album_artist != '' { nt.album_artist } else { nt.artist }
			it.album = nt.album
			it.genre = nt.genre
			it.year = nt.date.int()
			it.track_no = nt.track.int()
			if nt.duration > 0 {
				return it
			}
		}
	}
	if ffprobe == '' {
		return it
	}
	out := run(ffprobe, ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams',
		path])
	root := (json2.decode[json2.Any](out) or { return it }).as_map()
	format := (root['format'] or { return it }).as_map()
	it.duration = int((format['duration'] or { json2.Any('0') }).str().f64())
	mut tags := map[string]string{}
	mut sources := [format]
	for s in (root['streams'] or { json2.Any([]json2.Any{}) }).as_array() {
		sources << s.as_map()
	}
	for src in sources {
		for k, v in (src['tags'] or { continue }).as_map() {
			if k.to_lower() !in tags {
				tags[k.to_lower()] = v.str()
			}
		}
	}
	if tags['title'] != '' {
		it.title = tags['title']
	}
	if tags['artist'] != '' {
		it.artist = tags['artist']
	}
	album_artist := if tags['album_artist'] != '' { tags['album_artist'] } else { tags['artist'] }
	if album_artist != '' {
		it.album_artist = album_artist
	}
	if tags['album'] != '' {
		it.album = tags['album']
	}
	if tags['genre'] != '' {
		it.genre = tags['genre']
	}
	if tags['date'].int() != 0 {
		it.year = tags['date'].int()
	}
	if tags['track'].int() != 0 {
		it.track_no = tags['track'].int()
	}
	return it
}

fn probe_worker(ffprobe string, paths chan string, out chan Item) {
	for {
		path := <-paths or { return }
		out <- probe_file(ffprobe, path)
	}
}

fn push_all(paths chan string, fresh []string) {
	for p in fresh {
		paths <- p
	}
	paths.close()
}

fn (mut app App) watch() {
	for {
		app.scan()
		time.sleep(5 * time.second)
	}
}

fn (mut app App) scan() {
	if app.scanning {
		return
	}
	app.scanning = true
	defer {
		app.scanning = false
	}
	dir := app.get('media_dir')
	if dir == '' || !os.is_dir(dir) {
		return
	}
	mut known := map[string]bool{}
	mut mtimes := map[string]i64{}
	for r in app.db.exec('select path, missing, mtime from items') or { return } {
		known[r.vals[0]] = r.vals[1] == '1'
		mtimes[r.vals[0]] = r.vals[2].i64()
	}
	reread_all := app.get('tags_version') != tag_reader_version
	now := time.now().unix()
	mut seen := map[string]bool{}
	mut work := []string{}
	for path in os.walk_ext(dir, '') {
		if os.file_ext(path).to_lower() !in media_types || os.file_name(path).starts_with('.') {
			continue
		}
		seen[path] = true
		mtime := os.file_last_mod_unix(path)
		if mtime <= now && now - mtime < 2 {
			continue
		}
		if path !in known || reread_all || mtimes[path] != mtime {
			work << path
		}
	}
	mut changed := false
	if work.len > 0 {
		changed = true
		mut edited := map[string][]string{}
		for r in app.reader().exec("select i.path, c.field from contributions c join items i on i.id = c.entity_id where c.entity = 'item'") or {
			return
		} {
			edited[r.vals[0]] << r.vals[1]
		}
		mut workers := runtime.nr_cpus()
		if workers < 2 {
			workers = 2
		} else if workers > 16 {
			workers = 16
		}
		paths_ch := chan string{cap: 2 * workers}
		items_ch := chan Item{cap: 2 * workers}
		for _ in 0 .. workers {
			spawn probe_worker(app.ffprobe, paths_ch, items_ch)
		}
		spawn push_all(paths_ch, work)
		unsafe {
			mut c := app.cache
			c.tx_mu.lock()
		}
		app.db.exec('begin') or { eprintln('scan: ${err}') }
		for i, _ in work {
			it := <-items_ch
			if it.path in known {
				mut sets := ['duration = ?', 'size = ?', 'mtime = ?']
				mut vals := [it.duration.str(), it.size.str(),
					it.mtime.str()]
				for col, val in {
					'title':        it.title
					'artist':       it.artist
					'album_artist': it.album_artist
					'album':        it.album
					'genre':        it.genre
					'year':         it.year.str()
					'track_no':     it.track_no.str()
				} {
					if col !in edited[it.path] {
						sets << '${col} = ?'
						vals << val
					}
				}
				vals << it.path
				app.db.exec_param_many('update items set ${sets.join(', ')} where path = ?', vals) or {
					eprintln('scan: ${it.path}: ${err}')
				}
			} else {
				sql app.db {
					insert it into Item
				} or {
					eprintln('scan: ${it.path}: ${err}')
					0
				}
			}
			if (i + 1) % 500 == 0 {
				app.db.exec('commit') or { eprintln('scan: ${err}') }
				app.db.exec('begin') or { eprintln('scan: ${err}') }
			}
		}
		app.db.exec('commit') or { eprintln('scan: ${err}') }
		unsafe {
			mut c := app.cache
			c.tx_mu.unlock()
		}
	}
	if reread_all {
		app.set('tags_version', tag_reader_version)
	}
	// Rows scanned before file_added existed carry their scan time; fix them once.
	if app.get('added_from_files') == '' {
		unsafe {
			mut c := app.cache
			c.tx_mu.lock()
		}
		app.db.exec('begin') or {}
		for path, _ in seen {
			if path in known {
				app.db.exec_param_many('update items set added_at = ? where path = ?', [
					file_added(path).str(),
					path,
				]) or { eprintln('scan: ${path}: ${err}') }
			}
		}
		app.db.exec('commit') or { eprintln('scan: ${err}') }
		unsafe {
			mut c := app.cache
			c.tx_mu.unlock()
		}
		app.set('added_from_files', '1')
		changed = true
	}
	mut unmiss := []string{}
	for path, _ in seen {
		if path in known && known[path] {
			unmiss << path
		}
	}
	mut miss := []string{}
	for path, was_missing in known {
		if !was_missing && path !in seen {
			miss << path
		}
	}
	if unmiss.len > 0 || miss.len > 0 {
		changed = true
		unsafe {
			mut c := app.cache
			c.tx_mu.lock()
		}
		app.db.exec('begin immediate') or {}
		for path in unmiss {
			app.db.exec_param('update items set missing = 0 where path = ?', path) or {}
		}
		for path in miss {
			app.db.exec_param('update items set missing = 1 where path = ?', path) or {}
		}
		app.db.exec('commit') or {}
		unsafe {
			mut c := app.cache
			c.tx_mu.unlock()
		}
	}
	if changed {
		app.rebuild_catalog()
		app.db.exec('pragma optimize') or {}
	}
}

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
	stx_size  u64
	stx_btime C.statx_timestamp
	stx_mtime C.statx_timestamp
}

fn C.statx(dirfd int, path &char, flags int, mask u32, buf &C.statx) int

struct FileMeta {
	size     i64
	mtime    i64
	added_at i64
}

// Single-syscall stat gathering size, mtime, and birth time (when the filesystem records one).
fn file_meta(path string) FileMeta {
	now := time.now().unix()
	mut size := i64(-1)
	mut mtime := i64(0)
	mut btime := i64(0)
	$if linux {
		mut sx := C.statx{}
		if C.statx(C.AT_FDCWD, &char(path.str), 0, C.STATX_MTIME | C.STATX_SIZE | C.STATX_BTIME,
			&sx) == 0 {
			if sx.stx_mask & C.STATX_SIZE != 0 {
				size = i64(sx.stx_size)
			}
			if sx.stx_mask & C.STATX_MTIME != 0 {
				mtime = sx.stx_mtime.tv_sec
			}
			if sx.stx_mask & C.STATX_BTIME != 0 && sx.stx_btime.tv_sec > 0 {
				btime = sx.stx_btime.tv_sec
			}
		}
	} $else $if macos {
		mut st := C.stat{}
		if unsafe { C.stat(&char(path.str), &st) } == 0 {
			size = i64(st.st_size)
			mtime = i64(st.st_mtime)
			if st.st_birthtime > 0 {
				btime = st.st_birthtime
			}
		}
	}
	if size < 0 {
		size = i64(os.file_size(path))
	}
	if mtime == 0 {
		mtime = os.file_last_mod_unix(path)
	}
	added_src := if btime > 0 { btime } else { mtime }
	return FileMeta{
		size:     size
		mtime:    mtime
		added_at: if added_src > 0 && added_src < now { added_src } else { now }
	}
}

// When the file arrived on this disk: its birth time where the filesystem
// records one, else its mtime. Never later than now (bad clocks, future mtimes).
fn file_added(path string) i64 {
	return file_meta(path).added_at
}

// os.exec, not os.Process: Process forks and runs V code in the child, which
// deadlocks if another thread held the allocator lock at that moment.
fn run(exe string, args []string) string {
	mut argv := [exe]
	argv << args
	return os.exec(argv).output
}

struct ScanFile {
	path     string
	size     i64
	mtime    i64
	added_at i64
	recent   bool
}

struct ProbeResult {
	item   Item
	lyrics string
}

fn probe_file(ffprobe string, f ScanFile) ProbeResult {
	ext := os.file_ext(f.path).to_lower()
	meta := if f.mtime != 0 && f.added_at != 0 {
		FileMeta{
			size:     f.size
			mtime:    f.mtime
			added_at: f.added_at
		}
	} else {
		file_meta(f.path)
	}
	mut it := Item{
		path:     f.path
		kind:     if media_types[ext].starts_with('video') { 'video' } else { 'audio' }
		title:    os.file_name(f.path).all_before_last('.')
		size:     meta.size
		mtime:    meta.mtime
		added_at: meta.added_at
	}
	mut lyrics := ''
	if it.kind == 'audio' {
		if nt := native_tags_sized(f.path, ext, meta.size) {
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
			it.disc_no = nt.disc.int()
			it.bitrate = nt.bitrate
			it.sample_rate = nt.sample_rate
			it.bit_depth = nt.bit_depth
			it.channels = nt.channels
			it.rg_track_gain = nt.rg_track_gain
			it.rg_album_gain = nt.rg_album_gain
			it.rg_track_peak = nt.rg_track_peak
			it.rg_album_peak = nt.rg_album_peak
			lyrics = nt.lyrics
			if nt.duration > 0 {
				return ProbeResult{
					item:   it
					lyrics: lyrics
				}
			}
		}
	}
	if ffprobe == '' {
		return ProbeResult{
			item:   it
			lyrics: lyrics
		}
	}
	out := run(ffprobe, ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams',
		f.path])
	root := (json2.decode[json2.Any](out) or {
		return ProbeResult{
			item:   it
			lyrics: lyrics
		}
	}).as_map()
	format := (root['format'] or {
		return ProbeResult{
			item:   it
			lyrics: lyrics
		}
	}).as_map()
	it.duration = int((format['duration'] or { json2.Any('0') }).str().f64())
	mut tags := map[string]string{}
	mut sources := [format]
	for s in (root['streams'] or { json2.Any([]json2.Any{}) }).as_array() {
		sm := s.as_map()
		sources << sm
		if (sm['codec_type'] or { json2.Any('') }).str() == 'audio' {
			if it.sample_rate == 0 {
				it.sample_rate = (sm['sample_rate'] or { json2.Any('0') }).int()
			}
			if it.channels == 0 {
				it.channels = (sm['channels'] or { json2.Any('0') }).int()
			}
			if it.bit_depth == 0 {
				bprs := (sm['bits_per_raw_sample'] or { json2.Any('0') }).int()
				it.bit_depth = if bprs > 0 {
					bprs
				} else {
					(sm['bits_per_sample'] or { json2.Any('0') }).int()
				}
			}
			if it.bitrate == 0 {
				it.bitrate = (sm['bit_rate'] or { json2.Any('0') }).int() / 1000
			}
		}
	}
	if it.bitrate == 0 {
		it.bitrate = (format['bit_rate'] or { json2.Any('0') }).int() / 1000
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
	if tags['disc'].int() != 0 && it.disc_no == 0 {
		it.disc_no = tags['disc'].int()
	}
	if it.rg_track_gain == 0 && tags['replaygain_track_gain'] != '' {
		it.rg_track_gain = parse_rg_db(tags['replaygain_track_gain'])
	}
	if it.rg_album_gain == 0 && tags['replaygain_album_gain'] != '' {
		it.rg_album_gain = parse_rg_db(tags['replaygain_album_gain'])
	}
	if it.rg_track_peak == 0 && tags['replaygain_track_peak'] != '' {
		it.rg_track_peak = tags['replaygain_track_peak'].trim_space().f64()
	}
	if it.rg_album_peak == 0 && tags['replaygain_album_peak'] != '' {
		it.rg_album_peak = tags['replaygain_album_peak'].trim_space().f64()
	}
	if lyrics == '' && tags['lyrics'] != '' {
		lyrics = tags['lyrics']
	}
	return ProbeResult{
		item:   it
		lyrics: lyrics
	}
}

fn probe_worker(ffprobe string, files chan ScanFile, out chan ProbeResult) {
	for {
		f := <-files or { return }
		out <- probe_file(ffprobe, f)
	}
}

fn push_all(files chan ScanFile, fresh []ScanFile) {
	for f in fresh {
		files <- f
	}
	files.close()
}

fn walk_media(root string, mut files []ScanFile, mut dirs map[string]i64, now i64) bool {
	dirs[root] = os.file_last_mod_unix(root)
	entries := os.ls(root) or { return false }
	mut had_recent := false
	for name in entries {
		if name.starts_with('.') {
			continue
		}
		p := os.join_path(root, name)
		if os.is_dir(p) {
			if walk_media(p, mut files, mut dirs, now) {
				had_recent = true
			}
			continue
		}
		if os.file_ext(name).to_lower() !in media_types {
			continue
		}
		m := file_meta(p)
		if m.mtime <= now && now - m.mtime < 2 {
			had_recent = true
			files << ScanFile{
				path:   p
				size:   m.size
				mtime:  m.mtime
				recent: true
			}
			continue
		}
		files << ScanFile{
			path:     p
			size:     m.size
			mtime:    m.mtime
			added_at: m.added_at
		}
	}
	return had_recent
}

fn (mut app App) watch() {
	mut tick := 0
	for {
		if tick % 12 == 0 {
			app.scan()
		} else {
			app.scan_fast()
		}
		tick++
		time.sleep(5 * time.second)
	}
}

fn (mut app App) scan_fast() {
	dir := app.get('media_dir')
	if dir == '' || !os.is_dir(dir) {
		return
	}
	if app.get('tags_version') != tag_reader_version || app.get('added_from_files') == '' {
		app.scan()
		return
	}
	mut cached_dir := ''
	mut cached_dirs := map[string]i64{}
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		cached_dir = c.scan_media_dir
		if cached_dir == dir && c.scan_dirs.len > 0 {
			cached_dirs = c.scan_dirs.clone()
		}
		c.mu.runlock()
	}
	if cached_dir != dir || cached_dirs.len == 0 {
		app.scan()
		return
	}
	for d, prev_mtime in cached_dirs {
		if !os.is_dir(d) || os.file_last_mod_unix(d) != prev_mtime {
			app.scan()
			return
		}
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
	mut files := []ScanFile{}
	mut dirs := map[string]i64{}
	had_recent := walk_media(dir, mut files, mut dirs, now)
	mut seen := map[string]bool{}
	mut work := []ScanFile{}
	for f in files {
		seen[f.path] = true
		if f.recent {
			continue
		}
		if f.path !in known || reread_all || mtimes[f.path] != f.mtime {
			work << f
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
		files_ch := chan ScanFile{cap: 2 * workers}
		items_ch := chan ProbeResult{cap: 2 * workers}
		for _ in 0 .. workers {
			spawn probe_worker(app.ffprobe, files_ch, items_ch)
		}
		spawn push_all(files_ch, work)
		unsafe {
			mut c := app.cache
			c.tx_mu.lock()
		}
		app.db.exec('begin') or { eprintln('scan: ${err}') }
		for i, _ in work {
			res := <-items_ch
			it := res.item
			if it.path in known {
				mut sets := ['duration = ?', 'size = ?', 'mtime = ?', 'bitrate = ?',
					'sample_rate = ?', 'bit_depth = ?', 'channels = ?', 'rg_track_gain = ?',
					'rg_album_gain = ?', 'rg_track_peak = ?', 'rg_album_peak = ?']
				mut vals := [it.duration.str(), it.size.str(), it.mtime.str(),
					it.bitrate.str(), it.sample_rate.str(), it.bit_depth.str(),
					it.channels.str(), it.rg_track_gain.str(), it.rg_album_gain.str(),
					it.rg_track_peak.str(), it.rg_album_peak.str()]
				for col, val in {
					'title':        it.title
					'artist':       it.artist
					'album_artist': it.album_artist
					'album':        it.album
					'genre':        it.genre
					'year':         it.year.str()
					'track_no':     it.track_no.str()
					'disc_no':      it.disc_no.str()
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
			if res.lyrics != '' {
				app.db.exec_param_many('insert or ignore into lyrics (item_id, text) values ((select id from items where path = ?), ?)', [
					it.path,
					res.lyrics,
				]) or {}
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
	unsafe {
		mut c := app.cache
		c.mu.lock()
		if had_recent {
			c.scan_media_dir = ''
			c.scan_dirs.clear()
		} else {
			c.scan_media_dir = dir
			c.scan_dirs = dirs.clone()
		}
		c.mu.unlock()
	}
}

module main

import os

// Readers must never panic (they run in scan workers); a file they can't read returns none for ffprobe.
// Bump tag_reader_version to make the next scan re-read every file, not only changed ones.
const tag_reader_version = '3'

struct NativeTags {
pub mut:
	title        string
	artist       string
	album_artist string
	album        string
	genre        string
	date         string
	track        string
	duration     int
}

fn native_tags(path string, ext string) ?NativeTags {
	match ext {
		'.mp3' {
			return mp3_tags(path)
		}
		'.flac' {
			return flac_tags(path)
		}
		'.m4a', '.m4b' {
			return mp4_tags(path)
		}
		'.ogg', '.oga', '.opus' {
			return ogg_tags(path)
		}
		'.wav' {
			return wav_tags(path)
		}
		'.aac' {
			return aac_tags(path)
		}
		else {}
	}

	return none
}

fn (mut t NativeTags) set(field string, val string) {
	if val == '' {
		return
	}
	match field {
		'title' {
			if t.title == '' { t.title = val }
		}
		'artist' {
			if t.artist == '' { t.artist = val }
		}
		'album' {
			if t.album == '' { t.album = val }
		}
		'album_artist' {
			if t.album_artist == '' { t.album_artist = val }
		}
		'genre' {
			if t.genre == '' { t.genre = val }
		}
		'date' {
			if t.date == '' { t.date = val }
		}
		'track' {
			if t.track == '' { t.track = val }
		}
		else {}
	}
}

fn take(b []u8, o int, n int) []u8 {
	if o < 0 || n < 0 || o + n > b.len {
		return []u8{}
	}
	return b[o..o + n]
}

fn txt(b []u8, o int, n int) string {
	return take(b, o, n).bytestr()
}

fn stxt(b []u8, o int, n int) string {
	raw := take(b, o, n)
	mut end := raw.len
	for end > 0 && raw[end - 1] == 0 {
		end--
	}
	return raw[..end].bytestr()
}

fn u16be(b []u8, o int) int {
	if o < 0 || o + 2 > b.len {
		return 0
	}
	return int(b[o]) << 8 | int(b[o + 1])
}

fn u16le(b []u8, o int) int {
	if o < 0 || o + 2 > b.len {
		return 0
	}
	return int(b[o + 1]) << 8 | int(b[o])
}

fn u32be(b []u8, o int) int {
	if o < 0 || o + 4 > b.len {
		return 0
	}
	return int(b[o]) << 24 | int(b[o + 1]) << 16 | int(b[o + 2]) << 8 | int(b[o + 3])
}

fn u32le(b []u8, o int) int {
	if o < 0 || o + 4 > b.len {
		return 0
	}
	return int(b[o + 3]) << 24 | int(b[o + 2]) << 16 | int(b[o + 1]) << 8 | int(b[o])
}

fn u64le(b []u8, o int) int {
	if o < 0 || o + 8 > b.len {
		return 0
	}
	mut v := i64(0)
	for i in 0 .. 8 {
		v |= i64(b[o + i]) << (8 * i)
	}
	return int(v)
}

fn u64be(b []u8, o int) int {
	if o < 0 || o + 8 > b.len {
		return 0
	}
	mut v := i64(0)
	for i in 0 .. 8 {
		v = v << 8 | i64(b[o + i])
	}
	return int(v)
}

fn syncsafe(b []u8, o int) int {
	if o < 0 || o + 4 > b.len {
		return 0
	}
	return int(b[o]) << 21 | int(b[o + 1]) << 14 | int(b[o + 2]) << 7 | int(b[o + 3])
}

struct Bin {
mut:
	f os.File
}

fn open_bin(path string) ?Bin {
	f := os.open(path) or { return none }
	return Bin{
		f: f
	}
}

fn (b &Bin) seg(off int, n int) []u8 {
	if n <= 0 || off < 0 {
		return []u8{}
	}
	return b.f.read_bytes_at(n, u64(off))
}

fn utf8_push(mut out []u8, cp int) {
	if cp < 0x80 {
		out << u8(cp)
	} else if cp < 0x800 {
		out << u8(0xc0 | cp >> 6)
		out << u8(0x80 | cp & 0x3f)
	} else if cp < 0x10000 {
		out << u8(0xe0 | cp >> 12)
		out << u8(0x80 | cp >> 6 & 0x3f)
		out << u8(0x80 | cp & 0x3f)
	} else {
		out << u8(0xf0 | cp >> 18)
		out << u8(0x80 | cp >> 12 & 0x3f)
		out << u8(0x80 | cp >> 6 & 0x3f)
		out << u8(0x80 | cp & 0x3f)
	}
}

fn latin1_to_utf8(b []u8) string {
	mut out := []u8{}
	for c in b {
		utf8_push(mut out, int(c))
	}
	return out.bytestr()
}

fn utf16_to_utf8(b []u8, big bool) string {
	mut out := []u8{}
	mut i := 0
	for i + 1 < b.len {
		mut cp := if big { u16be(b, i) } else { u16le(b, i) }
		if cp >= 0xd800 && cp <= 0xdbff && i + 3 < b.len {
			lo := if big { u16be(b, i + 2) } else { u16le(b, i + 2) }
			if lo >= 0xdc00 && lo <= 0xdfff {
				cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
				i += 2
			}
		}
		utf8_push(mut out, cp)
		i += 2
	}
	return out.bytestr()
}

const nul = [u8(0)].bytestr()

// Decode before trimming: a UTF-16 string's last byte is often a zero of its final character.
fn id3_text(enc u8, b []u8) string {
	s := match enc {
		0 {
			latin1_to_utf8(b)
		}
		1 {
			if b.len >= 2 && b[0] == 0xfe && b[1] == 0xff {
				utf16_to_utf8(b, true)
			} else {
				utf16_to_utf8(b, false)
			}
		}
		2 {
			utf16_to_utf8(b, true)
		}
		else {
			b.bytestr()
		}
	}

	return s.replace('\ufeff', '').split(nul).map(it.trim_space()).filter(it != '').join('; ')
}

fn parse_vorbis_comments(b []u8, from int, t0 NativeTags) NativeTags {
	mut t := t0
	mut off := from
	off += 4 + u32le(b, off)
	if off < from || off + 4 > b.len {
		return t
	}
	n := u32le(b, off)
	off += 4
	for _ in 0 .. int(n) {
		if off + 4 > b.len {
			return t
		}
		cl := u32le(b, off)
		off += 4
		if cl < 0 || cl > b.len - off {
			return t
		}
		kv := b[off..off + cl].bytestr()
		off += cl
		mut eq := -1
		for i in 0 .. kv.len {
			if kv[i] == 61 {
				eq = i
				break
			}
		}
		if eq <= 0 {
			continue
		}
		key := kv[..eq].to_lower()
		val := kv[eq + 1..].trim_space()
		if val == '' {
			continue
		}
		match key {
			'title', 'artist', 'album', 'genre', 'date' { t.set(key, val) }
			'year' { t.set('date', val) }
			'albumartist', 'album artist', 'album_artist' { t.set('album_artist', val) }
			'tracknumber', 'track' { t.set('track', val) }
			else {}
		}
	}
	return t
}

const id3_genres = ['Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', 'Hip-Hop',
	'Jazz', 'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B', 'Rap', 'Reggae', 'Rock', 'Techno',
	'Industrial', 'Alternative', 'Ska', 'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno',
	'Ambient', 'Trip-Hop', 'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical', 'Instrumental',
	'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', 'AlternRock', 'Bass', 'Soul', 'Punk',
	'Space', 'Meditative', 'Instrumental Pop', 'Instrumental Rock', 'Ethnic', 'Gothic', 'Darkwave',
	'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream', 'Southern Rock', 'Comedy',
	'Cult', 'Gangsta', 'Top 40', 'Christian Rap', 'Pop/Funk', 'Jungle', 'Native American', 'Cabaret',
	'New Wave', 'Psychedelic', 'Rave', 'Showtunes', 'Trailer', 'Lo-Fi', 'Tribal', 'Acid Punk',
	'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll', 'Hard Rock', 'Folk', 'Folk-Rock',
	'National Folk', 'Swing', 'Fast Fusion', 'Bebop', 'Latin', 'Revival', 'Celtic', 'Bluegrass',
	'Avantgarde', 'Gothic Rock', 'Progressive Rock', 'Psychedelic Rock', 'Symphonic Rock',
	'Slow Rock', 'Big Band', 'Chorus', 'Easy Listening', 'Acoustic', 'Humour', 'Speech', 'Chanson',
	'Opera', 'Chamber Music', 'Sonata', 'Symphony', 'Booty Bass', 'Primus', 'Porn Groove', 'Satire',
	'Slow Jam', 'Club', 'Tango', 'Samba', 'Folklore', 'Ballad', 'Power Ballad', 'Rhythmic Soul',
	'Freestyle', 'Duet', 'Punk Rock', 'Drum Solo', 'A Cappella', 'Euro-House', 'Dance Hall', 'Goa',
	'Drum & Bass', 'Club-House', 'Hardcore Techno', 'Terror', 'Indie', 'BritPop', 'Negerpunk',
	'Polsk Punk', 'Beat', 'Christian Gangsta Rap', 'Heavy Metal', 'Black Metal', 'Crossover',
	'Contemporary Christian', 'Christian Rock', 'Merengue', 'Salsa', 'Thrash Metal', 'Anime', 'Jpop',
	'Synthpop', 'Abstract', 'Art Rock', 'Baroque', 'Bhangra', 'Big Beat', 'Breakbeat', 'Chillout',
	'Downtempo', 'Dub', 'EBM', 'Eclectic', 'Electro', 'Electroclash', 'Emo', 'Experimental', 'Garage',
	'Global', 'IDM', 'Illbient', 'Industro-Goth', 'Jam Band', 'Krautrock', 'Leftfield', 'Lounge',
	'Math Rock', 'New Romantic', 'Nu-Breakz', 'Post-Punk', 'Post-Rock', 'Psytrance', 'Shoegaze',
	'Space Rock', 'Trop Rock', 'World Music', 'Neoclassical', 'Audiobook', 'Audio Theatre',
	'Neue Deutsche Welle', 'Podcast', 'Indie Rock', 'G-Funk', 'Dubstep', 'Garage Rock', 'Psybient']

fn all_digits(s string) bool {
	for c in s {
		if c < 48 || c > 57 {
			return false
		}
	}
	return s.len > 0
}

fn id3_genre(raw string) string {
	mut s := raw.trim_space()
	for s.starts_with('(') {
		end := s.index_after(')', 0) or { -1 }
		if end <= 1 || !all_digits(s[1..end]) {
			break
		}
		if end + 1 < s.len {
			s = s[end + 1..].trim_space()
		} else {
			s = s[1..end]
		}
	}
	if all_digits(s) && s.len < 4 && s.int() < id3_genres.len {
		return id3_genres[s.int()]
	}
	return s
}

const mp3_bitrate_v1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
const mp3_bitrate_v2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]

fn mpeg_rate(ver int, idx int) int {
	if idx > 2 {
		return 0
	}
	mut r := match idx {
		0 { 44100 }
		1 { 48000 }
		else { 32000 }
	}

	if ver == 2 {
		r /= 2
	} else if ver < 2 {
		r /= 4
	}
	return r
}

fn mp3_duration(head []u8, audio_bytes int) int {
	for i := 0; i < head.len - 4; i++ {
		if head[i] != 0xff || head[i + 1] & 0xe0 != 0xe0 {
			continue
		}
		ver := int(head[i + 1] >> 3) & 0x03
		layer := int(head[i + 1] >> 1) & 0x03
		br_idx := int(head[i + 2] >> 4) & 0x0f
		sr := mpeg_rate(ver, int(head[i + 2] >> 2) & 0x03)
		if ver == 1 || layer != 1 || sr == 0 || br_idx == 0 || br_idx == 15 {
			continue
		}
		spf := if ver == 3 { 1152 } else { 576 }
		br := if ver == 3 { mp3_bitrate_v1[br_idx] } else { mp3_bitrate_v2[br_idx] }
		nxt := i + spf / 8 * br * 1000 / sr + (int(head[i + 2] >> 1) & 1)
		if nxt + 1 < head.len && (head[nxt] != 0xff || head[nxt + 1] & 0xe0 != 0xe0) {
			continue
		}
		mono := int(head[i + 3] >> 6) == 3
		side := if ver == 3 {
			if mono { 17 } else { 32 }
		} else {
			if mono { 9 } else { 17 }
		}
		xing := txt(head, i + 4 + side, 4)
		frames := u32be(head, i + 4 + side + 8)
		if (xing == 'Xing' || xing == 'Info') && u32be(head, i + 4 + side + 4) & 1 != 0
			&& frames > 0 {
			return int(f64(frames) * f64(spf) / f64(sr))
		}
		if txt(head, i + 36, 4) == 'VBRI' && u32be(head, i + 50) > 0 {
			return int(f64(u32be(head, i + 50)) * f64(spf) / f64(sr))
		}
		mut j := i
		mut samples := i64(0)
		mut cbr := true
		for j + 4 <= head.len && head[j] == 0xff && head[j + 1] & 0xe0 == 0xe0 {
			bi := int(head[j + 2] >> 4) & 0x0f
			if bi == 0 || bi == 15 {
				break
			}
			cbr = cbr && bi == br_idx
			fbr := if ver == 3 { mp3_bitrate_v1[bi] } else { mp3_bitrate_v2[bi] }
			j += spf / 8 * fbr * 1000 / sr + (int(head[j + 2] >> 1) & 1)
			samples += spf
		}
		if cbr {
			return int(f64(audio_bytes - i) * 8.0 / (f64(br) * 1000.0))
		}
		return if head.len >= audio_bytes { int(samples / sr) } else { -1 }
	}
	return 0
}

fn id3_frame_start(x []u8) bool {
	if x.len == 0 {
		return false
	}
	mut zeros := 0
	for c in x {
		if c == 0 {
			zeros++
		} else if !((c >= 65 && c <= 90) || (c >= 48 && c <= 57)) {
			return false
		}
	}
	return zeros == 0 || zeros == x.len
}

fn unsync(b []u8) []u8 {
	mut out := []u8{cap: b.len}
	for i, c in b {
		if c == 0 && i > 0 && b[i - 1] == 0xff {
			continue
		}
		out << c
	}
	return out
}

fn id3_at(b &Bin, base int, buf []u8, off int, n int) []u8 {
	if off >= 0 && n >= 0 && off + n <= buf.len {
		return buf[off..off + n]
	}
	return b.seg(base + off, n)
}

fn id3v2(b &Bin, base int, head []u8, mut t NativeTags) int {
	if head.len < 10 || txt(head, 0, 3) != 'ID3' {
		return 0
	}
	ver := int(head[3])
	flags := int(head[5])
	tag_size := syncsafe(head, 6)
	mut end := 10 + tag_size
	total := end + if flags & 0x10 != 0 { 10 } else { 0 }
	if tag_size <= 0 || ver < 2 || ver > 4 {
		return total
	}
	mut buf := unsafe { head }
	if flags & 0x80 != 0 && ver < 4 {
		if end > 32 << 20 {
			return total
		}
		buf = unsync(b.seg(base, end))
		end = buf.len
	}
	idlen := if ver == 2 { 3 } else { 4 }
	hlen := if ver == 2 { 6 } else { 10 }
	mut off := 10
	if flags & 0x40 != 0 {
		x := id3_at(b, base, buf, off, 4)
		off += if ver == 4 { syncsafe(x, 0) } else { 4 + u32be(x, 0) }
	}
	for off >= 10 && off + hlen <= end {
		h := id3_at(b, base, buf, off, hlen)
		if h.len < hlen || h[0] == 0 || !id3_frame_start(h[..idlen]) {
			break
		}
		id := h[..idlen].bytestr()
		mut fsz := 0
		mut fl := 0
		if ver == 2 {
			fsz = int(h[3]) << 16 | int(h[4]) << 8 | int(h[5])
		} else {
			fsz = u32be(h, 4)
			fl = u16be(h, 8)
			if ver == 4 && (h[4] | h[5] | h[6] | h[7]) & 0x80 == 0 {
				ss := syncsafe(h, 4)
				nx := off + hlen + ss
				if nx == end || fsz > end - off - hlen
					|| id3_frame_start(id3_at(b, base, buf, nx, idlen)) {
					fsz = ss
				}
			}
		}
		data_off := off + hlen
		off = data_off + fsz
		if fsz <= 0 || off > end {
			break
		}
		field := match id {
			'TIT2', 'TT2' { 'title' }
			'TPE1', 'TP1' { 'artist' }
			'TPE2', 'TP2' { 'album_artist' }
			'TALB', 'TAL' { 'album' }
			'TCON', 'TCO' { 'genre' }
			'TDRC', 'TDRL', 'TYER', 'TYE' { 'date' }
			'TRCK', 'TRK' { 'track' }
			else { '' }
		}

		if field == '' || fsz > 65536 {
			continue
		}
		if (ver == 3 && fl & 0xc0 != 0) || (ver == 4 && fl & 0x0c != 0) {
			continue
		}
		mut data := id3_at(b, base, buf, data_off, fsz)
		if ver == 4 {
			if fl & 0x02 != 0 || flags & 0x80 != 0 {
				data = unsync(data)
			}
			if fl & 0x01 != 0 {
				data = take(data, 4, data.len - 4)
			}
		}
		if data.len < 2 {
			continue
		}
		val := id3_text(data[0], data[1..])
		t.set(field, if field == 'genre' { id3_genre(val) } else { val })
	}
	return total
}

fn id3v1(b &Bin, fsize int, mut t NativeTags) {
	x := b.seg(fsize - 128, 128)
	if x.len < 128 || txt(x, 0, 3) != 'TAG' {
		return
	}
	t.set('title', latin1_to_utf8(x[3..33]).all_before(nul).trim_space())
	t.set('artist', latin1_to_utf8(x[33..63]).all_before(nul).trim_space())
	t.set('album', latin1_to_utf8(x[63..93]).all_before(nul).trim_space())
	t.set('date', latin1_to_utf8(x[93..97]).all_before(nul).trim_space())
	if x[125] == 0 && x[126] != 0 {
		t.set('track', int(x[126]).str())
	}
	if int(x[127]) < id3_genres.len {
		t.set('genre', id3_genres[int(x[127])])
	}
}

fn mp3_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	fsize := int(os.file_size(path))
	head := b.seg(0, 65536)
	if head.len < 10 {
		return none
	}
	mut t := NativeTags{}
	start := id3v2(b, 0, head, mut t)
	id3v1(b, fsize, mut t)
	frame := if start + 8192 <= head.len { head[start..] } else { b.seg(start, 65536) }
	t.duration = mp3_duration(frame, fsize - start)
	if t.duration < 0 {
		t.duration = mp3_duration(b.seg(start, fsize - start), fsize - start)
	}
	return t
}

fn flac_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	mut t := NativeTags{}
	mut id3 := NativeTags{}
	mut off := id3v2(b, 0, b.seg(0, 65536), mut id3)
	if txt(b.seg(off, 4), 0, 4) != 'fLaC' {
		return none
	}
	off += 4
	for _ in 0 .. 64 {
		h := b.seg(off, 4)
		if h.len < 4 {
			break
		}
		typ := int(h[0]) & 0x7f
		last := h[0] & 0x80 != 0
		ln := int(h[1]) << 16 | int(h[2]) << 8 | int(h[3])
		if typ == 0 && ln >= 18 {
			s := b.seg(off + 4, ln)
			if s.len >= 18 {
				sr := int(s[10]) << 12 | int(s[11]) << 4 | int(s[12]) >> 4
				total := i64(s[13] & 0x0f) << 32 | i64(s[14]) << 24 | i64(s[15]) << 16 | i64(s[16]) << 8 | i64(s[17])
				if sr > 0 && total > 0 {
					t.duration = int(f64(total) / f64(sr))
				}
			}
		} else if typ == 4 && ln > 8 {
			t = parse_vorbis_comments(b.seg(off + 4, ln), 0, t)
		}
		off += 4 + ln
		if last {
			break
		}
	}
	t.set('title', id3.title)
	t.set('artist', id3.artist)
	t.set('album_artist', id3.album_artist)
	t.set('album', id3.album)
	t.set('genre', id3.genre)
	t.set('date', id3.date)
	t.set('track', id3.track)
	return t
}

fn mp4_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	fsize := int(os.file_size(path))
	mut moov := 0
	mut moov_end := 0
	mut off := 0
	for off >= 0 && off + 8 <= fsize {
		h := b.seg(off, 8)
		if h.len < 8 {
			break
		}
		mut sz := u32be(h, 0)
		if sz == 1 {
			sz = u64be(b.seg(off + 8, 8), 0)
		} else if sz == 0 {
			sz = fsize - off
		}
		if sz < 8 {
			break
		}
		if txt(h, 4, 4) == 'moov' {
			moov = off
			moov_end = off + sz
			break
		}
		off += sz
	}
	if moov == 0 {
		return none
	}
	mut t := NativeTags{}
	mut off2 := moov + 8
	for off2 + 8 <= moov_end {
		h := b.seg(off2, 8)
		if h.len < 8 {
			break
		}
		sz := u32be(h, 0)
		if sz < 8 {
			break
		}
		typ := txt(h, 4, 4)
		if typ == 'mvhd' {
			m := b.seg(off2 + 8, 40)
			if m.len >= 20 && m[0] == 0 {
				ts := u32be(m, 12)
				if ts > 0 {
					t.duration = int(f64(u32(u32be(m, 16))) / f64(ts))
				}
			} else if m.len >= 32 {
				ts := u32be(m, 20)
				if ts > 0 {
					t.duration = int(f64(u64be(m, 24)) / f64(ts))
				}
			}
		} else if typ == 'udta' {
			t = mp4_meta(b, off2 + 8, off2 + sz, t)
		} else if typ == 'meta' {
			t = mp4_meta(b, off2, off2 + sz, t)
		}
		off2 += sz
	}
	if t.duration == 0 && t.title == '' && t.artist == '' && t.album == '' {
		return none
	}
	return t
}

fn mp4_meta(b &Bin, start int, end int, t0 NativeTags) NativeTags {
	mut t := t0
	mut off := start
	for off + 8 <= end {
		h := b.seg(off, 8)
		if h.len < 8 {
			return t
		}
		sz := u32be(h, 0)
		if sz < 8 {
			return t
		}
		if txt(h, 4, 4) == 'meta' {
			mut mo := off + 12
			for mo + 8 <= off + sz {
				mh := b.seg(mo, 8)
				if mh.len < 8 {
					break
				}
				msz := u32be(mh, 0)
				if msz < 8 {
					break
				}
				if txt(mh, 4, 4) == 'ilst' {
					t = mp4_items(b, mo + 8, mo + msz, t)
				}
				mo += msz
			}
		}
		off += sz
	}
	return t
}

fn mp4_items(b &Bin, start int, end int, t0 NativeTags) NativeTags {
	mut t := t0
	mut off := start
	for off + 8 <= end {
		h := b.seg(off, 8)
		if h.len < 8 {
			return t
		}
		sz := u32be(h, 0)
		if sz < 8 {
			return t
		}
		field := match h[4..8].hex() {
			'a96e616d' { 'title' }
			'a9415254' { 'artist' }
			'61415254' { 'album_artist' }
			'a9616c62' { 'album' }
			'a967656e' { 'genre' }
			'a9646179' { 'date' }
			'74726b6e' { 'track' }
			'676e7265' { 'gnre' }
			else { '' }
		}

		d := b.seg(off + 8, 16)
		dsz := u32be(d, 0) - 16
		if field != '' && d.len >= 16 && txt(d, 4, 4) == 'data' && dsz > 0 && dsz <= 65536 {
			enc := u32be(d, 8)
			payload := b.seg(off + 24, dsz)
			if field == 'track' || field == 'gnre' {
				val := u16be(payload, if field == 'track' { 2 } else { 0 })
				if field == 'track' && val > 0 {
					t.set('track', val.str())
				} else if field == 'gnre' && val > 0 && val - 1 < id3_genres.len {
					t.set('genre', id3_genres[val - 1])
				}
			} else if enc == 1 {
				t.set(field, payload.bytestr().trim_space())
			} else if enc == 2 {
				t.set(field, utf16_to_utf8(payload, true).trim_space())
			}
		}
		off += sz
	}
	return t
}

struct OggInfo {
mut:
	t         NativeTags
	rate      int
	preskip   int
	flac      bool
	have_tags bool
}

fn ogg_headers(head []u8) OggInfo {
	mut o := OggInfo{}
	mut packet := []u8{}
	mut off := 0
	for off + 27 <= head.len && txt(head, off, 4) == 'OggS' {
		n := int(head[off + 26])
		mut seg_off := off + 27 + n
		if seg_off > head.len {
			break
		}
		for s in 0 .. n {
			l := int(head[off + 27 + s])
			if seg_off + l > head.len {
				return o
			}
			packet << head[seg_off..seg_off + l]
			seg_off += l
			if l == 255 {
				continue
			}
			if o.rate == 0 {
				if packet.len >= 16 && packet[0] == 1 && txt(packet, 1, 6) == 'vorbis' {
					o.rate = u32le(packet, 12)
				} else if packet.len >= 12 && txt(packet, 0, 8) == 'OpusHead' {
					o.preskip = u16le(packet, 10)
					o.rate = 48000
				} else if packet.len >= 30 && packet[0] == 0x7f && txt(packet, 1, 4) == 'FLAC' {
					o.rate = int(packet[27]) << 12 | int(packet[28]) << 4 | int(packet[29]) >> 4
					o.flac = true
				}
				if o.rate <= 0 {
					o.rate = 0
					return o
				}
			} else if o.flac {
				if packet.len > 4 && packet[0] & 0x7f == 4 {
					o.t = parse_vorbis_comments(packet, 4, o.t)
					o.have_tags = true
					return o
				}
				if packet.len > 0 && packet[0] == 0xff {
					o.have_tags = true
					return o
				}
			} else {
				if packet.len > 7 && packet[0] == 3 && txt(packet, 1, 6) == 'vorbis' {
					o.t = parse_vorbis_comments(packet, 7, o.t)
					o.have_tags = true
				} else if txt(packet, 0, 8) == 'OpusTags' {
					o.t = parse_vorbis_comments(packet, 8, o.t)
					o.have_tags = true
				}
				return o
			}
			packet = []u8{}
		}
		off = seg_off
	}
	return o
}

fn ogg_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	fsize := int(os.file_size(path))
	head := b.seg(0, 65536)
	if txt(head, 0, 4) != 'OggS' {
		return none
	}
	mut o := ogg_headers(head)
	if o.rate > 0 && !o.have_tags && fsize > head.len {
		o = ogg_headers(b.seg(0, if fsize < 16 << 20 { fsize } else { 16 << 20 }))
	}
	if o.rate == 0 || !o.have_tags {
		return none
	}
	mut t := o.t
	tail := if fsize > 65536 { b.seg(fsize - 65536, 65536) } else { head }
	for i := tail.len - 14; i >= 0; i-- {
		if tail[i] == 0x4f && tail[i + 1] == 0x67 && tail[i + 2] == 0x67 && tail[i + 3] == 0x53
			&& tail[i + 4] == 0 {
			gp := u64le(tail, i + 6)
			if gp > o.preskip {
				t.duration = int(f64(gp - o.preskip) / f64(o.rate))
				break
			}
		}
	}
	return t
}

fn wav_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	fsize := int(os.file_size(path))
	h := b.seg(0, 12)
	if h.len < 12 || txt(h, 0, 4) != 'RIFF' || txt(h, 8, 4) != 'WAVE' {
		return none
	}
	mut t := NativeTags{}
	mut id3 := NativeTags{}
	mut byterate := 0
	mut datasz := 0
	mut off := 12
	for off >= 12 && off + 8 <= fsize {
		ch := b.seg(off, 8)
		cid := txt(ch, 0, 4)
		csz := u32le(ch, 4)
		data := off + 8
		if ch.len < 8 || csz < 0 {
			break
		}
		if cid == 'fmt ' {
			byterate = u32le(b.seg(data, 16), 8)
		} else if cid == 'data' {
			datasz = if csz > fsize - data { fsize - data } else { csz }
		} else if cid.to_lower() == 'id3 ' {
			id3v2(b, data, b.seg(data, 65536), mut id3)
		} else if cid == 'LIST' && csz > 4 && csz <= 1 << 20 {
			l := b.seg(data, csz)
			mut lo := 4
			for txt(l, 0, 4) == 'INFO' && lo + 8 <= l.len {
				isz := u32le(l, lo + 4)
				if isz < 0 || lo + 8 + isz > l.len {
					break
				}
				val := stxt(l, lo + 8, isz).trim_space()
				match txt(l, lo, 4) {
					'INAM' { t.set('title', val) }
					'IART' { t.set('artist', val) }
					'IPRD' { t.set('album', val) }
					'IGNR' { t.set('genre', val) }
					'ICRD' { t.set('date', val) }
					'ITRK', 'IPRT' { t.set('track', val) }
					else {}
				}

				lo += 8 + isz + (isz & 1)
			}
		}
		off = data + csz + (csz & 1)
	}
	if byterate > 0 {
		t.duration = datasz / byterate
	}
	if id3.title != '' || id3.artist != '' || id3.album != '' {
		id3.duration = t.duration
		return id3
	}
	if t.duration == 0 {
		return none
	}
	return t
}

const aac_rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025,
	8000, 7350, 0, 0, 0]

fn aac_tags(path string) ?NativeTags {
	mut b := open_bin(path) or { return none }
	defer {
		b.f.close()
	}
	fsize := int(os.file_size(path))
	d := b.seg(0, fsize)
	mut t := NativeTags{}
	mut i := id3v2(b, 0, d, mut t)
	id3v1(b, fsize, mut t)
	mut samples := i64(0)
	mut rate := 0
	for i >= 0 && i + 7 <= d.len {
		fl := int(d[i + 3] & 0x03) << 11 | int(d[i + 4]) << 3 | int(d[i + 5]) >> 5
		sr := aac_rates[int(d[i + 2] >> 2) & 0x0f]
		if d[i] != 0xff || d[i + 1] & 0xf6 != 0xf0 || fl < 7 || sr == 0 {
			if rate > 0 {
				break
			}
			i++
			continue
		}
		rate = sr
		samples += 1024 * (i64(d[i + 6] & 0x03) + 1)
		i += fl
	}
	if rate == 0 {
		return none
	}
	t.duration = int(samples / rate)
	return t
}

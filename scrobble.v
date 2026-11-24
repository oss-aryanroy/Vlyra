module main

import crypto.md5
import net.http
import net.urllib
import os
import veb
import x.json2

const lastfm_api = 'https://ws.audioscrobbler.com/2.0/'
const listenbrainz_api = 'https://api.listenbrainz.org/1/'

// V's TLS client checks no certificates unless it is given a CA bundle.
fn ca_bundle() ?string {
	for path in [os.getenv('SSL_CERT_FILE'), '/etc/ssl/cert.pem',
		'/etc/ssl/certs/ca-certificates.crt', '/etc/pki/tls/certs/ca-bundle.crt'] {
		if path != '' && os.exists(path) {
			return path
		}
	}
	return none
}

fn outbound(method http.Method, url string, auth string, content_type string, data string) !map[string]json2.Any {
	ca := ca_bundle() or {
		return error('no CA certificates found on this server; install ca-certificates or set SSL_CERT_FILE')
	}
	mut header := http.new_header(key: .content_type, value: content_type)
	if auth != '' {
		header.add(.authorization, auth)
	}
	res := http.fetch(
		url:        url
		method:     method
		header:     header
		data:       data
		user_agent: 'Vlyra/${version}'
		validate:   true
		verify:     ca
	)!
	parsed := json2.decode[json2.Any](res.body) or { json2.Any(map[string]json2.Any{}) }
	reply := if parsed is map[string]json2.Any {
		parsed
	} else {
		map[string]json2.Any{}
	}
	if res.status_code >= 400 || 'error' in reply {
		if m := reply['message'] {
			return error(m.str())
		}
		if m := reply['error'] {
			return error(m.str())
		}
		return error('HTTP ${res.status_code}')
	}
	return reply
}

fn lastfm_sig(params map[string]string, secret string) string {
	mut keys := params.keys()
	keys.sort()
	return md5.hexhash(keys.map(it + params[it]).join('') + secret)
}

fn (app &App) lastfm(method string, extra map[string]string) !map[string]json2.Any {
	mut params := extra.clone()
	params['method'] = method
	params['api_key'] = app.get('lastfm.key')
	params['api_sig'] = lastfm_sig(params, app.get('lastfm.secret'))
	// After signing: Last.fm leaves `format` out of the signature.
	params['format'] = 'json'
	return outbound(.post, lastfm_api, '', 'application/x-www-form-urlencoded',
		http.url_encode_form_data(params))
}

fn listen_json(it Item, at i64) string {
	mut info := map[string]json2.Any{}
	info['media_player'] = 'Vlyra'
	info['submission_client'] = 'Vlyra'
	info['submission_client_version'] = version
	if it.duration > 0 {
		info['duration'] = it.duration
	}
	if it.track_no > 0 {
		info['tracknumber'] = it.track_no
	}
	mut meta := map[string]json2.Any{}
	meta['artist_name'] = it.artist
	meta['track_name'] = it.title
	if it.album != '' {
		meta['release_name'] = it.album
	}
	meta['additional_info'] = info
	mut listen := map[string]json2.Any{}
	listen['listened_at'] = at
	listen['track_metadata'] = meta
	mut body := map[string]json2.Any{}
	body['listen_type'] = 'single'
	body['payload'] = [json2.Any(listen)]
	return json2.Any(body).json_str()
}

fn (app &App) forward_play(it Item, at i64) {
	if it.kind != 'audio' || it.title == '' || it.artist == '' {
		return
	}
	token := app.get('listenbrainz.token')
	if token != '' {
		outbound(.post, listenbrainz_api + 'submit-listens', 'Token ${token}', 'application/json', listen_json(it,
			at)) or { eprintln('listenbrainz: ${err}') }
	}
	session := app.get('lastfm.session')
	if session != '' {
		mut params := {
			'artist':    it.artist
			'track':     it.title
			'timestamp': at.str()
			'sk':        session
		}
		if it.album != '' {
			params['album'] = it.album
			params['albumArtist'] = it.album_artist
		}
		if it.duration > 0 {
			params['duration'] = it.duration.str()
		}
		if it.track_no > 0 {
			params['trackNumber'] = it.track_no.str()
		}
		app.lastfm('track.scrobble', params) or { eprintln('last.fm: ${err}') }
	}
}

@['/api/v1/scrobblers/listenbrainz'; put]
pub fn (mut app App) connect_listenbrainz(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	token := (body(ctx)['token'] or { json2.Any('') }).str().trim_space()
	if token == '' {
		return fail(mut ctx, .bad_request, 'paste your ListenBrainz user token')
	}
	reply := outbound(.get, listenbrainz_api + 'validate-token', 'Token ${token}',
		'application/json', '') or {
		return fail(mut ctx, .bad_gateway, 'ListenBrainz: ${err.msg()}')
	}
	if !(reply['valid'] or { json2.Any(false) }).bool() {
		return fail(mut ctx, .bad_request, 'ListenBrainz did not accept that token')
	}
	user := (reply['user_name'] or { json2.Any('') }).str()
	app.set('listenbrainz.token', token)
	app.set('listenbrainz.user', user)
	return ctx.json({
		'user': user
	})
}

@['/api/v1/scrobblers/lastfm'; post]
pub fn (mut app App) connect_lastfm(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	b := body(ctx)
	key := (b['key'] or { json2.Any('') }).str().trim_space()
	secret := (b['secret'] or { json2.Any('') }).str().trim_space()
	if key == '' || secret == '' {
		return fail(mut ctx, .bad_request, 'enter the API key and the shared secret')
	}
	app.set('lastfm.key', key)
	app.set('lastfm.secret', secret)
	reply := app.lastfm('auth.getToken', map[string]string{}) or {
		return fail(mut ctx, .bad_gateway, 'Last.fm: ${err.msg()}')
	}
	token := (reply['token'] or { json2.Any('') }).str()
	app.set('lastfm.token', token)
	return ctx.json({
		'url': 'https://www.last.fm/api/auth/?api_key=${urllib.query_escape(key)}&token=${urllib.query_escape(token)}'
	})
}

@['/api/v1/scrobblers/lastfm'; put]
pub fn (mut app App) finish_lastfm(mut ctx Context) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	reply := app.lastfm('auth.getSession', {
		'token': app.get('lastfm.token')
	}) or { return fail(mut ctx, .bad_gateway, 'Last.fm: ${err.msg()}') }
	session := (reply['session'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	user := (session['name'] or { json2.Any('') }).str()
	app.set('lastfm.session', (session['key'] or { json2.Any('') }).str())
	app.set('lastfm.user', user)
	return ctx.json({
		'user': user
	})
}

@['/api/v1/scrobblers/:name'; delete]
pub fn (mut app App) disconnect_scrobbler(mut ctx Context, name string) veb.Result {
	app.auth(ctx, 'admin') or { return deny(mut ctx, err) }
	if name !in ['listenbrainz', 'lastfm'] {
		return fail(mut ctx, .not_found, 'unknown service')
	}
	app.db.exec_param('delete from settings where key like ?', '${name}.%') or {
		return fail(mut ctx, .internal_server_error, err.msg())
	}
	app.reload_settings()
	return ok(mut ctx)
}

module main

import crypto.rand as crand
import crypto.sha256
import encoding.hex
import time

const resources = ['library', 'lyrics', 'artwork', 'playlists', 'history', 'ratings']

const protocols = ['native', 'subsonic', 'jellyfin']

pub struct Principal {
pub:
	name   string
	app_id int
	admin  bool
	scopes []string
}

fn (p Principal) can(scope string) bool {
	return p.admin || scope in p.scopes
}

fn valid_scope(s string) bool {
	parts := s.split(':')
	return parts.len == 2 && parts[0] in resources && parts[1] in ['read', 'write']
}

fn new_token() string {
	return hex.encode(crand.bytes(24) or { panic(err) })
}

fn (app &App) protocol_on(name string) bool {
	return app.get('proto.${name}') != '0'
}

fn (mut app App) principal_for(a ClientApp) Principal {
	app.db.exec_param_many('update apps set last_seen = ? where id = ?', [
		time.now().unix().str(),
		a.id.str(),
	]) or {}
	return Principal{
		name:   a.name
		app_id: a.id
		scopes: a.scopes.fields()
	}
}

fn (app &App) session_ok(token string) bool {
	if token == '' {
		return false
	}
	rows := app.db.exec_param_many('select 1 from sessions where token = ? and expires > ?', [
		sha256.hexhash(token),
		time.now().unix().str(),
	]) or { return false }
	return rows.len > 0
}

fn (mut app App) identify(ctx &Context) ?Principal {
	if app.session_ok(ctx.get_cookie('vlyra_session') or { '' }) {
		return Principal{
			name:  'admin'
			admin: true
		}
	}
	header := ctx.get_header(.authorization) or { '' }
	if !header.starts_with('Bearer ') || !app.protocol_on('native') {
		return none
	}
	return app.app_by_token(header[7..].trim_space())
}

fn (mut app App) app_by_token(token string) ?Principal {
	hash := sha256.hexhash(token)
	found := sql app.db {
		select from ClientApp where token_hash == hash && enabled == true
	} or { return none }
	if found.len == 0 {
		return none
	}
	return app.principal_for(found[0])
}

fn (mut app App) auth(ctx &Context, scope string) !Principal {
	p := app.identify(ctx) or { return error('unauthorized') }
	if scope == '' || (scope == 'admin' && p.admin) || (scope != 'admin' && p.can(scope)) {
		return p
	}
	return error('forbidden')
}

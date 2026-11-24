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

fn (app &App) reload_apps() {
	rows := app.reader().exec('select id, name, token_hash, subsonic_password, scopes, enabled, created_at, last_seen from apps') or {
		return
	}
	mut by_token := map[string]ClientApp{}
	mut by_name := map[string]ClientApp{}
	mut list := []ClientApp{cap: rows.len}
	for r in rows {
		v := r.vals
		a := ClientApp{
			id:                v[0].int()
			name:              v[1]
			token_hash:        v[2]
			subsonic_password: v[3]
			scopes:            v[4]
			enabled:           v[5] == '1'
			created_at:        v[6].i64()
			last_seen:         v[7].i64()
		}
		list << a
		if a.enabled {
			by_token[a.token_hash] = a
			by_name[a.name] = a
		}
	}
	unsafe {
		mut c := app.cache
		c.mu.lock()
		mut seen := map[int]i64{}
		mut seen_db := map[int]i64{}
		for a in list {
			prev := c.last_seen[a.id]
			prev_db := c.last_seen_db[a.id]
			seen[a.id] = if a.last_seen > prev { a.last_seen } else { prev }
			seen_db[a.id] = if a.last_seen > prev_db { a.last_seen } else { prev_db }
		}
		c.apps_by_token = by_token.move()
		c.apps_by_name = by_name.move()
		c.last_seen = seen.move()
		c.last_seen_db = seen_db.move()
		c.mu.unlock()
	}
}

fn (app &App) live_last_seen(id int, fallback i64) i64 {
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		ls := c.last_seen[id]
		c.mu.runlock()
		return if ls > fallback { ls } else { fallback }
	}
}

fn (app &App) cached_app_by_token(hash string) ?ClientApp {
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		found := c.apps_by_token[hash] or {
			c.mu.runlock()
			return none
		}
		c.mu.runlock()
		return found
	}
}

fn (app &App) cached_app_by_name(name string) ?ClientApp {
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		found := c.apps_by_name[name] or {
			c.mu.runlock()
			return none
		}
		c.mu.runlock()
		return found
	}
}

fn (mut app App) principal_for(a ClientApp) Principal {
	now := time.now().unix()
	mut already := false
	unsafe {
		mut c := app.cache
		c.mu.rlock()
		already = c.last_seen[a.id] == now
		c.mu.runlock()
	}
	if !already {
		mut should_flush := false
		unsafe {
			mut c := app.cache
			c.mu.lock()
			if now > c.last_seen[a.id] {
				c.last_seen[a.id] = now
			}
			if now - c.last_seen_db[a.id] >= 60 {
				c.last_seen_db[a.id] = now
				should_flush = true
			}
			c.mu.unlock()
		}
		if should_flush {
			app.db.exec_param_many('update apps set last_seen = ? where id = ?', [
				now.str(),
				a.id.str(),
			]) or {}
		}
	}
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
	rows := app.reader().exec_param_many('select 1 from sessions where token = ? and expires > ?', [
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
	if token == '' {
		return none
	}
	found := app.cached_app_by_token(sha256.hexhash(token)) or { return none }
	return app.principal_for(found)
}

fn (mut app App) auth(ctx &Context, scope string) !Principal {
	p := app.identify(ctx) or { return error('unauthorized') }
	if scope == '' || (scope == 'admin' && p.admin) || (scope != 'admin' && p.can(scope)) {
		return p
	}
	return error('forbidden')
}

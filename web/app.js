'use strict';

const $ = (sel) => document.querySelector(sel);

// Text is always inserted as text, never as HTML.
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  el.append(...kids.flat().filter((k) => k != null && k !== false));
  return el;
}

const ICONS = {
  play: '<path class="f" d="M8 5.2v13.6a.8.8 0 0 0 1.2.7l11-6.8a.8.8 0 0 0 0-1.4l-11-6.8A.8.8 0 0 0 8 5.2z"/>',
  pause: '<rect class="f" x="6.5" y="5" width="4" height="14" rx="1"/><rect class="f" x="13.5" y="5" width="4" height="14" rx="1"/>',
  prev: '<path class="f" d="M19 6.3v11.4a.7.7 0 0 1-1.1.6l-8.4-5.7a.7.7 0 0 1 0-1.2l8.4-5.7a.7.7 0 0 1 1.1.6z"/><path d="M6 6v12"/>',
  next: '<path class="f" d="M5 6.3v11.4a.7.7 0 0 0 1.1.6l8.4-5.7a.7.7 0 0 0 0-1.2L6.100 5.700A.7.7 0 0 0 5 6.3z"/><path d="M18 6v12"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.500"/>',
  library: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  playlist: '<path d="M4 7h12M4 12h12M4 17h7"/><path class="f" d="M15.500 14.600v5.800a.5.5 0 0 0 .8.4l4.200-2.900a.5.5 0 0 0 0-.8l-4.200-2.900a.5.5 0 0 0-.8.4z"/>',
  history: '<circle cx="12" cy="12" r="8.500"/><path d="M12 7.500V12l3 2"/>',
  apps: '<circle cx="6" cy="12" r="2.500"/><circle cx="18" cy="6" r="2.500"/><circle cx="18" cy="18" r="2.500"/><path d="m8.300 10.900 7.400-3.800M8.300 13.100l7.400 3.800"/>',
  activity: '<path d="M3 12h4l2.500-6.500 4.500 13L16.500 12H21"/>',
  settings: '<path d="M4 7h8M18 7h2M4 17h2M12 17h8"/><circle cx="15" cy="7" r="2.500"/><circle cx="9" cy="17" r="2.500"/>',
  signout: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M10 8l-4 4 4 4M6 12h9"/>',
  more: '<circle class="f" cx="5.500" cy="12" r="1.600"/><circle class="f" cx="12" cy="12" r="1.600"/><circle class="f" cx="18.500" cy="12" r="1.600"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  back: '<path d="m14 6-6 6 6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  star: '<path d="m12 3.6 2.6 5.3 5.8.8-4.2 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8-4.2-4.1 5.8-.8z"/>',
  volume: '<path d="M4 10v4h3l5 4V6l-5 4H4z"/><path d="M16 9a4 4 0 0 1 0 6M18.500 6.500a8 8 0 0 1 0 11"/>',
};
function icon(name) {
  const t = document.createElement('template');
  // ICONS are static strings: never put data in them.
  t.innerHTML = `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
  return t.content.firstChild;
}

async function api(path, { method = 'GET', body } = {}) {
  const raw = body instanceof Blob;
  const res = await fetch('/api/v1' + path, { method, body: body && !raw ? JSON.stringify(body) : body });
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && path !== '/session') boot();
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

let toastTimer;
function toast(message, isError = false) {
  const el = $('#toast');
  el.textContent = message;
  el.className = 'show' + (isError ? ' error' : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = ''), isError ? 5000 : 2200);
}
const act = (fn) => async (event) => {
  try { await fn(event); } catch (err) { toast(err.message, true); }
};

const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const when = (unix) => (unix ? new Date(unix * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : 'never');
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const hueOf = (text) => [...String(text)].reduce((a, c) => (a * 31 + c.charCodeAt(0)) % 360, 7);
const albumHref = (artist, album) => `#/library?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`;

const artVersion = {};
const probe = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
probe.canvas.width = probe.canvas.height = 1;

function colourOf(img, hue) {
  probe.clearRect(0, 0, 1, 1);
  if (img) probe.drawImage(img, 0, 0, 1, 1);
  else { probe.fillStyle = `hsl(${hue} 40% 38%)`; probe.fillRect(0, 0, 1, 1); }
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data;
  return `${r} ${g} ${b}`;
}

function cover(itemId, seed, onColour, size = 640) {
  const name = seed || 'Vlyra';
  const hue = hueOf(name);
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');
  const el = h('div', { class: 'cover', style: `--hue:${hue}` }, h('span', {}, initials));
  const fallback = () => onColour && onColour(colourOf(null, hue));
  if (!itemId) { fallback(); return el; }
  el.append(h('img', {
    src: `/api/v1/items/${itemId}/artwork?size=${size}${artVersion[itemId] ? `&v=${artVersion[itemId]}` : ''}`, alt: '', loading: 'lazy', decoding: 'async',
    onload: (e) => onColour && onColour(colourOf(e.target)),
    onerror: (e) => { e.target.remove(); fallback(); },
  }));
  return el;
}

function openDialog(...content) {
  const dialog = $('#dialog');
  dialog.replaceChildren(h('div', { class: 'stack' }, ...content));
  if (!dialog.open) dialog.showModal();
}
$('#dialog').addEventListener('close', () => $('#dialog').replaceChildren());

function confirmDialog(title, text, action) {
  return new Promise((resolve) => {
    const done = (answer) => { $('#dialog').close(); resolve(answer); };
    openDialog(h('h2', {}, title), h('p', {}, text),
      h('div', { class: 'row' },
        h('button', { class: 'danger', onclick: () => done(true) }, action),
        h('button', { autofocus: true, onclick: () => done(false) }, 'Cancel')));
    $('#dialog').addEventListener('close', () => resolve(false), { once: true });
  });
}

const audio = $('#audio');
const seek = $('#seek');
const volume = $('#volume');
let queue = [];
let position = -1;
let scrubbing = false;

const current = () => queue[position];
const length = () => (Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : (current() || {}).duration || 0);
const fill = (range) => range.style.setProperty('--p', `${(range.value / range.max) * 100}%`);

function play(items, index) {
  const item = items[index];
  if (!item) return;
  if (item.kind === 'video') {
    audio.pause();
    return openDialog(h('h2', {}, item.title),
      h('video', { src: `/api/v1/items/${item.id}/stream`, controls: true, autoplay: true }),
      h('div', { class: 'row' }, h('button', { onclick: () => $('#dialog').close() }, 'Close')));
  }
  queue = items;
  position = index;
  audio.src = `/api/v1/items/${item.id}/stream`;
  audio.play().catch(() => {});
  $('#player').hidden = false;
  $('#now').href = albumHref(item.album_artist, item.album);
  $('#now-title').textContent = item.title;
  $('#now-artist').textContent = item.artist || 'Unknown artist';
  $('#now-art').replaceChildren(cover(item.id, item.album || item.title, (rgb) => $('#player').style.setProperty('--glow', rgb), 128));
  $('#time-total').textContent = clock(item.duration);
  document.title = `${item.title} · Vlyra`;
  if ('mediaSession' in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: item.title, artist: item.artist, album: item.album, artwork: [{ src: `/api/v1/items/${item.id}/artwork` }] });
  }
  markPlaying();
}
function markPlaying() {
  const id = current() && current().id;
  for (const row of document.querySelectorAll('[data-item]')) row.classList.toggle('playing', Number(row.dataset.item) === id);
}
const toggle = () => (audio.paused ? audio.play().catch(() => {}) : audio.pause());

function syncToggle() {
  $('#toggle').replaceChildren(icon(audio.paused ? 'play' : 'pause'));
  $('#toggle').setAttribute('aria-label', audio.paused ? 'Play' : 'Pause');
}
audio.addEventListener('play', syncToggle);
audio.addEventListener('pause', syncToggle);
audio.addEventListener('durationchange', () => ($('#time-total').textContent = clock(length())));
audio.addEventListener('timeupdate', () => {
  if (scrubbing || !length()) return;
  seek.value = (audio.currentTime / length()) * 1000;
  fill(seek);
  $('#time-now').textContent = clock(audio.currentTime);
});
audio.addEventListener('ended', () => {
  api('/plays', { method: 'POST', body: { item_id: current().id } }).catch(() => {});
  play(queue, position + 1);
});
seek.addEventListener('input', () => { scrubbing = true; fill(seek); $('#time-now').textContent = clock((seek.value / 1000) * length()); });
seek.addEventListener('change', () => { audio.currentTime = (seek.value / 1000) * length(); scrubbing = false; });
volume.addEventListener('input', () => {
  audio.volume = volume.value / 100;
  fill(volume);
  try { localStorage.setItem('volume', volume.value); } catch {}
});
try { volume.value = localStorage.getItem('volume') || 100; } catch {}
audio.volume = volume.value / 100;
fill(volume);
$('#toggle').onclick = toggle;
$('#prev').onclick = () => (audio.currentTime > 3 ? (audio.currentTime = 0) : play(queue, position - 1));
$('#next').onclick = () => play(queue, position + 1);
$('#prev').append(icon('prev'));
$('#next').append(icon('next'));
$('#volume-icon').append(icon('volume'));
syncToggle();
if ('mediaSession' in navigator) {
  navigator.mediaSession.setActionHandler('previoustrack', () => $('#prev').click());
  navigator.mediaSession.setActionHandler('nexttrack', () => $('#next').click());
}
addEventListener('keydown', (e) => {
  if (e.code === 'Escape' && !$('#panel').hidden) closePanel();
  if (e.code !== 'Space' || !current() || e.target.closest('input, textarea, select, button, a, dialog')) return;
  e.preventDefault();
  toggle();
});

function trackRow(items, index, lead, action) {
  const item = items[index];
  return h('div', { class: 'track' + (lead == null ? ' with-art' : ''), role: 'listitem', 'data-item': item.id },
    h('button', { class: 'lead', 'aria-label': `Play ${item.title}`, onclick: () => play(items, index) },
      lead == null ? cover(item.id, item.album || item.title, null, 128) : h('span', {}, String(lead)), icon('play')),
    h('div', { class: 'name' }, h('strong', {}, item.title), h('span', { class: 'small muted' }, item.artist || 'Unknown artist')),
    h('span', { class: 'col' }, item.album),
    h('span', { class: 'time' }, clock(item.duration)),
    action || h('button', { class: 'icon more', 'aria-label': `Details for ${item.title}`, onclick: act(() => openPanel(item)) }, icon('more')));
}
const trackList = (rows, cls = '') => h('div', { class: `tracks ${cls}`, role: 'list' }, rows);
const go = (href, cls, ...kids) => h('button', { type: 'button', class: cls, onclick: () => (location.hash = href) }, ...kids);

function empty(title, text, ...actions) {
  return h('div', { class: 'empty' }, h('h2', {}, title), h('p', {}, text), actions);
}

const library = { q: '' };

async function libraryView(render, params, view) {
  if (params.has('album')) return albumView(render, params, view);
  const tab = params.get('view') === 'tracks' ? 'tracks' : 'albums';
  const body = h('div', {});
  const count = h('p', {});
  let tracks = [];
  let total = 0;
  let turn = 0;

  const draw = async (append) => {
    const mine = ++turn;
    const q = encodeURIComponent(library.q);
    if (tab === 'albums') {
      const albums = await api(`/albums?q=${q}`);
      if (mine !== turn) return;
      count.textContent = plural(albums.length, 'album');
      if (!albums.length) return body.replaceChildren(noResults());
      body.replaceChildren(h('div', { class: 'albums' }, albums.map((a) => h('div', { class: 'album' },
        h('div', { class: 'art' },
          cover(a.first_id, a.name || a.artist),
          h('button', { class: 'fab', 'aria-label': `Play ${a.name || 'album'}`, onclick: act(async () => {
            const page = await api(`/items?artist=${encodeURIComponent(a.artist)}&album=${encodeURIComponent(a.name)}`);
            play(page.items, 0);
          }) }, icon('play'))),
        h('div', {},
          h('a', { href: albumHref(a.artist, a.name) }, h('strong', {}, a.name || 'Unknown album')),
          h('span', { class: 'small muted' }, [a.artist || 'Unknown artist', a.year || null, a.rating ? `★ ${a.rating}` : null].filter(Boolean).join(' · ')))))));
      return;
    }
    const page = await api(`/items?limit=200&offset=${append ? tracks.length : 0}&q=${q}`);
    if (mine !== turn) return;
    tracks = append ? tracks.concat(page.items) : page.items;
    total = page.total;
    count.textContent = plural(total, 'track');
    if (!tracks.length) return body.replaceChildren(noResults());
    body.replaceChildren(trackList(tracks.map((_, i) => trackRow(tracks, i, null))),
      tracks.length < total ? h('p', { class: 'row', style: 'margin-top:16px' }, h('button', { onclick: act(() => draw(true)) }, 'Show more')) : '');
    markPlaying();
  };
  const noResults = () => (library.q
    ? empty('Nothing found', `No ${tab} match “${library.q}”.`)
    : empty('Your library is empty', 'Tell Vlyra where your music lives and it will index it for every app you connect.',
      go('#/settings', 'primary', 'Choose a media folder')));

  let timer;
  const search = h('div', { class: 'search' }, icon('search'), h('input', {
    type: 'search', placeholder: 'Search your library', 'aria-label': 'Search your library', value: library.q,
    oninput: (e) => { clearTimeout(timer); timer = setTimeout(act(() => { library.q = e.target.value.trim(); return draw(false); }), 220); },
  }));
  render(
    h('div', { class: 'head' },
      h('div', {}, h('h1', {}, 'Library'), count),
      h('div', { class: 'row tools' },
        h('div', { class: 'tabs' },
          h('a', { href: '#/library', 'aria-current': tab === 'albums' ? 'page' : null }, 'Albums'),
          h('a', { href: '#/library?view=tracks', 'aria-current': tab === 'tracks' ? 'page' : null }, 'Tracks')),
        search)),
    body);
  await draw(false);
}

function stars(artist, album, rating) {
  const buttons = [1, 2, 3, 4, 5].map((n) => h('button', { type: 'button', class: 'icon', 'aria-label': plural(n, 'star'), onclick: act(async () => {
    const next = n === rating ? 0 : n;
    await api('/albums/rating', { method: 'PUT', body: { artist, album, rating: next } });
    draw(next);
  }) }, icon('star')));
  const draw = (now) => {
    rating = now;
    buttons.forEach((b, i) => { b.classList.toggle('on', i < now); b.setAttribute('aria-pressed', String(i + 1 === now)); });
  };
  draw(rating);
  return h('div', { class: 'stars', role: 'group', 'aria-label': 'Your rating' }, buttons);
}

async function albumView(render, params, view) {
  const artist = params.get('artist') || '';
  const album = params.get('album') || '';
  const { items, rating } = await api(`/items?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`);
  if (!items.length) return render(empty('Album not found', 'It may have been renamed or removed.', go('#/library', '', 'Back to library')));
  const seconds = items.reduce((sum, i) => sum + i.duration, 0);
  const year = Math.max(...items.map((i) => i.year));
  view.classList.add('lit');
  render(
    go('#/library', 'ghost back', icon('back'), 'Library'),
    h('div', { class: 'hero' },
      cover(items[0].id, album || artist, (rgb) => view.style.setProperty('--glow', rgb)),
      h('div', {},
        h('h1', {}, album || 'Unknown album'),
        h('p', { class: 'meta' }, h('strong', {}, artist || 'Unknown artist'), ` · ${[year || null, plural(items.length, 'track'), `${Math.max(1, Math.round(seconds / 60))} min`].filter(Boolean).join(' · ')}`),
        h('div', { class: 'row' }, h('button', { class: 'primary', onclick: () => play(items, 0) }, icon('play'), 'Play'), stars(artist, album, rating)))),
    trackList(items.map((item, i) => trackRow(items, i, item.track_no || i + 1)), 'one-album'));
  markPlaying();
}

const fields = {
  Song: [['title', 'Title'], ['artist', 'Artist'], ['genre', 'Genre']],
  Album: [['album', 'Album'], ['album_artist', 'Album artist'], ['track_no', 'Track', 'half'], ['year', 'Year', 'half']],
};

function closePanel() {
  $('#panel').hidden = true;
  $('#panel').replaceChildren();
}

async function openPanel(item) {
  const [lyrics, playlists, changes] = await Promise.all([
    api(`/items/${item.id}/lyrics`), api('/playlists'), api(`/activity?item_id=${item.id}`)]);
  const numeric = (key) => key === 'year' || key === 'track_no';
  const inputs = Object.fromEntries([...Object.values(fields).flat(), ['tags']].map(([key]) => [key, h('input', {
    value: item[key] || '', inputmode: numeric(key) ? 'numeric' : null, placeholder: numeric(key) ? '–' : 'None',
  })]));
  const lyricsBox = h('textarea', { placeholder: 'Paste lyrics. Lines like [00:12.50] stay in time with the song.' }, lyrics.text);
  const lyricsLabel = h('span', {});
  const timed = () => (lyricsLabel.textContent = /^\s*\[\d+:\d/m.test(lyricsBox.value) ? 'Lyrics · timed' : 'Lyrics');
  timed();
  lyricsBox.classList.toggle('blank', !lyrics.text);

  const file = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp,image/gif', hidden: true });
  const art = h('button', { type: 'button', class: 'cover-pick', 'aria-label': 'Replace the cover', onclick: () => file.click() },
    cover(item.id, item.album || item.title, null, 320));
  const artNote = h('span', { class: 'small muted' }, 'Click the cover to replace it');
  const undoArt = h('button', { type: 'button', class: 'link-button', hidden: true, onclick: () => {
    file.value = '';
    art.replaceChildren(cover(item.id, item.album || item.title, null, 320));
    artNote.textContent = 'Click the cover to replace it';
    undoArt.hidden = true;
    dirty();
  } }, 'Undo');
  file.addEventListener('change', () => {
    const picked = file.files[0];
    if (!picked) return;
    art.replaceChildren(h('div', { class: 'cover' }, h('img', { src: URL.createObjectURL(picked), alt: '' })));
    artNote.textContent = 'New cover, saved with your changes.';
    undoArt.hidden = false;
    dirty();
  });

  const changedFields = () => Object.fromEntries(Object.keys(inputs)
    .filter((key) => inputs[key].value.trim() !== String(item[key] || ''))
    .map((key) => [key, inputs[key].value.trim()]));
  const saveButton = h('button', { class: 'primary', disabled: true }, 'Save changes');
  const dirty = () => (saveButton.disabled = !(Object.keys(changedFields()).length || lyricsBox.value !== lyrics.text || file.files[0]));

  const save = act(async (event) => {
    event.preventDefault();
    const changed = changedFields();
    if (Object.keys(changed).length) Object.assign(item, await api(`/items/${item.id}`, { method: 'PATCH', body: changed }));
    if (lyricsBox.value !== lyrics.text) await api(`/items/${item.id}/lyrics`, { method: 'PUT', body: { text: lyricsBox.value } });
    if (file.files[0]) {
      await api(`/items/${item.id}/artwork`, { method: 'PUT', body: file.files[0] });
      artVersion[item.id] = Date.now();
    }
    closePanel();
    toast('Saved');
    route();
  });

  const picker = h('select', { 'aria-label': 'Playlist' }, playlists.map((p) => h('option', { value: p.id }, p.name)));
  const addToPlaylist = act(async () => {
    const playlist = await api(`/playlists/${picker.value}`);
    await api(`/playlists/${picker.value}`, { method: 'PUT', body: { item_ids: playlist.items.map((i) => i.id).concat(item.id) } });
    toast(`Added to ${playlist.name}`);
  });

  const group = (title, list) => h('fieldset', { class: 'group' }, h('legend', {}, title),
    list.map(([key, label, half]) => h('label', { class: half ? 'half' : null }, label, inputs[key])));

  $('#panel').replaceChildren(h('form', { onsubmit: save, oninput: () => { timed(); lyricsBox.classList.toggle('blank', !lyricsBox.value); dirty(); } },
    h('div', { class: 'top' },
      art,
      h('div', { class: 'stack', style: 'gap:6px;min-width:0' },
        h('h2', {}, item.title || 'Untitled'),
        h('span', { class: 'small muted' }, item.artist || 'Unknown artist'),
        h('span', { class: 'row', style: 'gap:8px' }, artNote, undoArt)),
      h('button', { type: 'button', class: 'icon', 'aria-label': 'Close details', onclick: closePanel }, icon('close'))),
    file,
    Object.entries(fields).map(([title, list]) => group(title, list)),
    h('label', {}, lyricsLabel, lyricsBox),
    h('details', { class: 'more', open: changes.length > 0 || !!item.tags || null },
      h('summary', {}, 'More'),
      h('div', { class: 'stack' },
        h('label', {}, 'App tags', inputs.tags, h('span', { class: 'small muted' }, 'Free labels for your apps to use, separated by commas.')),
        playlists.length > 0 && h('label', {}, 'Add to a playlist',
          h('div', { class: 'secret' }, picker, h('button', { type: 'button', onclick: addToPlaylist }, 'Add'))),
        changes.length > 0 && h('div', { class: 'stack', style: 'gap:8px' }, h('h3', {}, 'Who changed this'),
          h('ul', {}, changes.slice(0, 8).map((c) => h('li', {}, h('strong', {}, c.app_name === 'admin' ? 'You' : c.app_name), ` ${describe(c)[0]} · ${when(c.at)}`)))),
        h('code', {}, item.path))),
    h('div', { class: 'foot row' }, saveButton, h('button', { type: 'button', class: 'ghost', onclick: closePanel }, 'Cancel'))));
  $('#panel').hidden = false;
  inputs.title.focus();
}

async function playlistsView(render, params) {
  const playlists = await api('/playlists');
  const selected = Number(params.get('id')) || (playlists[0] && playlists[0].id);
  const name = h('input', { placeholder: 'New playlist', 'aria-label': 'New playlist name', required: true, maxlength: 80 });
  const create = act(async (event) => {
    event.preventDefault();
    const made = await api('/playlists', { method: 'POST', body: { name: name.value, item_ids: [] } });
    location.hash = `#/playlists?id=${made.id}`;
  });
  const detail = h('div', { class: 'detail' });
  render(
    h('div', { class: 'head' }, h('div', {}, h('h1', {}, 'Playlists'), h('p', {}, 'Made here or by any app you allow to edit playlists.'))),
    h('div', { class: 'split' },
      h('div', { class: 'side' },
        h('form', { class: 'secret', onsubmit: create }, name, h('button', { class: 'icon', 'aria-label': 'Create playlist', style: 'border-color:var(--line)' }, icon('plus'))),
        playlists.map((p) => h('a', { href: `#/playlists?id=${p.id}`, 'aria-current': p.id === selected ? 'page' : null },
          h('strong', {}, p.name), h('span', { class: 'small' }, `by ${p.owner}`)))),
      detail));
  if (!selected) return detail.replaceChildren(empty('No playlists yet', 'Name one on the left, then add tracks from the library using the ··· button on any track.'));

  const playlist = await api(`/playlists/${selected}`);
  const put = (body) => api(`/playlists/${selected}`, { method: 'PUT', body });
  const seconds = playlist.items.reduce((sum, i) => sum + i.duration, 0);
  detail.replaceChildren(
    h('div', { class: 'head' },
      h('div', { style: 'flex:1;min-width:0' },
        h('input', { class: 'title', value: playlist.name, 'aria-label': 'Playlist name', maxlength: 80,
          onchange: act(async (e) => { if (e.target.value.trim()) { await put({ name: e.target.value }); toast('Renamed'); route(); } }) }),
        h('p', {}, `${plural(playlist.items.length, 'track')} · ${Math.round(seconds / 60)} min · created by ${playlist.owner}`)),
      h('div', { class: 'row' },
        h('button', { class: 'primary', disabled: !playlist.items.length, onclick: () => play(playlist.items, 0) }, icon('play'), 'Play'),
        h('button', { class: 'ghost danger', onclick: act(async () => {
          if (await confirmDialog(`Delete “${playlist.name}”?`, 'The tracks stay in your library.', 'Delete playlist')) {
            await api(`/playlists/${selected}`, { method: 'DELETE' });
            location.hash = '#/playlists';
            route();
          }
        }) }, 'Delete'))),
    playlist.items.length
      ? trackList(playlist.items.map((item, i) => trackRow(playlist.items, i, null,
        h('button', { class: 'icon more', 'aria-label': `Remove ${item.title} from playlist`, onclick: act(async () => {
          await put({ item_ids: playlist.items.filter((_, j) => j !== i).map((x) => x.id) });
          route();
        }) }, icon('close')))))
      : empty('Nothing in here yet', 'Open the library, press ··· on a track and choose this playlist.', go('#/library?view=tracks', '', 'Browse tracks')));
  markPlaying();
}

async function historyView(render) {
  const plays = await api('/plays');
  render(
    h('div', { class: 'head' }, h('div', {}, h('h1', {}, 'History'), h('p', {}, 'Everything you have listened to, here or in any app allowed to report listens.'))),
    plays.length
      ? h('div', { class: 'list' }, plays.map((p) => h('div', { class: 'item' },
        cover(p.item_id, p.title, null, 128),
        h('div', { style: 'min-width:0' }, h('strong', {}, p.title), h('div', { class: 'small muted' }, p.artist || 'Unknown artist')),
        h('span', { class: 'when' }, `${p.app_name === 'admin' ? 'Web player' : p.app_name} · ${when(p.at)}`))))
      : empty('No listens yet', 'Play something. Finished tracks show up here, along with the app that reported them.'));
}

const resources = [
  ['library', 'Library', 'Browse and stream', 'Edit titles and tags'],
  ['lyrics', 'Lyrics', 'Read lyrics', 'Add or replace lyrics'],
  ['artwork', 'Artwork', 'See covers', 'Upload covers'],
  ['playlists', 'Playlists', 'See playlists', 'Create and edit'],
  ['history', 'History', 'Read listening history', 'Report listens'],
  ['ratings', 'Ratings', 'See album ratings', 'Rate albums'],
];
const presets = {
  Player: ['library:read', 'lyrics:read', 'artwork:read', 'playlists:read', 'playlists:write', 'history:write', 'ratings:read', 'ratings:write'],
  'Read only': resources.map(([id]) => `${id}:read`),
  'Full access': resources.flatMap(([id]) => [`${id}:read`, `${id}:write`]),
};

function permissions(scopes, onchange) {
  const granted = new Set(scopes);
  const boxes = {};
  const box = (scope, label) => h('label', {}, (boxes[scope] = h('input', {
    type: 'checkbox', class: 'switch', role: 'switch', checked: granted.has(scope),
    onchange: (e) => { e.target.checked ? granted.add(scope) : granted.delete(scope); onchange([...granted]); },
  })), label);
  const el = h('div', { class: 'perms' }, resources.map(([id, name, read, write]) => h('div', { class: 'perm' },
    h('strong', {}, name), box(`${id}:read`, read), box(`${id}:write`, write))));
  const set = (next) => {
    granted.clear();
    for (const s of next) granted.add(s);
    for (const [scope, input] of Object.entries(boxes)) input.checked = granted.has(scope);
    onchange([...granted]);
  };
  return { el, set };
}

function showSecrets(app) {
  const secret = (label, value) => h('label', {}, label, h('div', { class: 'secret' }, h('code', {}, value),
    h('button', { onclick: act(async () => { await navigator.clipboard.writeText(value); toast('Copied'); }) }, 'Copy')));
  openDialog(
    h('h2', {}, `${app.name} is connected`),
    h('p', {}, 'Copy these now. Vlyra only keeps a fingerprint of the token, so it cannot show it again.'),
    secret('API token', app.token),
    app.subsonic_password && secret('Subsonic password', app.subsonic_password),
    h('dl', { class: 'how' },
      h('dt', {}, 'Server address'), h('dd', {}, h('code', {}, location.origin)),
      h('dt', {}, 'Jellyfin apps'), h('dd', {}, 'Username ', h('code', {}, app.name), ', password is the API token.'),
      app.subsonic_password && h('dt', {}, 'Subsonic apps'), app.subsonic_password && h('dd', {}, 'Username ', h('code', {}, app.name), ', password is the Subsonic password.'),
      h('dt', {}, 'Vlyra API'), h('dd', {}, 'Send ', h('code', {}, 'Authorization: Bearer <token>'), ' to ', h('code', {}, '/api/v1'), '.')),
    h('div', { class: 'row' }, h('button', { class: 'primary', onclick: () => $('#dialog').close() }, 'Done')));
}

async function appsView(render, params) {
  const apps = await api('/apps');
  const creating = params.has('new');
  const selected = creating ? null : apps.find((a) => a.id === Number(params.get('id'))) || apps[0];
  const detail = h('div', { class: 'detail' });
  render(
    h('div', { class: 'head' }, h('div', {}, h('h1', {}, 'Apps'),
      h('p', {}, 'Every player and integration signs in as an app, and can only do what you allow. Changes apply straight away.'))),
    h('div', { class: 'split' },
      h('div', { class: 'side' },
        go('#/apps?new', 'primary', icon('plus'), 'Connect an app'),
        apps.map((a) => h('a', { href: `#/apps?id=${a.id}`, 'aria-current': selected && a.id === selected.id ? 'page' : null },
          h('strong', {}, h('span', { class: 'dot' + (a.enabled ? '' : ' off') }), a.name),
          h('span', { class: 'small' }, a.enabled ? `Last seen ${when(a.last_seen)}` : 'Access paused')))),
      detail));

  if (creating || !selected) {
    let scopes = presets.Player;
    const name = h('input', { placeholder: 'Symfonium on my phone, Lyrics fetcher…', required: true, maxlength: 64 });
    const subsonic = h('input', { type: 'checkbox', class: 'switch', role: 'switch' });
    const chips = {};
    const grid = permissions(scopes, (next) => {
      scopes = next;
      for (const [label, chip] of Object.entries(chips)) chip.setAttribute('aria-pressed', String(presets[label].length === next.length && presets[label].every((s) => next.includes(s))));
    });
    const create = act(async (event) => {
      event.preventDefault();
      const made = await api('/apps', { method: 'POST', body: { name: name.value, scopes, subsonic: subsonic.checked } });
      location.hash = `#/apps?id=${made.id}`;
      showSecrets(made);
    });
    detail.replaceChildren(h('form', { class: 'detail', onsubmit: create },
      h('div', {}, h('h2', {}, apps.length ? 'Connect an app' : 'Connect your first app'),
        h('p', { class: 'muted', style: 'margin-top:4px;max-width:60ch' }, 'A music player, a lyrics fetcher, a tagger, a scrobbler: anything that should use or improve your library.')),
      h('label', {}, 'What is it called?', name),
      h('div', { class: 'stack' },
        h('div', { class: 'head' }, h('h3', {}, 'What may it do?'),
          h('div', { class: 'row' }, Object.keys(presets).map((label) => (chips[label] = h('button', { type: 'button', class: 'chip', 'aria-pressed': String(label === 'Player'), onclick: () => grid.set(presets[label]) }, label))))),
        grid.el),
      h('label', { class: 'setting', style: 'border:0;padding:0' }, subsonic,
        h('span', {}, h('strong', {}, 'It is a Subsonic app'), h('span', { class: 'small' }, 'Subsonic apps need their own password. Jellyfin apps and integrations use the API token.'))),
      h('div', { class: 'row' }, h('button', { class: 'primary' }, 'Connect'))));
    name.focus();
    return;
  }

  const app = selected;
  const update = (body, message) => act(async () => { await api(`/apps/${app.id}`, { method: 'PUT', body }); toast(message); })();
  const changes = await api(`/activity?app_id=${app.id}`);
  detail.replaceChildren(
    h('div', { class: 'head' },
      h('div', {}, h('h2', { style: 'font-size:28px' }, app.name),
        h('p', {}, h('span', { class: 'status' + (app.enabled ? '' : ' off') }, app.enabled ? 'Active' : 'Access paused'), ` · connected ${when(app.created_at)}`)),
      h('div', { class: 'row' },
        h('button', { onclick: act(async () => {
          await api(`/apps/${app.id}`, { method: 'PUT', body: { enabled: !app.enabled } });
          toast(app.enabled ? 'Access paused' : 'Access restored');
          route();
        }) }, app.enabled ? 'Pause access' : 'Restore access'),
        h('button', { class: 'ghost danger', onclick: act(async () => {
          if (await confirmDialog(`Remove ${app.name}?`, 'Its token stops working immediately. Everything it contributed stays in your library.', 'Remove app')) {
            await api(`/apps/${app.id}`, { method: 'DELETE' });
            location.hash = '#/apps';
            route();
          }
        }) }, 'Remove'))),
    h('div', { class: 'section' }, h('h3', {}, 'Permissions'),
      permissions(app.scopes.split(' ').filter(Boolean), (next) => update({ scopes: next }, 'Permissions updated')).el),
    h('div', { class: 'section' }, h('h3', {}, 'How it signs in'),
      h('dl', { class: 'how' },
        h('dt', {}, 'Server address'), h('dd', {}, h('code', {}, location.origin)),
        h('dt', {}, 'Jellyfin and Vlyra API'), h('dd', {}, 'Username ', h('code', {}, app.name), ' with its API token, shown once when it was connected.'),
        h('dt', {}, 'Subsonic'), h('dd', {}, app.subsonic_password ? 'Has its own Subsonic password.' : 'Not set up. Connect it again as a Subsonic app if it needs this.'))),
    h('div', { class: 'section' },
      h('div', { class: 'head' }, h('h3', {}, 'What it changed'), changes.length > 5 && h('a', { class: 'link small', href: `#/activity?app=${app.id}` }, `See all ${changes.length}`)),
      changes.length ? h('div', { class: 'list' }, changes.slice(0, 5).map(changeRow)) : h('p', {}, 'Nothing yet. Anything it writes to your library will be listed here.')));
}

function describe(c) {
  const what = c.label || `${c.entity} ${c.entity_id}`;
  if (c.field === 'created') return [`created the playlist ${what}`, false];
  if (c.field === 'deleted') return [`deleted the playlist ${what}`, false];
  if (c.field === 'items') return [`changed the tracks in ${what}`, true];
  if (c.field === 'rating') return [c.new_value === '0' ? `cleared the rating of ${what}` : `rated ${what} ${plural(Number(c.new_value), 'star')}`, false];
  if (c.field === 'artwork') return [`replaced the cover of ${what}`, false];
  if (c.field === 'lyrics') return [`${c.old_value ? 'rewrote' : 'added'} the lyrics of ${what}`, false];
  return [`changed the ${c.field.replace('_no', ' number')} of ${what}`, true];
}
function changeRow(c) {
  const [text, diff] = describe(c);
  const who = c.app_name === 'admin' ? 'You' : c.app_name;
  return h('div', { class: 'item' },
    h('span', { class: 'who', style: `--hue:${hueOf(c.app_name)}` }, h('i', {})),
    h('div', { style: 'min-width:0' },
      h('div', {}, h('strong', {}, who), ` ${text}`),
      diff && h('div', { class: 'diff' }, c.old_value && h('del', {}, c.old_value), c.old_value && ' → ', h('ins', {}, c.new_value || 'empty'))),
    h('span', { class: 'when' }, when(c.at)));
}

async function activityView(render, params) {
  const appId = params.get('app');
  const [log, apps] = await Promise.all([api('/activity' + (appId ? `?app_id=${appId}` : '')), api('/apps')]);
  const filter = h('select', { 'aria-label': 'Show changes by', style: 'width:auto', onchange: (e) => (location.hash = '#/activity' + (e.target.value ? `?app=${e.target.value}` : '')) },
    h('option', { value: '' }, 'Everyone'),
    h('option', { value: '0', selected: appId === '0' }, 'You'),
    apps.map((a) => h('option', { value: a.id, selected: String(a.id) === appId }, a.name)));
  render(
    h('div', { class: 'head' },
      h('div', {}, h('h1', {}, 'Activity'), h('p', {}, 'Every change to your library, and who made it.')),
      filter),
    log.length
      ? h('div', { class: 'list' }, log.map(changeRow))
      : empty('No changes yet', 'Edits you make and anything your apps contribute will be recorded here.'));
}

async function settingsView(render) {
  const s = await api('/settings');
  const dir = h('input', { value: s.media_dir, placeholder: '/path/to/your/music', required: true, 'aria-label': 'Media folder on the server' });
  const saveDir = act(async (event) => {
    event.preventDefault();
    await api('/settings', { method: 'PUT', body: { media_dir: dir.value } });
    toast('Folder saved. Scanning…');
    setTimeout(route, 800);
  });
  const scrobbler = (id, name, user, about, form) => h('div', { class: 'stack' },
    h('p', {}, h('strong', {}, name), ' ', h('span', { class: 'status' + (user ? '' : ' off') }, user ? `Connected as ${user}` : 'Not connected')),
    user
      ? h('div', { class: 'row' }, h('button', { type: 'button', onclick: act(async () => { await api(`/scrobblers/${id}`, { method: 'DELETE' }); toast(`${name} disconnected`); route(); }) }, 'Disconnect'))
      : [h('p', { class: 'small muted' }, about), form]);
  const secretInput = (label) => h('input', { type: 'password', placeholder: label, 'aria-label': label, required: true, autocomplete: 'off' });
  const lbToken = secretInput('ListenBrainz user token');
  const lfKey = secretInput('Last.fm API key');
  const lfSecret = secretInput('Last.fm shared secret');
  const outside = (href, text) => h('a', { class: 'link', href, target: '_blank', rel: 'noopener noreferrer' }, text);
  const connectListenBrainz = act(async (event) => {
    event.preventDefault();
    const { user } = await api('/scrobblers/listenbrainz', { method: 'PUT', body: { token: lbToken.value } });
    toast(`Scrobbling to ListenBrainz as ${user}`);
    route();
  });
  const connectLastfm = act(async (event) => {
    event.preventDefault();
    const { url } = await api('/scrobblers/lastfm', { method: 'POST', body: { key: lfKey.value, secret: lfSecret.value } });
    openDialog(
      h('h2', {}, 'Allow Vlyra on Last.fm'),
      h('p', {}, outside(url, 'Open Last.fm'), ' in a new tab and choose “Yes, allow access”. Then come back here to finish.'),
      h('div', { class: 'row' },
        h('button', { class: 'primary', onclick: act(async () => {
          const { user } = await api('/scrobblers/lastfm', { method: 'PUT' });
          $('#dialog').close();
          toast(`Scrobbling to Last.fm as ${user}`);
          route();
        }) }, 'I have allowed it'),
        h('button', { onclick: () => $('#dialog').close() }, 'Cancel')));
  });
  render(
    h('div', { class: 'head' }, h('h1', {}, 'Settings')),
    h('div', { class: 'detail', style: 'max-width:760px' },
      h('form', { class: 'stack', onsubmit: saveDir },
        h('h3', {}, 'Media folder'),
        h('p', { class: 'muted' }, s.scanning ? 'Scanning now…' : `${plural(s.items, 'item')} indexed.`,
          ' Scans add new files and re-read changed ones, and never overwrite edits made by you or your apps.',
          !s.ffprobe && ' ffprobe is not installed on the server, so videos and exotic formats cannot be tagged.'),
        h('div', { class: 'secret' }, dir, h('button', { class: 'primary' }, 'Save')),
        h('div', { class: 'row' }, h('button', { type: 'button', disabled: s.scanning || !s.media_dir, onclick: act(async () => { await api('/scan', { method: 'POST' }); toast('Scan started'); setTimeout(route, 800); }) }, 'Scan again'))),
      h('div', { class: 'section' },
        h('h3', {}, 'Protocols'),
        h('p', {}, 'Different doors into the same library. Switching one off takes effect immediately, with no restart.'),
        h('div', {}, s.protocols.map((p) => h('label', { class: 'setting' },
          h('input', { type: 'checkbox', class: 'switch', role: 'switch', checked: p.enabled, onchange: act(async (e) => {
            await api('/settings', { method: 'PUT', body: { protocols: { [p.id]: e.target.checked } } });
            toast(`${p.name} ${e.target.checked ? 'on' : 'off'}`);
          }) }),
          h('span', {}, h('strong', {}, p.name), ' ', h('code', {}, p.endpoint), h('span', { class: 'small' }, p.about)))))),
      h('div', { class: 'section' },
        h('h3', {}, 'Scrobbling'),
        h('p', {}, 'Every finished listen, from the web player or any app allowed to report listens, is also sent to the accounts you connect here.'),
        scrobbler('listenbrainz', 'ListenBrainz', s.listenbrainz,
          ['Paste the user token from ', outside('https://listenbrainz.org/settings/', 'listenbrainz.org/settings'), '.'],
          h('form', { class: 'secret', onsubmit: connectListenBrainz }, lbToken, h('button', { class: 'primary' }, 'Connect'))),
        scrobbler('lastfm', 'Last.fm', s.lastfm,
          ['Last.fm needs an API account of your own: ', outside('https://www.last.fm/api/account/create', 'create one'), ' (leave the callback URL empty), then enter its key and secret.'],
          h('form', { class: 'stack', onsubmit: connectLastfm }, h('div', { class: 'two' }, lfKey, lfSecret), h('div', { class: 'row' }, h('button', { class: 'primary' }, 'Connect'))))),
      h('div', { class: 'section' },
        h('div', { class: 'head' }, h('p', {}, `Vlyra ${s.version} · free software under the GPL-3.0 licence.`),
          h('button', { onclick: () => $('#signout').click() }, 'Sign out')))));
  if (s.scanning) setTimeout(() => location.hash === '#/settings' && route(), 1500);
}

const views = { library: libraryView, playlists: playlistsView, history: historyView, apps: appsView, activity: activityView, settings: settingsView };
let turn = 0;

async function route() {
  const [path, query] = location.hash.slice(2).split('?');
  const name = views[path] ? path : 'library';
  const mine = ++turn;
  for (const link of document.querySelectorAll('#rail a[data-icon]')) {
    link.getAttribute('href') === `#/${name}` ? link.setAttribute('aria-current', 'page') : link.removeAttribute('aria-current');
  }
  const view = $('#view');
  // A slow response must never paint over the page the user has moved on to.
  const render = (...nodes) => { if (mine === turn) view.replaceChildren(...nodes); };
  view.classList.remove('lit');
  try {
    await views[name](render, new URLSearchParams(query || ''), view);
  } catch (err) {
    toast(err.message, true);
  }
}
addEventListener('hashchange', () => { closePanel(); scrollTo(0, 0); route(); });

async function boot() {
  const me = await fetch('/api/v1/me').then((r) => r.json());
  $('#shell').hidden = !me.authenticated;
  $('#auth').hidden = me.authenticated;
  if (me.authenticated) return route();
  audio.pause();
  $('#player').hidden = true;
  const setup = me.setup_needed;
  $('#auth-intro').textContent = setup ? 'Welcome. Choose a password to protect your server.' : 'Sign in to your library.';
  $('#auth-submit').textContent = setup ? 'Get started' : 'Sign in';
  $('#auth-confirm-row').hidden = !setup;
  $('#auth-password').autocomplete = setup ? 'new-password' : 'current-password';
  $('#auth-form').onsubmit = act(async (event) => {
    event.preventDefault();
    const password = $('#auth-password').value;
    if (setup && password !== $('#auth-confirm').value) throw new Error('The two passwords do not match.');
    await api(setup ? '/setup' : '/session', { method: 'POST', body: { password } });
    $('#auth-form').reset();
    boot();
  });
  $('#auth-password').focus();
}
for (const el of document.querySelectorAll('[data-icon]')) el.prepend(icon(el.dataset.icon));
$('#signout').onclick = act(async () => { await api('/session', { method: 'DELETE' }); boot(); });

boot();

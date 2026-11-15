import { rpc } from '../supabase.js';
import { state, refreshMe, getConfig, go } from '../state.js';
import { el, hms, onLeave, errText } from '../ui.js';

const GAMES = [
  { id: 'chest', nm: 'Truhen', ds: 'Truhen öffnen, Bomben meiden', file: 'chest.js', gi: true, ic: '💰', c: '#f5b942' },
  { id: 'wheel', nm: 'Glücksrad', ds: 'Drehen, mit Autospin', file: 'wheel.js', gi: true, ic: '🎡', c: '#a78bfa' },
  { id: 'slots', nm: 'Slotmaschine', ds: 'Drei gleiche Symbole', file: 'slots.js', gi: true, ic: '🎰', c: '#fb7185' },
  { id: 'blackjack', nm: 'Blackjack', ds: 'Gegen den Dealer', file: 'blackjack.js', gi: true, ic: '🃏', c: '#60a5fa' },
  { id: 'race', nm: 'Pferderennen', ds: 'Täglich 19:00 Uhr', file: 'race.js', live: true, ic: '🏇', c: '#34d399' },
  { id: 'plinko', nm: 'Plinko', ds: 'Kugel fallen lassen', file: 'plinko.js', ic: '🔮', c: '#c084fc' },
  { id: 'scratch', nm: 'Rubbellose', ds: 'Felder freirubbeln', file: 'scratchcards.js', ic: '🎟️', c: '#f472b6' },
  { id: 'hilo', nm: 'Higher or Lower', ds: 'Höher oder tiefer', file: 'higher-lower.js', ic: '🎲', c: '#38bdf8' },
  { id: 'poker', nm: 'Video Poker', ds: 'Jacks or Better', file: 'video-poker.js', ic: '♠️', c: '#2dd4bf' },
  { id: 'stocks', nm: 'Börse', ds: 'Erfundene Aktien handeln', file: 'stock-market.js', ic: '📈', c: '#4ade80' },
];

export function racePhase(st, now) {
  if (st.phase === 'finished' && st.next_open_ms && now >= st.next_open_ms) return 'reload';
  if (now < st.t_open_ms) return 'waiting';
  if (now < st.t_start_ms) return 'betting';
  if (now < st.t_end_ms) return 'racing';
  return 'finished';
}

export async function renderGames(box) {
  const [, cfg] = await Promise.all([refreshMe(), getConfig()]);
  if (state.me.is_admin && !state.me.is_test) {
    const a = el('div', 'card'); a.appendChild(el('h2', null, 'Spiele'));
    a.appendChild(el('p', null, 'Admin-Konten können nicht mitspielen. Nimm dafür das Test-Konto.')); box.appendChild(a); return;
  }
  if (state.sub) {
    const g = GAMES.find((x) => x.id === state.sub);
    if (g) return openGame(box, g, cfg);
  }
  const grid = el('div', 'tiles'); let liveEl = null;
  GAMES.forEach((g) => {
    const t = cfg && cfg.toggles && cfg.toggles[g.id], off = t && t.enabled === false;
    const d = el('div', 'tile' + (off ? ' off' : '')); d.style.setProperty('--c', g.c);
    d.appendChild(el('div', 'gic', g.ic));
    const top = el('div'); top.appendChild(el('div', 'nm', g.nm)); top.appendChild(el('div', 'ds', off ? 'Pausiert' : g.ds)); d.appendChild(top);
    if (g.live && !off) { liveEl = el('div', 'live', ''); d.appendChild(liveEl); }
    if (!off) d.onclick = () => go('games', g.id);
    grid.appendChild(d);
  });
  box.appendChild(grid);
  setTimeout(() => GAMES.forEach((g) => import('./' + g.file).catch(() => {})), 800); // Spiele vorladen
  if (liveEl) {
    Promise.resolve(rpc('race_state')).then((rs) => {
      if (!rs.data || !liveEl.isConnected) return;
      const st = rs.data, off = st.server_ms - Date.now();
      const upd = () => {
        const now = Date.now() + off, ph = racePhase(st, now);
        liveEl.textContent = ph === 'waiting' ? 'Wetten ab 18:00, in ' + hms(st.t_open_ms - now)
          : ph === 'betting' ? 'Wetten offen, noch ' + hms(st.t_start_ms - now)
          : ph === 'racing' ? 'Läuft live' : ph === 'finished' ? 'Nächstes Rennen in ' + hms((st.next_start_ms || now) - now) : '';
      };
      upd(); const iv = setInterval(upd, 1000); onLeave(() => clearInterval(iv));
    });
  }
}

async function openGame(box, g, cfg) {
  const back = el('button', 'sec back', 'Zurück zu den Spielen'); back.onclick = () => go('games'); box.appendChild(back);
  const wrap = el('div', 'gamewrap'); box.appendChild(wrap);
  const t = cfg && cfg.toggles && cfg.toggles[g.id];
  if (t && t.enabled === false) { wrap.appendChild(el('p', 'msg', 'Dieses Spiel ist gerade pausiert.')); return; }
  const title = el('div', 'stat'); title.style.marginBottom = '10px';
  title.appendChild(el('b', null, g.nm));
  const bal = el('span'); const bb = el('b', null, String(state.me.balance)); bb.setAttribute('data-bal', ''); bal.appendChild(bb); bal.appendChild(document.createTextNode(' Coins'));
  title.appendChild(bal); wrap.appendChild(title);
  const inner = el('div'); wrap.appendChild(inner);
  let gi = null;
  if (g.gi) { const r = await rpc('game_info'); if (r.error || !r.data) { inner.appendChild(el('p', 'msg', errText(r.error))); return; } gi = r.data; }
  const m = await import('./' + g.file);
  await m.init(inner, { cfg, gi, toggle: t || { min_stake: 1, max_stake: 1000 } });
}

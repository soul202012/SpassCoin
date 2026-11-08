import { rpc } from '../supabase.js';
import { state, refreshMe, getConfig, go } from '../state.js';
import { el, hms, onLeave, errText } from '../ui.js';

const GAMES = [
  { id: 'chest', ic: '🧰', nm: 'Truhen', ds: 'Öffne Truhen, meide Bomben', file: 'chest.js', gi: true },
  { id: 'wheel', ic: '🎡', nm: 'Glücksrad', ds: 'Mit Autospin', file: 'wheel.js', gi: true },
  { id: 'slots', ic: '🎰', nm: 'Slotmaschine', ds: 'Drei gleiche gewinnen, mit Autospin', file: 'slots.js', gi: true },
  { id: 'blackjack', ic: '🃏', nm: 'Blackjack', ds: 'Schlage den Dealer', file: 'blackjack.js', gi: true },
  { id: 'race', ic: '🏇', nm: 'Pferderennen', ds: 'Live um 19:00 Uhr', file: 'race.js', live: true },
  { id: 'plinko', ic: '🔴', nm: 'Plinko', ds: 'Lass die Kugel fallen', file: 'plinko.js' },
  { id: 'scratch', ic: '🎟️', nm: 'Rubbellose', ds: 'Freirubbeln und gewinnen', file: 'scratchcards.js' },
  { id: 'hilo', ic: '🔼', nm: 'Higher or Lower', ds: 'Höher oder tiefer?', file: 'higher-lower.js' },
  { id: 'poker', ic: '♠️', nm: 'Video Poker', ds: 'Jacks or Better', file: 'video-poker.js' },
  { id: 'stocks', ic: '📈', nm: 'SpassCoin-Börse', ds: 'Erfundene Aktien handeln', file: 'stock-market.js' },
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
    a.appendChild(el('p', null, 'Admin-Konten können nicht mitspielen. Zum Ausprobieren nimm das Test-Konto.')); box.appendChild(a); return;
  }
  if (state.sub) {
    const g = GAMES.find((x) => x.id === state.sub);
    if (g) return openGame(box, g, cfg);
  }
  box.appendChild(el('p', 'sub', 'Wähle ein Spiel. Alle Spiele sind jederzeit freigeschaltet. Alle Coins sind nur zum Spass.'));
  const grid = el('div', 'tiles'); let liveEl = null;
  GAMES.forEach((g) => {
    const t = cfg && cfg.toggles && cfg.toggles[g.id];
    const off = t && t.enabled === false;
    const d = el('div', 'tile' + (off ? ' off' : ''));
    d.appendChild(el('div', 'ic', g.ic)); d.appendChild(el('div', 'nm', g.nm)); d.appendChild(el('div', 'ds', off ? 'Gerade pausiert' : g.ds));
    if (g.live && !off) { liveEl = el('div', 'live', '…'); d.appendChild(liveEl); }
    if (!off) d.onclick = () => go('games', g.id);
    grid.appendChild(d);
  });
  box.appendChild(grid);
  if (liveEl) {
    const rs = await rpc('race_state');
    if (rs.data) {
      const st = rs.data, off = st.server_ms - Date.now();
      const upd = () => {
        const now = Date.now() + off, ph = racePhase(st, now);
        liveEl.textContent = ph === 'waiting' ? 'Wetten ab 18:00 · in ' + hms(st.t_open_ms - now)
          : ph === 'betting' ? '🟢 Wetten offen · noch ' + hms(st.t_start_ms - now)
          : ph === 'racing' ? '🔴 Läuft live!' : ph === 'finished' ? 'Nächstes Rennen in ' + hms((st.next_start_ms || now) - now) : '…';
      };
      upd(); const iv = setInterval(upd, 1000); onLeave(() => clearInterval(iv));
    }
  }
}

async function openGame(box, g, cfg) {
  const back = el('button', 'sec back', '← Zurück zu den Spielen'); back.onclick = () => go('games'); box.appendChild(back);
  const bal = el('p', 'hint'); bal.appendChild(document.createTextNode('Dein Kontostand: '));
  const bb = el('b', null, String(state.me.balance)); bb.id = 'gbal'; bal.appendChild(bb); bal.appendChild(document.createTextNode(' Coins')); box.appendChild(bal);
  const t = cfg && cfg.toggles && cfg.toggles[g.id];
  if (t && t.enabled === false) { box.appendChild(el('p', 'msg', 'Dieses Spiel ist gerade pausiert.')); return; }
  const inner = el('div'); box.appendChild(inner);
  let gi = null;
  if (g.gi) { const r = await rpc('game_info'); if (r.error || !r.data) { inner.appendChild(el('p', 'msg', errText(r.error))); return; } gi = r.data; }
  const info = [];
  if (t) { info.push('Einsatz: ' + t.min_stake + ' bis ' + t.max_stake + ' Coins'); if (t.daily_limit) info.push('Tageslimit: ' + t.daily_limit + ' Runden'); }
  const m = await import('./' + g.file);
  await m.init(inner, { cfg, gi, toggle: t || { min_stake: 1, max_stake: 1000 } });
  if (info.length) { const p = el('p', 'hint', info.join(' · ')); p.style.marginTop = '6px'; box.appendChild(p); }
}

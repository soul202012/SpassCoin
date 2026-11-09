import { sb, rpc } from './supabase.js';
import { el, inp, modal } from './ui.js';

let mode = 'login', err = '', info = '', busy = false;
const cleanName = (u) => u.trim().toLowerCase().replace(/[^a-z0-9_.-]/g, '');

// Anmeldeseite. onDone wird nach erfolgreicher Anmeldung aufgerufen.
export function renderAuth(root, onDone) {
  root.innerHTML = '';
  const h = el('header'); h.appendChild(el('h1', null, '🪙 SpassCoin')); root.appendChild(h);
  root.appendChild(el('p', 'sub', 'Unser Spass-Coin. Alle Coins sind rein digital und nur zum Spass.'));
  const c = el('div', 'card'); c.appendChild(el('h2', null, mode === 'login' ? 'Anmelden' : 'Konto erstellen'));
  const u = inp(mode === 'login' ? 'Benutzername oder E-Mail' : 'Benutzername'), em = inp('E-Mail', 'email'), p = inp('Passwort', 'password');
  u.autocapitalize = 'none'; u.autocomplete = 'username'; p.autocomplete = mode === 'login' ? 'current-password' : 'new-password';
  c.appendChild(u); if (mode === 'register') c.appendChild(em); c.appendChild(p);
  if (err) c.appendChild(el('p', 'err', err));
  if (info) c.appendChild(el('p', 'okmsg', info));
  const go = el('button', 'full', mode === 'login' ? 'Anmelden' : 'Registrieren'); go.disabled = busy;
  go.onclick = async () => {
    err = ''; info = ''; go.disabled = true;
    try {
      if (mode === 'login') {
        const login = u.value.trim(); let email = login;
        if (!login || !p.value) throw 'Bitte alles ausfüllen.';
        if (login.indexOf('@') < 0) {
          const r = await rpc('email_for_username', { uname: login });
          if (!r.data) throw 'Benutzername oder Passwort stimmt nicht.';
          email = r.data;
        }
        const s = await sb.auth.signInWithPassword({ email, password: p.value });
        if (s.error) throw 'Benutzername oder Passwort stimmt nicht (oder die E-Mail ist noch nicht bestätigt).';
        onDone();
      } else {
        const name = cleanName(u.value), mail = em.value.trim();
        if (name.length < 3) throw 'Der Benutzername braucht mindestens 3 Zeichen (Buchstaben, Zahlen, _ . -).';
        if (!/^\S+@\S+\.\S+$/.test(mail)) throw 'Bitte eine gültige E-Mail eingeben.';
        if (p.value.length < 6) throw 'Das Passwort braucht mindestens 6 Zeichen.';
        const t = await rpc('username_taken', { uname: name });
        if (t.data) throw 'Diesen Benutzernamen gibt es schon.';
        const s2 = await sb.auth.signUp({ email: mail, password: p.value, options: { data: { username: name } } });
        if (s2.error) throw s2.error.message.indexOf('registered') >= 0 ? 'Diese E-Mail ist schon registriert.' : 'Registrieren hat nicht geklappt: ' + s2.error.message;
        if (!s2.data.session) { mode = 'login'; info = 'Fast fertig! Bitte bestätige zuerst den Link in der E-Mail, die wir dir geschickt haben. Danach kannst du dich anmelden.'; return renderAuth(root, onDone); }
        onDone(() => modal('Willkommen, ' + name + '!', 'Dein Konto wurde erstellt. Deinen persönlichen Code findest du auf der Startseite.'));
      }
    } catch (e) { err = typeof e === 'string' ? e : 'Das hat nicht geklappt. Bitte nochmal versuchen.'; renderAuth(root, onDone); }
  };
  c.appendChild(go);
  const sw = el('p', 'hint'); sw.style.marginTop = '14px';
  const l = el('a', null, mode === 'login' ? 'Noch kein Konto? Jetzt registrieren' : 'Schon ein Konto? Anmelden'); l.href = '#';
  l.onclick = (ev) => { ev.preventDefault(); mode = mode === 'login' ? 'register' : 'login'; err = ''; info = ''; renderAuth(root, onDone); };
  sw.appendChild(l); c.appendChild(sw); root.appendChild(c);
}

# SpassCoin: Architektur

Dieses Dokument erklärt, wie die Teile zusammenhängen, und zwar auch das, was man im Code allein nicht sieht
(HTML startet JavaScript, Datenbank-Zeitpläne, Edge Functions, Löschregeln). Die Einrichtung steht im `README.md`.

## Überblick

```
Browser (statische Seite auf Netlify)
  index.html ──lädt──> js/app.js ──import()──> eine Ansicht pro Tab (coins, games, missions, ...)
        │                   │
        │                   ├─ js/supabase.js  sb (Supabase-Client), rpc(name, args)
        │                   ├─ js/state.js     state, refreshMe(), getConfig(), go()
        │                   └─ js/ui.js        el(), toast(), modal(), confirmBox(), lineChart()
        ▼
Supabase
  Postgres: Tabellen (alle gesperrt) + SECURITY-DEFINER-Funktionen (die einzige Schnittstelle)
  pg_cron:  Zeitpläne (Börse, Rettungsnetz, Push, Kontostand-Punkte, Aufräumen)
  Edge Functions: login-username, send-push
```

Es gibt keinen Build-Schritt. GitHub → Netlify veröffentlicht automatisch bei jedem Push.

## Start der Seite

1. `index.html` lädt alle CSS-Dateien und `<script type="module" src="js/app.js">`. Wichtige Module sind per
   `modulepreload` vorgeladen. Ein Notfall-Skript zeigt nach 10 Sekunden ohne Start einen Knopf zum Cache-Leeren.
2. `js/app.js` → `boot()`: fragt `sb.auth.getSession()`.
   - keine Sitzung → `renderAuth()` aus `js/auth.js` (Login/Registrierung)
   - Sitzung → `afterLogin()`: `refreshMe()` lädt das Profil, `loadSettings()` setzt Farbe/Modus, `readUrl()` liest `?tab=`,
     dann `render()`. Danach werden alle Ansichten im Hintergrund vorgeladen.
3. `render()`: baut einmal die Hülle (`buildShell()`: Kopfzeile, Desktop-Menü, Handy-Menü als kleines Popup),
   dann lädt es die Ansicht aus `VIEWS[state.tab]` und ruft ihre `render…(box)` auf. Jede Ansicht bekommt ein
   `<div class="view v-<tab>">` mit großem Seitentitel (`.ptitle`).
4. Navigation: `go(tab, sub)` → `navigate()` → schreibt `?tab=…&sub=…` in die Adresse und rendert neu.

## Ansichten (js/)

| Tab | Datei | Hauptfunktion | Daten (RPC) |
|---|---|---|---|
| home | `coins.js` | `renderHome` | Profil, `claim_daily`, `request_coins` |
| account | `coins.js` | `renderAccount` | `send_coins`, `my_transactions` (nur letzte 24 h) |
| games | `games/index.js` | `renderGames`, `openGame` | `game_info`, je Spiel eigene RPCs |
| missions | `missions/missions.js` | `renderMissions` | `my_missions`, `claim_mission` |
| rank | `leaderboard/leaderboard.js` | `renderLeaderboard` | `leaderboard_v2`, `leaderboard` |
| shop | `shop/shop.js` | `renderShop` | `shop_list` (über `cosmetics.js`), `buy_item`, `update_profile` |
| profile | `profile/profile.js` | `renderProfile` | `get_profile`, `balance_history` |
| settings | `settings.js` | `renderSettings` | `save_my_settings`, Push über `notifications.js` |
| admin | `admin/admin.js` | `renderAdmin` | `admin_*`-Funktionen |

Spiele (`js/games/*.js`) exportieren `init(box, ctx)`. Zufall und Auszahlung passieren immer in der Datenbank.

## Login und Sicherheit

- **Mit E-Mail:** `sb.auth.signInWithPassword` direkt bei Supabase.
- **Mit Benutzername:** `js/auth.js` ruft die Edge Function `login-username` auf. Sie sucht die E-Mail mit dem
  Service-Schlüssel auf dem Server, meldet an und gibt nur `access_token`/`refresh_token` zurück, nie die E-Mail.
  Nach 5 Fehlversuchen ist der Name 15 Minuten gesperrt (Tabelle `login_attempts`, Antwort 429).
- `email_for_username` und `handle_new_user` sind für die API gesperrt (Migration `20261115000002_login_hardening.sql`).
- Registrierung: Passwort mindestens 8 Zeichen mit Buchstaben und Zahlen; `username_taken` prüft den Namen.
- Alle Tabellen haben RLS ohne offene Policies (außer eigenes Profil/eigene Transaktionen lesen).
  Zugriff läuft nur über Funktionen, die selbst prüfen (`auth.uid()`, `is_admin()`).
- `is_admin()` ist auch für Test-Konten wahr (`is_admin or is_test`). Im Browser entspricht das `canAdmin()`.
- `config.js` enthält nur Öffentliches (anon-Schlüssel, öffentlicher Push-Schlüssel). Geheime Schlüssel stehen
  nur in Supabase (Edge-Function-Umgebung bzw. gesperrte Tabelle `push_config`).

## Coin-Wirtschaft

- Gesamtmenge in `game_settings.total_coins`. **Bank = Gesamtmenge − Konten der Spieler − in Aktien angelegt**
  (`bank_balance()`). Admin- und Test-Konten zählen nicht mit.
- Jede Coin-Bewegung wird in `transactions` geschrieben (`log_tx`, `send_coins`, `decide_request`, Spiele).
- Spielrunden landen in `game_rounds` (über `record_round`) und in `player_stats`.

## Daten-Aufbewahrung (wichtig)

Einzelne Transaktionen leben nur **24 Stunden** (Zeitplan `spasscoin-tx-cleanup`, jede Minute).
Damit nichts verloren geht, gibt es Zusammenfassungen (Migration `20261115000001_tx_rollup.sql`):

| Tabelle | Inhalt | Wird gefüllt von | Gelesen von |
|---|---|---|---|
| `tx_daily` | Summe rein/raus pro Spieler, Tag (Schweizer Zeit) und Art | Trigger `tx_daily_add` auf `transactions` | `leaderboard_v2` (Netto), `get_profile` (Verdient/Ausgegeben), `admin_economy` |
| `balance_points` | Kontostand alle 5 Stunden (festes Raster) | Zeitplan `spasscoin-balance-points` → `snapshot_balances()` | `balance_history` (Kontoverlauf im Profil) |

`balance_history` gibt `[{ts, balance}]` zurück, der letzte Punkt ist immer der aktuelle Stand.
Börsen-Arten (`stock_buy`, `stock_sell`) zählen nicht zu Netto/Verdient.

## Zeitpläne (pg_cron)

| Name | Wann | Was |
|---|---|---|
| `spasscoin-stocks` | jede Minute | Börsenkurse weiterrechnen |
| `spasscoin-hourly` | stündlich :05 | Rettungsnetz, Tagesschnappschuss der Wirtschaft |
| `spasscoin-push` | alle 5 Minuten | Push-Erinnerungen über `send-push` (Header `x-cron-secret`) |
| `spasscoin-balance-points` | stündlich :01 | Kontostand-Punkt, schreibt nur einmal pro 5-h-Raster |
| `spasscoin-tx-cleanup` | jede Minute | Transaktionen älter als 24 h löschen |
| `spasscoin-login-attempts-cleanup` | täglich 03:17 | alte Login-Fehlversuche löschen |

## Edge Functions (supabase/functions/)

- `send-push`: sendet Web-Push. Aufrufer: Admin aus der Seite (prüft Token + `is_admin`/`is_test`) oder pg_cron
  mit `x-cron-secret`. Liest VAPID-Schlüssel aus `push_config`. Deploy mit „Verify JWT“ **aus**.
- `login-username`: siehe Login. Deploy mit „Verify JWT“ **an**.

Achtung: Edge Functions werden nicht automatisch aus GitHub veröffentlicht. Nach Änderungen müssen sie in
Supabase neu deployt werden.

## Browser: Service Worker und Design

- `service-worker.js`: Code (js/css/html/json) zuerst aus dem Netz, nach 2,5 s aus dem Cache; Bilder/Musik aus dem
  Cache. `VERSION` hochzählen, wenn alte Caches gelöscht werden sollen. Empfängt auch Push-Nachrichten.
- Design „Midnight Gold“ mit Liquid Glass in `css/main.css`. Farben über CSS-Variablen: `--accent` und `--accent-t`
  setzt `applyTheme()` in `js/settings.js` (Akzentfarbe frei wählbar), `data-theme="light"` schaltet den hellen Modus.
  Glas: `--glass`, `--blur`, `--edge`, `--shadow`.
- Handy: kein Tab-Leiste, Menü-Knopf oben öffnet `.menu-panel` (Popup). Safe Areas und Home-Bildschirm-Modus
  (`display-mode: standalone`) sind in `main.css` berücksichtigt. Herauszoomen ist per `minimum-scale=1` gesperrt.
- PC (ab 861 px): zentrierte Spalte 1080 px; Missionen, Rangliste, Einstellungen, Konto in schmaler Spalte 760 px.

## Wo ändere ich was?

| Ich will … | Datei |
|---|---|
| einen neuen Tab | `VIEWS`, `PRIMARY`/`MORE`, `ICONS` in `js/app.js` + neue Ansicht in `js/` |
| ein neues Spiel | `GAMES` in `js/games/index.js` + `js/games/<spiel>.js` + RPC in einer neuen Migration |
| Farben/Abstände | Variablen oben in `css/main.css` |
| Datenbank ändern | neue Datei in `supabase/migrations/` (Datum vorne), dann in Supabase ausführen |
| Shop-Artikel | Admin → Shop (Tabelle `shop_items`), siehe `README.md` |

# SpassCoin 2.0

Digitale Spass-Coins mit Spielen, Missionen, Shop, Profilen, Börse und Push-Nachrichten.
Alle Coins sind rein digital und nur zum Spass. Es gibt kein echtes Geld.

Die Seite ist eine reine statische Seite (HTML, CSS, JavaScript-Module, kein Build nötig). Backend ist Supabase.
GitHub → Netlify veröffentlicht automatisch.

## Projektstruktur

```
index.html               Einstieg (lädt css/ und js/app.js)
config.js                Supabase-Adresse, öffentlicher Schlüssel, öffentlicher Push-Schlüssel (alles öffentlich)
manifest.json            App-Installation (PWA)
service-worker.js        Offline-Hülle, schnelles Laden, Push-Nachrichten
netlify.toml             Netlify-Einstellungen
css/                     main, games, casino, profile, shop, leaderboard, admin
js/
  app.js                 Start, Menü oben, Ansichten werden erst beim Öffnen geladen
  supabase.js auth.js state.js ui.js coins.js settings.js audio.js notifications.js
  games/                 chest, wheel, slots (mit Autospin), blackjack, race, plinko, scratchcards,
                         higher-lower, video-poker, stock-market, index (Kacheln)
  profile/               profile.js, profile-editor.js, cosmetics.js
  shop/ missions/ leaderboard/
  admin/                 admin.js, admin-games.js, admin-content.js, admin-push.js, forms.js
assets/
  icons/ avatars/ frames/ backgrounds/ images/
  music/                 deine MP3-Dateien + music.json
  sounds/                Hinweis: alle Effekte werden im Browser erzeugt
supabase/
  migrations/            alle SQL-Dateien (die ersten vier sind die bisherigen)
  functions/send-push/   Edge Function für Push-Nachrichten
SPASSCOIN_2_0_ALLES.sql  die neuen SQL-Dateien in einer einzigen Datei zum Einfügen
```

## Einrichtung (einmalig)

### 1. Datenbank erweitern
Supabase → **SQL Editor** → neue Abfrage → ganzen Inhalt von `SPASSCOIN_2_0_ALLES.sql` einfügen → **Run**.
Alles läuft in einer Transaktion: Geht etwas schief, ändert sich nichts. Du kannst die Datei gefahrlos mehrmals ausführen.
Bestehende Konten, Coin-Bestände und der Verlauf bleiben unverändert.

### 2. Push-Nachrichten einschalten
1. Im SQL Editor den Befehl mit dem geheimen Push-Schlüssel ausführen (hat dir Claude im Chat gegeben, steht bewusst NICHT im Projekt).
2. Supabase → **Edge Functions** → **Deploy a new function** → «Via Editor». Name: `send-push`. Den Inhalt von
   `supabase/functions/send-push/index.ts` einfügen. **«Verify JWT» ausschalten** (die Funktion prüft Aufrufer selbst). Deploy.
3. Wer SpassCoin auf dem Handy nutzt: Auf dem **iPhone** zuerst «Zum Home-Bildschirm» hinzufügen, von dort öffnen, dann in den
   Einstellungen die Benachrichtigungen einschalten. Auf **Android** reicht Chrome, am besten ebenfalls installiert.

### 3. GitHub und Netlify
Den Inhalt des Ordners `spasscoin/` ins Repository kopieren (die alte `index.html` wird ersetzt) und committen.
Netlify veröffentlicht automatisch. Es sind keine Umgebungsvariablen nötig: In `config.js` steht nur Öffentliches
(der Supabase-Schlüssel ist der öffentliche «publishable key»). Geheime Schlüssel gibt es im Frontend nicht.

### 4. Musik
MP3-Dateien in `assets/music/` legen und in `assets/music/music.json` eintragen (siehe `assets/music/LIESMICH.txt`).
Jede Datei ist einzeln austauschbar. Es gibt kein Hochladen für Spieler.

## Wie die Coin-Wirtschaft funktioniert
- Gesamtmenge: 10 000 Coins. **Bank + Konten der Spieler + in Aktien angelegte Coins = 10 000.**
- Gewinne zahlt die Bank, Verluste fliessen zurück. Ist die Bank leer, wird die Auszahlung auf den Bankstand begrenzt.
- Admin- und Test-Konten zählen nicht zum Umlauf und erscheinen in keiner Statistik.
- Tägliche Belohnung, Missionen und Rettungsnetz zahlt ebenfalls die Bank.
- Alles Wichtige (Einsätze, Zufall, Auszahlungen) passiert in der Datenbank, nie im Browser.

Standardwerte (Auszahlungsquote = was langfristig an die Spieler zurückgeht):

| Spiel | Quote |
|---|---|
| Truhen, Glücksrad, Slotmaschine | etwa 100 % (ausgeglichen) |
| Blackjack | etwa 99.5 % bei guter Strategie |
| Pferderennen | etwa 100 % (Quoten fair, abgerundet) |
| Plinko | 96.3 bis 96.4 % |
| Rubbellose | 95.5 % |
| Higher or Lower | 96 % bei bester Strategie |
| Video Poker (8/5 Jacks or Better) | 97.3 % bei perfekter Strategie |

Im Admin-Tab «Ökonomie» siehst du Einnahmen, Ausgaben, Quoten pro Spiel und den Verlauf der Bank.

## Zeitgesteuerte Aufgaben (pg_cron, werden vom SQL angelegt)
- jede Minute: Börsenkurse weiterrechnen (nur wenn das Intervall abgelaufen ist)
- stündlich: Rettungsnetz prüfen (zur eingestellten Stunde, Schweizer Zeit; pro Spieler höchstens einmal pro Tag) und Tagesschnappschuss der Wirtschaft
- alle 5 Minuten: Push-Erinnerungen (Missionen 8:00, Streak 18:00, Rennen 18:45), höchstens einmal pro Art und Tag

Das Pferderennen läuft ohne Zeitplanung: Der Server erzeugt das Rennen beim ersten Aufruf nach 18:00 Uhr und zahlt nach 19:15 Uhr
aus, sobald jemand die Seite öffnet.

## Sicherheit
- Alle Tabellen sind für Spieler gesperrt. Zugriff läuft nur über geprüfte Datenbank-Funktionen.
- Admin-Funktionen prüfen das Admin-Recht in der Datenbank.
- Coin-Buchungen sperren die betroffenen Konten, damit nichts doppelt ausgegeben wird.
- Rubbellose, Kartenspiele, Plinko und Rennen werden komplett auf dem Server entschieden.
- Push-Abos liegen in der Datenbank. Abgelaufene Abos werden beim Senden automatisch entfernt.

## Hinweise
- Es gibt ein Test-Konto (kein Teil der Bank, nicht in Ranglisten), mit dem du alles inklusive Admin-Menü testen kannst.
- Musik: Verwende nur Dateien, für die du die Nutzungsrechte hast. Die Credits-Zeile «Musik: 8bit auf Spotify» kannst du in
  `assets/music/music.json` anpassen (Künstler und Link), sobald die Musik feststeht.

// Notbremse: Falls die App nach 10 Sekunden nicht startet, Hilfe anzeigen (z. B. alter Zwischenspeicher).
// Eigene Datei statt Inline-Script, damit die Sicherheitsregel (CSP) nur Skripte von dieser Seite erlaubt.
setTimeout(function () {
  var r = document.getElementById('root');
  if (r && r.children.length === 1 && /Lade/.test(r.textContent)) {
    r.innerHTML = '<div class="card"><h2>Das Laden dauert zu lange</h2><p>Tippe auf den Knopf, um den Zwischenspeicher zu leeren und die Seite neu zu laden.</p><button class="full" id="rescue">Neu laden</button></div>';
    document.getElementById('rescue').onclick = function () {
      Promise.all([(navigator.serviceWorker ? navigator.serviceWorker.getRegistrations().then(function (rs) { return Promise.all(rs.map(function (x) { return x.unregister(); })); }) : null),
        (window.caches ? caches.keys().then(function (ks) { return Promise.all(ks.map(function (k) { return caches.delete(k); })); }) : null)]).then(function () { location.reload(); });
    };
  }
}, 10000);

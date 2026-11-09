// SpassCoin Service Worker: Offline-Hülle, schnelles Laden und Push-Benachrichtigungen
const VERSION = 'spasscoin-2.0.0';
const CORE = ['./', 'index.html', 'manifest.json', 'assets/icons/icon-192.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => Promise.allSettled(CORE.map((u) => c.add(u)))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin || req.headers.has('range')) return; // Datenbank und Musik-Streams nie anfassen
  const isCode = req.mode === 'navigate' || /\.(js|css|json|html)$/.test(url.pathname) || url.pathname === '/';
  if (isCode) {
    // Code immer frisch holen, offline aus dem Zwischenspeicher
    e.respondWith(fetch(req).then((res) => { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); return res; })
      .catch(() => caches.match(req).then((r) => r || caches.match('index.html'))));
  } else {
    // Bilder, Avatare, Rahmen, Sounds: sofort aus dem Zwischenspeicher, im Hintergrund aktualisieren
    e.respondWith(caches.match(req).then((hit) => {
      const net = fetch(req).then((res) => { if (res.ok) { const copy = res.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); } return res; }).catch(() => hit);
      return hit || net;
    }));
  }
});

// Push-Benachrichtigungen
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: 'SpassCoin', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'SpassCoin', {
    body: d.body || '', icon: 'assets/icons/icon-192.png', tag: d.category || 'spasscoin', data: { url: d.url || './' },
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const target = new URL((e.notification.data && e.notification.data.url) || './', self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) { c.postMessage({ type: 'navigate', url: target }); return c.focus(); } }
    return self.clients.openWindow(target);
  }));
});

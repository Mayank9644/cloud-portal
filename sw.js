/* Fincept Cloud Host Control — Service Worker */
const CACHE_NAME = "fincept-cloud-host-v3";
const SHELL_ASSETS = [
  "./",
  "./index.html",
  "./manifest.json",
  "./assets/icon.svg"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const reqUrl = new URL(event.request.url);

  // Network-only for live dynamic data (endpoints, APIs, tunnel queries, cache-busting queries)
  if (
    reqUrl.pathname.endsWith("endpoints.json") ||
    reqUrl.pathname.includes("/api/") ||
    reqUrl.search.includes("t=") ||
    reqUrl.hostname.includes("trycloudflare.com") ||
    event.request.method !== "GET"
  ) {
    event.respondWith(fetch(event.request));
    return;
  }

  // Stale-While-Revalidate for shell assets
  event.respondWith(
    caches.match(event.request).then((cachedResponse) => {
      const fetchPromise = fetch(event.request)
        .then((networkResponse) => {
          if (networkResponse && networkResponse.status === 200 && networkResponse.type === "basic") {
            const responseClone = networkResponse.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, responseClone));
          }
          return networkResponse;
        })
        .catch(() => cachedResponse);

      return cachedResponse || fetchPromise;
    })
  );
});

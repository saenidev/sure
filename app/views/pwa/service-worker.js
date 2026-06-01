const CACHE_VERSION = '<%= ENV.fetch("BUILD_COMMIT_SHA", "development") %>';
const OFFLINE_CACHE = `sure-offline-${CACHE_VERSION}`;
const ROUTE_CACHE = `sure-routes-${CACHE_VERSION}`;
const ROUTE_TTL_MS = 30 * 1000;
const OFFLINE_ASSETS = [
  '/offline.html',
  '/logo-offline.svg'
];

const ROUTE_CACHE_PATHS = new Set([
  '/',
  '/transactions',
  '/reports',
  '/budgets',
  '/forecast',
  '/chats'
]);

// Install event - cache the offline page and assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(OFFLINE_CACHE).then((cache) => {
      return cache.addAll(OFFLINE_ASSETS);
    })
  );
  // Activate immediately
  self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (![OFFLINE_CACHE, ROUTE_CACHE].includes(cacheName)) {
            return caches.delete(cacheName);
          }
        })
      );
    }).then(() => {
      // Take control of all pages immediately
      return self.clients.claim();
    })
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (url.origin === self.location.origin && request.method !== 'GET') {
    event.waitUntil(clearRouteCache());
    return;
  }

  if (shouldHandleRouteRequest(request, url)) {
    event.respondWith(handleRouteRequest(request));
    return;
  }

  if (OFFLINE_ASSETS.some(asset => url.pathname === asset)) {
    event.respondWith(
      caches.match(request).then((response) => {
        return response || fetch(request);
      })
    );
  }
});

self.addEventListener('message', (event) => {
  if (event.data?.type === 'CLEAR_ROUTE_CACHE') {
    event.waitUntil(clearRouteCache());
  }
});

function shouldHandleRouteRequest(request, url) {
  if (url.origin !== self.location.origin) return false;
  if (request.method !== 'GET') return false;
  if (!ROUTE_CACHE_PATHS.has(url.pathname)) return false;

  return isHtmlRequest(request);
}

function isHtmlRequest(request) {
  return request.mode === 'navigate' || request.headers.get('Accept')?.includes('text/html');
}

async function handleRouteRequest(request) {
  if (request.headers.get('X-Sure-Route-Preload') === '1') {
    const response = await fetch(request);
    try {
      await cacheRouteResponse(request, response);
    } catch (_error) {
      await clearRouteCache();
    }
    return response;
  }

  const cached = await freshCachedRoute(request);
  if (cached) return cached;

  return fetch(request).catch((error) => {
    if (request.mode === 'navigate' && (error.name === 'TypeError' || !navigator.onLine)) {
      return caches.match('/offline.html');
    }

    throw error;
  });
}

async function cacheRouteResponse(request, response) {
  if (!response.ok || !response.headers.get('Content-Type')?.includes('text/html')) return;

  const headers = new Headers(response.headers);
  headers.set('X-Sure-Cached-At', Date.now().toString());

  const cachedResponse = new Response(await response.clone().blob(), {
    status: response.status,
    statusText: response.statusText,
    headers,
  });

  const cache = await caches.open(ROUTE_CACHE);
  await cache.put(request, cachedResponse);
}

async function freshCachedRoute(request) {
  const cache = await caches.open(ROUTE_CACHE);
  const response = await cache.match(request, { ignoreVary: true });
  if (!response) return null;

  const cachedAt = Number(response.headers.get('X-Sure-Cached-At') || 0);
  if (Date.now() - cachedAt > ROUTE_TTL_MS) {
    await cache.delete(request, { ignoreVary: true });
    return null;
  }

  return response;
}

function clearRouteCache() {
  return caches.delete(ROUTE_CACHE);
}

// Add a service worker for processing Web Push notifications:
//
// self.addEventListener("push", async (event) => {
//   const { title, options } = await event.data.json()
//   event.waitUntil(self.registration.showNotification(title, options))
// })
//
// self.addEventListener("notificationclick", function(event) {
//   event.notification.close()
//   event.waitUntil(
//     clients.matchAll({ type: "window" }).then((clientList) => {
//       for (let i = 0; i < clientList.length; i++) {
//         let client = clientList[i]
//         let clientPath = (new URL(client.url)).pathname
//
//         if (clientPath == event.notification.data.path && "focus" in client) {
//           return client.focus()
//         }
//       }
//
//       if (clients.openWindow) {
//         return clients.openWindow(event.notification.data.path)
//       }
//     })
//   )
// })

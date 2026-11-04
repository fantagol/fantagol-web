/* FantaGol Web Push V1 - notification worker; no credential storage. */
/* global self */
"use strict";

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    if (event.data) payload = event.data.json();
  } catch {
    payload = {};
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) payload = {};

  const title = typeof payload.title === "string" && payload.title.length <= 120
    ? payload.title : "FantaGol";
  const body = typeof payload.body === "string" && payload.body.length <= 400
    ? payload.body : "Hai una nuova notifica.";
  const requested = typeof payload.url === "string" ? payload.url : "/leghe";
  const safePath = requested.startsWith("/") && !requested.startsWith("//") &&
    !requested.includes("\\") ? requested : "/leghe";

  event.waitUntil(self.registration.showNotification(title, {
    body,
    icon: "/icon.png",
    badge: "/icon.png",
    tag: typeof payload.tag === "string" ? payload.tag.slice(0, 80) : undefined,
    data: { url: safePath },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = event.notification.data?.url;
  const path = typeof target === "string" && target.startsWith("/") &&
    !target.startsWith("//") && !target.includes("\\") ? target : "/leghe";
  const url = new URL(path, self.location.origin);
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin === self.location.origin && "focus" in client) {
        try {
          if ("navigate" in client) await client.navigate(url.href);
          return await client.focus();
        } catch { /* Fallback to opening a same-origin window. */ }
      }
    }
    if (self.clients.openWindow) await self.clients.openWindow(url.href);
  })());
});

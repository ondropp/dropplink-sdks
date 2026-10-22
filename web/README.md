# @ondropp/dropplink-web

Dropplink for websites. See what visitors from each creator, campaign and link do on your site (pages, funnel
steps, where they drop off) and credit website orders to the creator who brought them.

Two halves, one package:

| | Runs in | Does | Key |
| --- | --- | --- | --- |
| **Script** (script tag, or `import { init } from '@ondropp/dropplink-web'`) | Every page of your site | Page views (single-page apps too), time on page, sessions, the landing's UTM tags and Dropplink click, your funnel events. | The app's **web key** (`pk_…`), public, works only on your website domains |
| **Server** (`@ondropp/dropplink-web/server`) | Your backend (Node 18+, Bun, Deno, edge) | Orders and refunds, with the visitor id, so they're credited. | The app's **server key** (`sk_…`), secret |

Money never comes from the browser. The web key is public by design, so Dropplink treats what the script sends
as behaviour only; orders and refunds come from your server.

## 1. Add your website to the app

In the Dropplink dashboard, **Settings → Project details → Website**: add your website's domains (e.g.
`yourbrand.com`, `shop.yourbrand.com`). The app gets a web key, `pk_…`. The script only works on those domains.

## 2. Add the script

Served from your own link domain, so it's first-party and blocklists don't match it:

```html
<script src="https://go.yourbrand.com/_d/s.js" data-key="pk_3f9c1e2a7b6d4c80" async></script>
```

Page views start right away. To track before the script has loaded, add this stub first; calls wait in
`dropplink.q` and run when it loads:

```html
<script>
  window.dropplink = window.dropplink || { q: [] };
  ['track', 'identify', 'logout', 'grant', 'revoke'].forEach(function (m) {
    dropplink[m] = dropplink[m] || function () { dropplink.q.push([m].concat([].slice.call(arguments))); };
  });
</script>
```

**Or npm**, with a bundler:

```ts
import { init } from '@ondropp/dropplink-web';

// Once, in the browser (in Next.js, in a client component rendered by the root layout).
const dropplink = init({ key: 'pk_3f9c1e2a7b6d4c80', endpoint: 'https://go.yourbrand.com/_d/e' });
```

| Option | Script tag | Default | |
| --- | --- | --- | --- |
| `key` | `data-key` | required | The app's web key |
| `endpoint` | `data-endpoint` | `/_d/e` beside the script; else the API host | Where batches go |
| `consent` | `data-consent="required"` | `'granted'` | Wait for `grant()` (cookie banners) |
| `spa` | `data-spa="false"` | `true` | Count `pushState` / `popstate` navigations |
| `cookieDomain` | `data-cookie-domain=".yourbrand.com"` | this host | Share the visitor across subdomains |
| `debug` | `data-debug="true"` | `false` | Console logs. Never ship it on. |

## 3. Track your funnel

The Web campaigns funnel uses these names: `page_view` (automatic), `view_item`, `add_to_cart`,
`begin_checkout`, `sign_up`, `purchase`.

```js
dropplink.track('view_item', { sku: 'RS-9' });
dropplink.track('add_to_cart', { sku: 'RS-9', price: 1499 });
dropplink.track('begin_checkout');
dropplink.identify('user_8812'); // after sign-in: your own id, never an email or phone
dropplink.logout();
```

Props: up to 20, keys `A–Z a–z 0–9 _`, values string / number / boolean / null. Anything that looks like an
email or phone number is dropped in the browser. `identify` is unverified: it links the visitor to the user in
the journey view only, never for credit.

## 4. Send orders from your server

```ts
import { DropplinkServer, readVisitorId } from '@ondropp/dropplink-web/server';

const dropplink = new DropplinkServer({ serverKey: process.env.DROPPLINK_SERVER_KEY! });

// When the order is created: keep the visitor with it (or send dropplink.getVisitorId() from the checkout).
order.droppVisitorId = readVisitorId(req.headers.cookie);

// When the payment is confirmed:
await dropplink.track({
  eventId: `order-${order.id}`, // your own id: a webhook that fires twice counts once
  visitorId: order.droppVisitorId,
  userId: order.customerId, // optional; with it the visitor is shown as this user (verified)
  name: 'purchase',
  ts: order.paidAt,
  revenue: { amount: order.total, currency: 'INR', orderId: order.id },
});
```

The order goes to the visitor's **first** Dropplink click (first touch). With a `userId`, that click also becomes
the customer's first touch, so their later orders are credited by `userId` alone, on any device. Refunds are a
negative `amount` with the refunded order's `orderId`.

`warnings`: `unknown_visitor` (no visitor with that id for this app) or `unknown_click`; the order is stored
either way. `track` retries rate limits, server errors and timeouts, then throws a `DropplinkError`. Resending
is safe.

**No script on the site?** Send the `dropp_click_id` the visitor landed with as `clickId` instead (`readClickId`).

## Consent

```js
dropplink.grant();  // start (with consent: 'required')
dropplink.revoke(); // clear the visitor id, session, click, queue and user, and stop
```

Before consent, only the click id is kept: it holds nothing about the person and is needed to credit an order.
Cookies: `dropp_vid` (visitor id, 13 months) and `dropp_click_id` (30 days), first-party.

## How it behaves

- **Sessions** end after 30 minutes idle, or when the visitor lands from a new campaign.
- **Engaged time** is time the page was visible, sent when the visitor moves on or hides the tab.
- **Queue:** items wait in localStorage (up to 200; page views and time go first when full), are sent 2 s after
  the last one (at once from 20), and on hide with `keepalive`. Failures retry with backoff (2 s doubling, up to
  5 min, `Retry-After` honoured). The server de-duplicates retries.
- **Stops** on `401` / `403` (wrong key, or a site not in the app's domains) and logs why. Automated browsers
  (`navigator.webdriver`) send nothing.
- **Safari** keeps script storage for 7 days. Send `visitorId` with orders and, once customers log in, their
  credit sits on their user, not the browser.

## Develop

```bash
npm install
npm test          # Vitest: the script in jsdom, the server half against ../contract
npm run typecheck
npm run lint
npm run build     # dist/: ESM, CommonJS, types and dropplink.min.js
../scripts/sync-web-script.sh   # on release: copy the script into dropp-attribution's assets/
```

Spec: [docs/sdk-spec.md](../docs/sdk-spec.md) section 12. Wire contract: dropp-attribution `docs/web-api.md`.

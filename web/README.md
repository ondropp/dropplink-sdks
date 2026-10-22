# Dropplink for websites

`@ondropp/dropplink-web` shows a brand which creator's link brought each website visitor and what they did
next: pages, the funnel (product → cart → checkout → order), where they dropped off, and time on page.
About 4.5 KB gzipped, no dependencies.

Orders and revenue are **not** sent from the browser. Your server sends them, with the visitor id this
script puts in a cookie, so creator payouts never depend on data anyone can fake from a browser console.

Full behaviour: [docs/sdk-spec.md §12](../docs/sdk-spec.md#12-web).

## 1. Add your website to the app

In the Dropplink dashboard, open the app, add your website's hosts (`brand.com`, `shop.brand.com`) under
**Website**, and copy the **web key** (`pk_…`). Batches from any other website are refused.

## 2. Add the script

On every page, as high in `<head>` as you can. Use your own link domain (the one your links use):

```html
<script>!function(w){var d=w.dropplink=w.dropplink||{q:[]};["track","identify","logout","grant","revoke"]
.forEach(function(m){d[m]=d[m]||function(){d.q.push([m].concat([].slice.call(arguments)))}})}(window)</script>
<script src="https://go.brand.com/_d/s.js" data-key="pk_…" defer></script>
```

The first line lets you call `dropplink.track(…)` before the script has loaded. Page views, including
route changes in single-page apps, are recorded automatically.

Or from npm:

```ts
import { init } from "@ondropp/dropplink-web";

export const dropplink = init({ key: "pk_…", endpoint: "https://go.brand.com/_d/e" });
```

## 3. Track the funnel

```js
dropplink.track("view_item", { sku: "RS-9", price: 1499 });
dropplink.track("add_to_cart", { sku: "RS-9", price: 1499 });
dropplink.track("begin_checkout");
dropplink.track("sign_up");
```

These names build the funnel in the dashboard. Your own names (`snake_case`) work too and show up as events.
Props: up to 20, strings/numbers/booleans; values that look like an email or a phone number are dropped.

After login, link the visitor to your user id (never an email or phone number):

```js
dropplink.identify("user_8812");
dropplink.logout(); // on sign-out
```

## 4. Send orders from your server

At checkout, read the `dropp_vid` cookie (or `dropplink.getVisitorId()` in the page) and keep it with the
order. When the order is paid, send it from your backend with the app's **server key**:

```bash
curl https://attribution.ondropp.app/v1/s2s/events \
  -H "Authorization: Bearer sk_…" -H "Content-Type: application/json" \
  -d '{"events":[{"eventId":"order-W5521","visitorId":"<dropp_vid>","userId":"user_8812",
       "name":"purchase","ts":1760700300,"revenue":{"amount":1499,"currency":"INR","orderId":"W5521"}}]}'
```

The order is credited to the creator whose link first brought this visitor (within 30 days). With a
`userId`, that creator also keeps the customer's later orders, from any device. Refunds: the same call
with a negative amount.

**Shopify:** store the ids on the cart as soon as the visitor lands, so they reach the order even if
Safari has cleared the cookie by then:

```js
fetch("/cart/update.js", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ attributes: { dropp_vid: dropplink.getVisitorId(), dropp_click_id: dropplink.getClickId() } }),
});
```

## Options

| Attribute | |
| --- | --- |
| `data-consent="required"` | Nothing but the click id is stored or sent until you call `dropplink.grant()`. `dropplink.revoke()` stops and deletes everything. |
| `data-cookie-domain=".brand.com"` | Cookies for every subdomain (e.g. the checkout on `pay.brand.com`). |
| `data-spa="false"` | No automatic page views on route changes. |
| `data-debug="true"` | Logs what it does to the console. |

## Checking it works

Open your site from one of your links with `data-debug="true"`. The console shows
`[Dropplink] sent 2: 2 stored`. In the dashboard, the visitor appears under the link's creator.

## Development

```sh
npm ci
npm test          # vitest + jsdom
npm run typecheck
npm run build     # dist/dropplink.js (script tag) and dist/index.js (npm)
npm run size
```

After a change, `../scripts/sync-web-script.sh <path to dropp-attribution>` copies the script-tag build
into the server, which serves it at `/_d/s.js`.

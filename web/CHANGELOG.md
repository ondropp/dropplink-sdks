# Changelog

All notable changes to `@ondropp/dropplink-web`. The version is shared with the Android, iOS, Flutter and
React Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## 0.2.1 - Unreleased

No web changes. Released to keep the version shared with the other SDKs.

## 0.2.0 - 2026-10-23

- Global Privacy Control: new option `respectGlobalPrivacyControl` (script tag:
  `data-respect-global-privacy-control`), default `true`. When the browser sends GPC, the script clears what it
  stored before, stores and sends nothing, and `grant()` doesn't override it.
- With `consent: 'required'`, nothing is stored before `grant()`: the landing's click id (was saved at once as
  `dl_click` and the `dropp_click_id` cookie) and the user id passed to `identify` (was `dl_uid`) stay in
  memory. `grant()` persists the click with its original 30-day window; `revoke()` forgets it. The default
  `consent: 'granted'` mode is unchanged.

First release: website behaviour and website orders (docs/sdk-spec.md section 12; wire contract:
dropp-attribution `docs/web-api.md`).

- Script tag (`dist/dropplink.min.js`, served as `/_d/s.js` on link domains) and `init(config)` for bundlers:
  page views including single-page navigations, engaged time, sessions (30 minutes idle), the landing's UTM tags,
  referrer and first Dropplink click (first touch), `track`, `identify` (unverified), `logout`, `grant` /
  `revoke` for consent, `getVisitorId`, `getClickId`, `flush`. A localStorage queue with backoff, `keepalive` on
  hide, fallback to the API host. Configured by `data-*` attributes or `window.DropplinkConfig`; calls made
  before load are replayed from `dropplink.q`.
- Server (`@ondropp/dropplink-web/server`): `DropplinkServer.track()` with `visitorId` or `clickId`, batching,
  retries and `DropplinkError`; `deleteUser()`, `getDeletion()`, `readVisitorId()`, `readClickId()`.

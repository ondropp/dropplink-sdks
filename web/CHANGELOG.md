# Changelog

All notable changes to `@ondropp/dropplink-web`. The version is shared with the Android, iOS, Flutter and
React Native SDKs ([docs/sdk-spec.md](../docs/sdk-spec.md)).

## Unreleased

## 0.2.0 - 2026-10-22

First release (docs/sdk-spec.md §12).

- A script tag served by the app's link domain (`/_d/s.js`), and an npm build with `init(config)`.
- Visitor id and first-touch click id in localStorage and the `dropp_vid` / `dropp_click_id` cookies, for
  the brand's server to send with orders. `dropp_click_id` is removed from the address bar.
- Sessions (30 minutes idle), automatic page views including SPA route changes, engaged time per page.
- `track(name, props?)`, `identify(userId)`, `logout()`, with the §11 validation and personal-data rules.
- A localStorage queue: batches of up to 50 items, retries with backoff and `Retry-After`, `keepalive`
  sends when the page is hidden, fallback to the API host when the link domain isn't routed.
- Consent mode (`data-consent="required"`, `grant()`, `revoke()`). Off in automated browsers.

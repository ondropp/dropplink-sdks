# Contributing

## Ground rules

1. **Spec first.** A change to public API or behaviour starts in [`docs/sdk-spec.md`](./docs/sdk-spec.md)
   and lands with the code for every affected platform in the same pull request.
2. **Logic lives in the native SDKs.** Flutter and React Native only bridge. If you're writing signing,
   storage or retry code in Dart or TypeScript, it belongs in `android/` and `ios/` instead. The one
   exception is `web/`: a browser has no native layer, so it implements spec §12 itself.
3. **Never crash the host app.** Public calls don't throw and don't block the main thread.
4. **No new dependencies** without a reason written in the pull request. Brands' apps already carry
   plenty, and every dependency is a possible version conflict.
5. **Keep the public surface small.** Kotlin uses `explicitApi()`; Swift keeps internals `internal`;
   wrappers export only what the spec lists.
6. **Tests run against `contract/`.** Don't copy fixtures into a platform folder; read them from the
   repo root so there's one copy.

## When the server contract changes

1. In `dropp-attribution-server`, `npm run fixtures`.
2. Here, `scripts/sync-contract.sh` and commit `contract/`.
3. Run every platform's tests; fix what breaks. Unknown response fields must keep being ignored.

## Adding a platform

Add a folder with its own README, CHANGELOG and tests, a row in the root README, a section in
`docs/sdk-spec.md` §1, and a workflow in `.github/workflows/`. If it can wrap the native SDKs (as
Flutter and React Native do), it should.

## Style

`.editorconfig` covers whitespace. Otherwise follow each platform's standard: Kotlin coding conventions,
Swift API Design Guidelines, Effective Dart, and the React Native library template's ESLint config.
Comment *why*, not *what*.

## Commits and pull requests

One logical change per pull request. Prefix the title with the area: `android:`, `ios:`, `flutter:`,
`react-native:`, `web:`, `spec:`, `contract:`. Update the platform's `CHANGELOG.md` under "Unreleased".

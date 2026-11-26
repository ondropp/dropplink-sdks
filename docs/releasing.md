# Releasing

All five SDKs share one version and are released together, so a brand never has to work out which
Flutter version matches which Android version.

## Versioning

[Semantic versioning](https://semver.org). While the version is `0.x`, a minor bump may break the
public API; from `1.0.0`, only a major bump may.

The version appears in:

| File | Field |
| --- | --- |
| `android/gradle.properties` (or the library's build file) | `VERSION_NAME`, and `Dropplink.VERSION` |
| `ios/Sources/Dropplink/Dropplink.swift`, `Dropplink.podspec`, `ios/Dropplink.podspec` | `version` |
| `flutter/pubspec.yaml`, `flutter/android/build.gradle`, `flutter/ios/dropplink_flutter.podspec` | package version and the native dependency versions |
| `react-native/package.json`, `react-native/android/build.gradle`, `react-native/*.podspec` | package version and the native dependency versions |
| `web/package.json`, `web/src/version.ts` | `version` and `VERSION` (a test checks they match) |
| The dashboard, `dropplink/src/features/sdk/snippets.ts` | `SDK_VERSION` |

## Steps

1. Move each `CHANGELOG.md`'s "Unreleased" section under the new version.
2. Bump every file above. The wrappers' native dependency must equal the new native version.
3. Merge to `main` with all five CI workflows green.
4. Tag `v<version>` (the tag is also what Swift Package Manager resolves).
5. Publish, native first, because the wrappers depend on them:
   1. Android → Maven Central: `cd android && ./gradlew :dropplink:publish` (signing keys and Sonatype
      credentials from CI secrets), then release the staging repository.
   2. iOS → CocoaPods trunk, from the repository root: `pod trunk push Dropplink.podspec --allow-warnings`.
      SPM needs only the tag: it reads the root `Package.swift`, which points at `ios/Sources/Dropplink`.
      Both root files exist because SwiftPM and trunk resolve from the root; `ios/` keeps its own for
      tests and `:path =>` installs.
   3. Flutter → pub.dev: `cd flutter && dart pub publish`.
   4. React Native → npm: `cd react-native && npm publish --access public`.
   5. Web → npm: `cd web && npm publish --access public`. Then `scripts/sync-web-script.sh` copies the
      script-tag build into dropp-attribution's `assets/`; deploying the server ships it as `/_d/s.js` on every
      link domain.
6. Update `SDK_VERSION` in the dashboard so the SDK setup page shows the new version.

## Credentials (CI secrets, never in the repo)

| Secret | For |
| --- | --- |
| `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`, `SIGNING_KEY`, `SIGNING_PASSWORD` | Android |
| `COCOAPODS_TRUNK_TOKEN` | iOS |
| pub.dev publisher (Google account, `ondropp.app` verified publisher) | Flutter |
| `NPM_TOKEN` (`@ondropp` org) | React Native, Web |

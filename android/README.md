# Dropplink Android SDK

Install attribution and deep links for apps promoted with Dropp links:

- Attributes each install to the Dropp link that drove it (Play Install Referrer, with fingerprint fallback
  on the server).
- Delivers the **deferred deep link** after a fresh install, so the first launch opens the right screen.
- Resolves **App Link** opens of Dropp links into the same deep link format.
- Records **in-app events** and links your **users** to the install, so the funnel after an install is
  credited to the creator who drove it.

minSdk 21, Kotlin and Java friendly. The only dependency is Google's Play Install Referrer library.
Behaviour is specified in [docs/sdk-spec.md](../docs/sdk-spec.md), shared with the iOS, Flutter and React
Native SDKs.

- [Setup in 4 steps](#setup-in-4-steps)
- [Events, revenue and users](#events-revenue-and-users)
- [API](#api)
- [Test your integration](#test-your-integration)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [Developing the SDK](#developing-the-sdk)

## Setup in 4 steps

### 1. Add the dependency

```kotlin
// app/build.gradle.kts (mavenCentral() must be in your repositories)
dependencies {
    implementation("app.ondropp:dropplink-android:0.2.0")
}
```

The SDK's manifest adds the `INTERNET` permission. Its consumer ProGuard/R8 rules keep the public API, so
nothing is needed in your `proguard-rules.pro`.

### 2. Put your keys in BuildConfig

Create an **Android** SDK key for your app in the Dropp dashboard. You get a key id (`ak_…`) and a secret.
Use the Android key: an iOS key fails with `platform_mismatch`.

Keep them out of source control. Put them in `local.properties` (already gitignored) or
`~/.gradle/gradle.properties`, and in CI pass them as `-P` / `ORG_GRADLE_PROJECT_…` environment variables:

```properties
# local.properties
dropplink.keyId=ak_3f9c1e2a7b6d4c80
dropplink.secret=…
```

```kotlin
// app/build.gradle.kts
import java.util.Properties

val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun secret(name: String): String =
    (findProperty(name) as String?) ?: localProperties.getProperty(name) ?: ""

android {
    buildFeatures { buildConfig = true }
    defaultConfig {
        buildConfigField("String", "DROPPLINK_KEY_ID", "\"${secret("dropplink.keyId")}\"")
        buildConfigField("String", "DROPPLINK_SECRET", "\"${secret("dropplink.secret")}\"")
    }
}
```

The secret ships inside the app, as every client SDK key does: signing stops casual abuse and replays, not
a determined attacker. Never use it on a server.

### 3. Initialize in `Application.onCreate`

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Dropplink.initialize(
            this,
            DropplinkConfig(
                keyId = BuildConfig.DROPPLINK_KEY_ID,
                secret = BuildConfig.DROPPLINK_SECRET,
                debug = BuildConfig.DEBUG, // logs under the "Dropplink" tag; never true in release
            ),
        )
        Dropplink.setDeepLinkListener { link ->
            // Main thread. link.path e.g. "/product/123", link.params {variant=red}
            router.open(link.path, link.params)
        }
    }
}
```

Java:

```java
Dropplink.initialize(this, new DropplinkConfig(BuildConfig.DROPPLINK_KEY_ID, BuildConfig.DROPPLINK_SECRET));
Dropplink.setDeepLinkListener(link -> router.open(link.getPath(), link.getParams()));
```

Both calls return immediately; `/v1/init` runs on a background thread. Register the `Application` class in
your manifest (`android:name=".MyApp"`). The listener receives both kinds of link. If a link arrives before a
listener is set, the latest one is held in memory and delivered when you set it, so it's fine to set the
listener later, once your router exists.

### 4. Forward App Links

When the app is already installed, tapping a Dropp link opens the app directly. Forward that URL to the SDK
so it can resolve the link's deep link path and record the open.

1. In the Dropp dashboard, register your link domain (e.g. `go.brand.com`) and your app's **SHA-256 signing
   certificates** (Play Console → App integrity → App signing key certificate, plus your debug/upload keys
   for testing). Dropp serves `/.well-known/assetlinks.json` for the domain from them.
2. Add an intent filter to your launcher activity:

   ```xml
   <activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTask">
       <intent-filter android:autoVerify="true">
           <action android:name="android.intent.action.VIEW" />
           <category android:name="android.intent.category.DEFAULT" />
           <category android:name="android.intent.category.BROWSABLE" />
           <data android:scheme="https" />
           <data android:host="go.brand.com" />
           <!-- One path segment only, so custom-redirect links (/w/<code>) open in the browser. -->
           <data android:pathAdvancedPattern="/[a-z0-9_-]+" />
       </intent-filter>
   </activity>
   ```

   Android 11 and older ignore `pathAdvancedPattern` and open the app for `/w/` links too; the SDK then
   sends the user on to the link's custom URL in the browser.

3. Forward the URL from `onCreate` (cold start) and `onNewIntent` (app already running):

   ```kotlin
   override fun onCreate(savedInstanceState: Bundle?) {
       super.onCreate(savedInstanceState)
       intent?.data?.let { Dropplink.handleDeepLink(it) }
   }

   override fun onNewIntent(intent: Intent) {
       super.onNewIntent(intent)
       setIntent(intent)
       intent.data?.let { Dropplink.handleDeepLink(it) }
   }
   ```

`handleDeepLink` ignores URLs that aren't `http(s)` and links that aren't Dropp links for your app (the
listener isn't called), so you can forward every URL your app receives. Links reported before init finishes
are sent right after it.

The [`sample/`](sample) app shows all four steps.

## Events, revenue and users

```kotlin
// Funnel events: snake_case names, up to 20 non-personal props (strings, numbers, booleans, null).
Dropplink.track("add_to_cart", mapOf("sku" to "TSHIRT-M", "qty" to 1))
Dropplink.track("purchase", revenue = Revenue(499.0, "INR", orderId = "A1023"))

// After sign-up / login: your own opaque user id. Email and phone are optional and hashed on the device.
Dropplink.identify(user.id, email = user.email, phone = user.phoneE164)

// On logout. Events after it carry no user.
Dropplink.logout()

// Consent: false clears anything waiting and stops events and identify, across launches, until set to
// true. Install attribution and deep links keep working.
Dropplink.setTrackingEnabled(userAccepted)
```

Java: `Dropplink.track("add_to_cart")`, `Dropplink.track("purchase", null, new Revenue(499.0, "INR"))`,
`Dropplink.identify(userId)`.

- Each call is checked, written to a queue file and returns; the SDK sends the queue in the background
  (1 s after the last call, when the app goes to the background, and after each launch's init), in
  batches, retrying until the server has it. Every event gets its id and timestamp when you call `track`,
  so retries never double-count.
- Invalid events are dropped with the reason logged in debug mode (`event "Add To Cart" dropped: name must
  be snake_case`). Props that look like an email or phone number are dropped. Use ids, not personal data.
- `identify` with the same user id as last time does nothing, so it's fine to call on every launch.
- The queue holds up to 1,000 events (1 MB); when full, the oldest events without revenue go first. Events
  older than 7 days are dropped.

**Revenue from the app is shown as app-reported.** A client can be modified, so purchases that pay
creators must be sent from your server with `POST /v1/s2s/events` (see the server's API docs). Use `track`
for the funnel (views, add to cart, checkout started) and, if you like, the app-side view of a purchase.

## API

Package `app.ondropp.dropplink`:

```kotlin
object Dropplink {
    const val VERSION = "0.2.0"
    @JvmStatic fun initialize(context: Context, config: DropplinkConfig)
    @JvmStatic fun setDeepLinkListener(listener: DeepLinkListener?)
    @JvmStatic fun handleDeepLink(uri: Uri)
    @JvmStatic fun handleDeepLink(url: String)
    @JvmStatic fun getAttribution(): Attribution?   // null before the first successful init
    @JvmStatic fun getInstallId(): String?          // null before initialize
    @JvmStatic @JvmOverloads fun track(name: String, props: Map<String, Any?>? = null, revenue: Revenue? = null)
    @JvmStatic @JvmOverloads fun identify(userId: String, email: String? = null, phone: String? = null)
    @JvmStatic fun logout()
    @JvmStatic fun setTrackingEnabled(enabled: Boolean)
    @JvmStatic fun isTrackingEnabled(): Boolean
}

data class Revenue @JvmOverloads constructor(val amount: Double, val currency: String, val orderId: String? = null)

data class DropplinkConfig @JvmOverloads constructor(
    val keyId: String,
    val secret: String,
    val debug: Boolean = false,
    val baseUrl: String = "https://attribution.ondropp.app",
    val platformWrapper: String? = null,            // set only by the Flutter / React Native packages
)

fun interface DeepLinkListener { fun onDeepLink(link: DeepLink) }

data class DeepLink(
    val path: String,                               // "/product/123"
    val params: Map<String, String>,
    val url: String?,                               // the opened URL; null for the deferred link
    val isDeferred: Boolean,                        // true only for the link delivered after a fresh install
) { fun toMap(): Map<String, Any?> }

data class Attribution(
    val type: String,                               // "attributed" | "organic"
    val method: String,                             // "install_referrer" | "fingerprint" | "none"
    val clickId: String?, val linkId: String?, val campaignId: String?, val creatorId: String?,
    val source: String?, val confidence: Double?, val attributedAt: String?,
) { fun toMap(): Map<String, Any?> }
```

All calls are thread-safe and never block on the network. None throws, except `initialize` with an invalid
config in a debuggable build (so the mistake shows up during development; release builds log and disable
the SDK instead). `getAttribution()` is cached on disk, so it's available immediately on later launches.
`track`, `identify`, `logout` and `setTrackingEnabled` calls made before `initialize` are held and applied
once it runs.

## Test your integration

1. Set `debug = true` and run the app. Watch Logcat filtered by tag `Dropplink`:

   ```
   Dropplink: install id 6f1c2a9e-… (paste into Dropplink → Install debugger)
   Dropplink: init 200 attributed via install_referrer, link 6711a0…, deep link /product/123
   ```

2. Paste the install id into **Dropp dashboard → Install debugger** to see the device's inits, its
   attribution and the click it matched.
3. Deferred deep link: uninstall the app, tap a Dropp link on the device, then install and launch. With a
   Play Store install the Install Referrer carries the click (`method = install_referrer`); a sideloaded or
   Android Studio install has no referrer and falls back to fingerprint matching on the same network. The
   listener receives the link with `isDeferred == true`.
4. App Link: with the app installed, tap a Dropp link in a chat or notes app. The listener receives it with
   `isDeferred == false`. Check verification with
   `adb shell pm get-app-links <your.package>` (Android 12+) — the domain should show `verified`.

Pointing at a local server from the emulator: `baseUrl = "http://10.0.2.2:4100"` (debug builds only; cleartext
HTTP needs a network security config).

## Troubleshooting

With `debug = true`, failures are logged under the `Dropplink` tag with the server's error code:

| Log | Cause | Fix |
| --- | --- | --- |
| `Invalid DropplinkConfig: … Dropplink is disabled.` | Empty `keyId` / `secret`, `keyId` not starting with `ak_`, or a bad `baseUrl`. Logged even without `debug`; throws in debuggable builds. | Check the BuildConfig fields are filled (an empty string means the property wasn't found). |
| `401 invalid_key` | The key is unknown or revoked, or its app was deleted. SDK stops until next launch. | Copy the key again from the dashboard. |
| `400 platform_mismatch` | An iOS key in an Android app. | Use the app's **Android** key. |
| `401 bad_signature` | Wrong secret for this key id. | Copy the secret again; check for trailing spaces. |
| `401 stale_timestamp. Device clock looks wrong` | The device clock is more than 5 minutes off. Retried with backoff. | Set the device to automatic time. |
| `400 validation_failed … details=…` | The server rejected the body. | Likely an SDK bug: report it with the log line. |
| `network error` / `5xx` / `429` … `retrying` | Retried 3 times (1 s, 2 s, 4 s ± 20%), then again on next launch. | Nothing; check connectivity or `baseUrl`. |
| `Install Referrer not available` / `timed out` | No Play Store on the device, or a sideloaded install. Init is still sent; the server falls back to fingerprint. | Expected on emulators without Play and for `adb install`. |
| `deeplink: not a Dropplink link` | `handleDeepLink` got a URL that isn't one of your app's links. | Expected for other URLs. |
| `deeplink: no path for this link` | The link was opened but has no deep link path set. | Set a deep link path on the link in the dashboard. |
| `event "…" dropped: …` / `prop … dropped` | The event broke a rule (name, props, revenue); see the reason. | Fix the call. |
| `identify dropped: userId looks like an email or phone number` | `identify` was given personal data as the id. | Pass your own opaque user id. |
| `events: 503 …; retrying in …` | The queue is kept and retried with backoff (1 s up to 5 min). | Nothing. |
| `events: 401 …` `paused until the next launch` | Key or signature problem; events stay queued. | Fix the key; they're sent on the next launch. |

No link delivered? Check the listener is set (it runs on the main thread), that the intent filter's host
matches your link domain, that `onNewIntent` forwards to the SDK for `singleTask` / `singleTop` activities,
and that `assetlinks.json` lists your signing certificate.

## Privacy

The SDK sends only: a random install id (created by the SDK, not an advertising or Android id), app and SDK
version, device model, OS version, locale, time zone, screen size and, until attributed, the Play Install
Referrer. No advertising id, no contacts, no location. With events, it also sends what you pass to
`track` and `identify`; emails and phone numbers given to `identify` are SHA-256 hashed on the device and
never stored or sent in plain text.

It stores the install id, last attribution and the tracking setting in `dropplink.json`, and unsent events
in `dropplink-queue.json`, both in `Context.noBackupFilesDir`. That folder
is never included in Auto Backup, so a restored phone gets a new install id and you don't need to edit your
backup rules. The secret is never stored by the SDK.

Permissions: `INTERNET`, plus `BIND_GET_INSTALL_REFERRER_SERVICE` from the Play Install Referrer library. No
`AD_ID`.

Full list of what is sent and stored, and retention: [docs/privacy.md](../docs/privacy.md). Play Data safety
answers per feature: [docs/store-disclosures.md](../docs/store-disclosures.md). Consent (EU / UK, children):
[docs/consent.md](../docs/consent.md).

## Developing the SDK

```sh
cd android
./gradlew :dropplink:testDebugUnitTest        # plain JVM tests; fixtures read from ../contract
./gradlew :dropplink:lint :sample:assembleDebug
./gradlew :dropplink:publishReleasePublicationToStagingRepository   # Maven layout in dropplink/build/staging-repo
```

`local.properties` needs `sdk.dir=/path/to/Android/sdk` (Android Studio writes it). The sample app reads
`dropplink.keyId`, `dropplink.secret` and optionally `dropplink.baseUrl` from the same file.

Tests reproduce every signing vector in `contract/hmac/vectors.json`, check the init body against
`contract/init/request.android.json` and the events / identify bodies against `contract/events` and
`contract/identify`, parse every response fixture, and cover the retry rules, the event queue, storage and
deep link delivery with a fake HTTP client, environment and executors. Android types are kept out of the core logic, so
there's no Robolectric.

Publishing to Maven Central: set `signingKey` (ASCII-armored private key) and `signingPassword` as Gradle
properties or `ORG_GRADLE_PROJECT_signingKey` / `ORG_GRADLE_PROJECT_signingPassword`, run the staging
publish above, zip `dropplink/build/staging-repo` and upload it to the Central Portal. Without the key,
artifacts are built unsigned. Bump `version` in `dropplink/build.gradle.kts` together with `Dropplink.VERSION`.

Layout of `dropplink/src/main/kotlin/app/ondropp/dropplink/`:

| File | |
| --- | --- |
| `Dropplink.kt`, `DropplinkConfig.kt`, `DeepLink.kt`, `Attribution.kt`, `Revenue.kt` | Public API |
| `internal/DropplinkCore.kt` | Lifecycle, init / deeplink requests, retries, state, queue flushes |
| `internal/EventQueue.kt`, `internal/EventValidation.kt`, `internal/Scheduler.kt` | Event queue file, caps and batches; `track` / `identify` checks and PII rules; timers |
| `internal/Signer.kt`, `internal/HttpClient.kt`, `internal/RetryPolicy.kt` | Signed requests over `HttpURLConnection` |
| `internal/InitBody.kt`, `internal/Responses.kt`, `internal/Json.kt` | `/v1/init` body and response parsing |
| `internal/Environment.kt`, `internal/AndroidEnvironment.kt`, `internal/InstallReferrerReader.kt` | Device details and Install Referrer (the only Android-specific code) |
| `internal/Storage.kt`, `internal/DeepLinkDispatcher.kt`, `internal/Logger.kt`, `internal/ConfigValidation.kt` | Persistence, listener delivery, logging, config checks |

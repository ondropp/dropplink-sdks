# Consent recipes

_How to wire the Dropplink SDKs to your consent flow. What each SDK collects is in [privacy.md](./privacy.md).
Which law applies to which user, and which consent category Dropplink belongs in, is for you and your counsel
to decide; these recipes show the mechanics._

- [EU / UK websites](#eu--uk-websites)
  - [Google Consent Mode v2](#google-consent-mode-v2)
  - [OneTrust](#onetrust)
  - [Cookiebot](#cookiebot)
- [EU / UK apps](#eu--uk-apps)
- [US: Global Privacy Control](#us-global-privacy-control)
- [Apps for children](#apps-for-children)

## EU / UK websites

The ePrivacy Directive (Art. 5(3)) and the UK's PECR require consent before storing or reading anything on a
visitor's device unless it's strictly necessary for a service they asked for. Measuring which link or creator
brought a visitor is generally not treated as strictly necessary. For visitors in the EU / UK, use
`consent: 'required'` and call `grant()` / `revoke()` from your consent banner (CMP):

```html
<script>window.dropplink=window.dropplink||{q:[]};['track','identify','logout','grant','revoke'].forEach(function(m){dropplink[m]=dropplink[m]||function(){dropplink.q.push([m].concat([].slice.call(arguments)))}});</script>
<script src="https://go.yourbrand.com/_d/s.js" data-key="pk_…" data-consent="required" async></script>
```

or `init({ key: 'pk_…', consent: 'required' })` with npm. The first line defines `dropplink.grant()` and
`dropplink.revoke()` before the script loads, so your CMP's callbacks can call them at any time.

Until `grant()` nothing is written to localStorage or cookies and nothing is sent: the session, the user id,
the Dropplink click id the visitor landed with and up to 50 items wait in memory, and are lost if the visitor
leaves without answering. `grant()` stores the click (`dl_click`, `dropp_click_id`, 30 days from the landing)
and sends what waited, so the visit is still credited to the link.

`revoke()` clears every Dropplink key and cookie, forgets what waits in memory, and stops sending. Call it when
the visitor withdraws, not on every page load before they've answered (that would also drop the click id held
for the current page).

Which category: Dropplink measures marketing (which links, creators and campaigns bring visitors and orders).
Many CMP setups put that under **marketing / advertising** rather than **statistics / analytics**. The
examples below use the marketing category; use whatever category your cookie list puts Dropplink in.

### Google Consent Mode v2

If your CMP (or your own code) reports consent with `gtag('consent', …)`, Dropplink can follow the same
signal. This listens for every `gtag('consent', 'default' | 'update', …)` call. Put it **before** your CMP and
Google tag snippets, after the Dropplink stub:

```html
<script>
  (function () {
    // Granted only when both are granted: Dropplink measures marketing, so it follows ad_storage too.
    var state = {};
    function onConsent(args) {
      // gtag() pushes its arguments object: ['consent', 'default' | 'update', { analytics_storage, ad_storage, … }]
      if (!args || args[0] !== 'consent' || typeof args[2] !== 'object') return;
      var was = state.analytics_storage === 'granted' && state.ad_storage === 'granted';
      for (var k in args[2]) state[k] = args[2][k];
      var now = state.analytics_storage === 'granted' && state.ad_storage === 'granted';
      if (now) window.dropplink.grant();
      else if (was || args[1] === 'update') window.dropplink.revoke();
    }
    var dl = (window.dataLayer = window.dataLayer || []);
    for (var i = 0; i < dl.length; i++) onConsent(dl[i]);
    var push = dl.push;
    dl.push = function () {
      for (var j = 0; j < arguments.length; j++) onConsent(arguments[j]);
      return push.apply(dl, arguments);
    };
  })();
</script>
```

Google Tag Manager and gtag.js replace `dataLayer.push` with their own when they load. Check that this still
sees consent updates on your site, with your tags loaded, using `data-debug="true"` (the console shows
`consent granted` / `consent withdrawn`). If your CMP already gives you an "on consent changed" callback, use
that instead, as in the next two examples. Dropplink does not read IAB TCF strings yet.

### OneTrust

OneTrust calls `OptanonWrapper()` when its banner loads and again on every change; `OnetrustActiveGroups`
lists the accepted categories. `C0004` is OneTrust's usual "Targeting Cookies" group; use the group id your
OneTrust cookie list assigns to Dropplink.

```html
<script>
  var DROPPLINK_GROUP = 'C0004';
  function OptanonWrapper() {
    var on = (',' + (window.OnetrustActiveGroups || '') + ',').indexOf(',' + DROPPLINK_GROUP + ',') !== -1;
    if (on) window.dropplink.grant();
    // Only once the visitor has answered, so a first visit doesn't delete the click they landed with.
    else if (window.OneTrust && OneTrust.IsAlertBoxClosed()) window.dropplink.revoke();
  }
</script>
```

`grant()` does nothing when consent is already granted, and `revoke()` on every page of a visitor who declined
just keeps their storage empty.

### Cookiebot

Cookiebot fires `CookiebotOnAccept` and `CookiebotOnDecline` when the visitor answers, and again on each page
load once they have.

```html
<script>
  window.addEventListener('CookiebotOnAccept', function () {
    if (Cookiebot.consent.marketing) window.dropplink.grant();
    else window.dropplink.revoke();
  });
  window.addEventListener('CookiebotOnDecline', function () {
    window.dropplink.revoke();
  });
</script>
```

## EU / UK apps

Mobile has no cookie banner, but the same rule covers reading and storing on a phone. The app SDKs store an
install id and send device details on every launch as soon as `initialize` runs, and
`setTrackingEnabled(false)` deliberately does **not** stop that (it stops events and identify only). So, for
users the law requires consent from:

1. **Call `initialize` only after the user consents**, and on later launches only if they still have.
   Setting the deep link listener before that is fine: links wait in memory. App Links / Universal Links still
   open your app either way; without `initialize` they aren't resolved through Dropplink, so route them
   yourself.
2. **On withdrawal, call `setTrackingEnabled(false)`** (it clears anything waiting and stops events and
   identify at once, persisted), save the choice, and stop calling `initialize` from the next launch.
3. **If they consent again**, call `setTrackingEnabled(true)` and `initialize`.

Keep the server's IP + device matching off for these apps unless consent is collected before `initialize`
(see [privacy.md](./privacy.md#install-matching-by-ip-and-device-fingerprinting)). Your own consent store and
"is this user in the EU / UK" check are yours (your CMP's SDK, the store country, or asking everyone).

**Kotlin**

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Dropplink.setDeepLinkListener { link -> router.open(link.path, link.params) }
        if (!consent.isRequired() || consent.hasGranted()) startDropplink()
    }

    fun startDropplink() {
        Dropplink.setTrackingEnabled(true)
        Dropplink.initialize(this, DropplinkConfig(keyId = BuildConfig.DROPPLINK_KEY_ID, secret = BuildConfig.DROPPLINK_SECRET))
    }
}

// Your consent screen
fun onConsentGiven() { consent.save(true); (application as App).startDropplink() }
fun onConsentWithdrawn() { consent.save(false); Dropplink.setTrackingEnabled(false) }
```

**Swift**

```swift
func startDropplink() {
    Dropplink.setTrackingEnabled(true)
    Dropplink.initialize(config: DropplinkConfig(keyId: keyId, secret: secret))
}

// At launch
if !consent.isRequired || consent.hasGranted { startDropplink() }

// Your consent screen
func consentGiven() { consent.save(true); startDropplink() }
func consentWithdrawn() { consent.save(false); Dropplink.setTrackingEnabled(false) }
```

**Dart (Flutter)**

```dart
Future<void> startDropplink() async {
  await Dropplink.setTrackingEnabled(true);
  await Dropplink.initialize(keyId: keyId, secret: secret);
}

// At launch, in main()
if (!consent.isRequired || consent.hasGranted) await startDropplink();

// Your consent screen
Future<void> consentGiven() async { await consent.save(true); await startDropplink(); }
Future<void> consentWithdrawn() async { await consent.save(false); await Dropplink.setTrackingEnabled(false); }
```

**TypeScript (React Native)**

```ts
async function startDropplink() {
  Dropplink.setTrackingEnabled(true);
  await Dropplink.initialize({ keyId, secret });
}

// At launch, in index.js
if (!consent.isRequired || consent.hasGranted) startDropplink().catch(console.warn);

// Your consent screen
async function consentGiven() { await consent.save(true); await startDropplink(); }
async function consentWithdrawn() { await consent.save(false); Dropplink.setTrackingEnabled(false); }
```

Don't also initialize natively (`MainApplication` / `AppDelegate`) in a Flutter or React Native app that
gates on consent: the native call runs before your consent check.

`setTrackingEnabled` can be called before `initialize`; the choice is kept. The install id is kept when tracking
is turned off; it disappears when the app is uninstalled.

## US: Global Privacy Control

California (CCPA / CPRA) and several other US states recognise **Global Privacy Control** (GPC), a browser
signal (`navigator.globalPrivacyControl`) meaning "don't sell or share my personal information". Dropp acts
as your service provider and doesn't sell or share your visitors' data, but the safer default is to stop
collecting for visitors who send it.

The web script does this by default (`respectGlobalPrivacyControl: true`): when the browser sends GPC, it
stores nothing (and clears anything it stored on an earlier visit), sends nothing, and `getVisitorId()` /
`getClickId()` return `null`. `grant()` doesn't override it: accepting a cookie banner doesn't withdraw the
browser's signal. Orders from these visitors still reach Dropplink through your server, without a visitor or
click to credit.

If your counsel decides GPC doesn't apply to your use of Dropplink, turn it off:

```html
<script src="https://go.yourbrand.com/_d/s.js" data-key="pk_…" data-respect-global-privacy-control="false" async></script>
```

```ts
init({ key: 'pk_…', respectGlobalPrivacyControl: false });
```

Apps have no GPC signal. If your app offers "Do not sell or share my personal information", you can wire it to
`setTrackingEnabled(false)` as above.

## Apps for children

Don't use `identify` or `track` in an app or website directed at children (under 13 in the US under COPPA,
under 16 in parts of the EU, under 18 in India under the DPDP Act), or in the parts of a mixed-audience app
used by children, and keep the server's IP + device matching off for it. Install attribution and deep links
then send only the random install id and the device fields in [privacy.md](./privacy.md). Whether even that
is acceptable for your audience, and what Google Play's Families policy and Apple's Kids category require of
you, is for your counsel. Tell Dropp if an app is directed at children.

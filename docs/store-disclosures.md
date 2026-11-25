# Store disclosures: Google Play Data safety and Apple App Privacy

_For brands filling in the store forms for an app that includes the Dropplink Android, iOS, Flutter or React
Native SDK (0.2.0). What the SDK sends is listed in [privacy.md](./privacy.md)._

These are our recommended answers for **the Dropplink SDK's part** of your app. Your answers must also cover
everything else your app and its other SDKs collect, and you are the one who submits them. Google's and
Apple's definitions leave room for interpretation in places; where they do, we say so and recommend the
answer that discloses more, because over-disclosing is not a reason for rejection and under-disclosing is.
This is not legal advice.

- [Which answers apply to you](#which-answers-apply-to-you)
- [Google Play: Data safety](#google-play-data-safety)
- [Apple: App Privacy ("nutrition labels")](#apple-app-privacy-nutrition-labels)
- [Things that change the answers](#things-that-change-the-answers)

## Which answers apply to you

| You use | Google Play data type | Apple data type |
| --- | --- | --- |
| The SDK at all (`initialize`: install attribution, deep links) | Device or other IDs; App interactions | Identifiers → Device ID; Usage Data → Product Interaction |
| `track(...)` | App interactions | Usage Data → Product Interaction |
| `track(..., revenue)` | Purchase history | Purchases → Purchase History |
| `identify(userId)` | User IDs | Identifiers → User ID |
| `identify(..., email)` | Email address | Contact Info → Email Address |
| `identify(..., phone)` | Phone number | Contact Info → Phone Number |
| The SDK at all (our server looks up country, region and city from the request) | Approximate location | Location → Coarse Location |

**Why "App interactions" / "Product Interaction" even without `track`:** every launch sends `/v1/init`, which
tells our server the app was opened, and `handleDeepLink` reports which link opened it. Both stores' examples
of these types include app launches and taps. Declaring them is the safer answer.

**Hashed email and phone still count.** `identify` hashes email and phone with SHA-256 on the device, but a
hash of an email address identifies the same person to anyone who hashes the same address. Both stores treat
it as collecting that data type. Declare Email address / Phone number if you pass them.

**Approximate location counts.** Our server never stores the IP address (only a daily-salted hash), but it
records the country, region and city that the request comes from (Cloudflare's location headers). Both stores
count location derived from an IP address as approximate / coarse location, so declare it.

**Not collected by the SDK, so not declared for it:** precise location (GPS, Wi-Fi, Bluetooth), contacts,
advertising id, crash logs,
diagnostics, photos, health, financial info. Device model, OS version, locale, time zone and screen size are
not a data type of their own in either form; they're covered by the answers above.

## Google Play: Data safety

### Overview questions

| Question | Answer for the Dropplink SDK |
| --- | --- |
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** (HTTPS only; `baseUrl` with `http://` is for local testing and must never ship) |
| Do you provide a way for users to request that their data is deleted? | **Yes**, if you offer a deletion request (account deletion or a support contact) and pass it on with `deleteUser(userId)` or to Dropplink support. See [privacy.md → Deletion](./privacy.md#deletion). |

### Per data type

For every type below: **Collected: yes. Shared: no.** Dropplink receives the data as your service provider, which
Google's definition excludes from "sharing". (If *you* send this data on to someone else, such as an ad
network or your creators, that is sharing and you must declare it.) **Processed ephemerally: no.**

| Data type (Play category) | Declare when | Required or optional | Purposes |
| --- | --- | --- | --- |
| **Device or other IDs** (Device or other IDs) | Always | Required, unless you only call `initialize` after the user opts in | Analytics; App functionality (deep links); Advertising or marketing (see below) |
| **App interactions** (App activity) | Always (see above) | Required for launches; for events, optional only if users can turn them off through `setTrackingEnabled(false)` | Analytics; Advertising or marketing |
| **Purchase history** (Financial info) | You pass `revenue` to `track` | As for events | Analytics; Advertising or marketing |
| **User IDs** (Personal info) | You call `identify` | As for events | Analytics; Advertising or marketing |
| **Email address** (Personal info) | You pass `email` to `identify` | As for events | Analytics; Advertising or marketing |
| **Phone number** (Personal info) | You pass `phone` to `identify` | As for events | Analytics; Advertising or marketing |
| **Approximate location** (Location) | Always (country, region and city from the request) | Required, unless you only call `initialize` after the user opts in | Analytics; Advertising or marketing |

**Advertising or marketing**: Google's definition includes "measure ad performance". Dropplink's purpose is
to measure which links, creators and campaigns bring installs, users and orders, which is measuring marketing
performance. Ticking **Analytics** alone is defensible if you use Dropplink only to understand your own
funnel; ticking **Advertising or marketing** as well is the safer answer, and we recommend it. Dropplink never
shows ads or targets anyone.

**Fraud prevention, security, and compliance**: not needed for the SDK's part, unless you use Dropplink data
for it yourself.

## Apple: App Privacy ("nutrition labels")

The SDK ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares every type it *can* collect, so
Xcode's privacy report for your app lists all of them. In App Store Connect, answer for what your app actually
uses (table at the top).

### Per data type

| Data type | Declare when | Linked to the user? | Used for tracking? | Purposes |
| --- | --- | --- | --- | --- |
| **Identifiers → Device ID** | Always | **Yes** | **No** | Analytics; App Functionality |
| **Usage Data → Product Interaction** | Always (see above) | **Yes** | **No** | Analytics |
| **Purchases → Purchase History** | You pass `revenue` | **Yes** | **No** | Analytics |
| **Identifiers → User ID** | You call `identify` | **Yes** | **No** | Analytics |
| **Contact Info → Email Address** | You pass `email` | **Yes** | **No** | Analytics |
| **Contact Info → Phone Number** | You pass `phone` | **Yes** | **No** | Analytics |
| **Location → Coarse Location** | Always (country, region and city from the request) | **Yes** | **No** | Analytics |

**Linked to the user: yes.** The install id is a stable per-install identifier and `identify` ties it to your
user id, so everything sent with it can be connected to the person. Apple counts data as linked unless it is
de-identified before collection; hashing an email or phone does not de-identify it. Answer "No" only for an
app that never calls `identify` *and* if your counsel is comfortable that a random install id alone isn't
linked to an identity; we recommend "Yes".

**Used for tracking: no**, on these conditions:

1. **The server's IP + device matching (fingerprinting) is off for your iOS app.** Apple forbids
   fingerprinting whatever the user answers to App Tracking Transparency, and attributing an install to a
   click made in a browser or another app by matching IP and device details is the kind of linking Apple
   describes. It is a server setting, not in the SDK. Confirm it with Dropplink before you submit. See
   [privacy.md](./privacy.md#install-matching-by-ip-and-device-fingerprinting).
2. You don't send Dropplink data (install id, user id, email / phone hashes) to ad networks or data brokers,
   or combine it with data from other companies' apps and websites for advertising.

If either isn't true, the honest answer is **Yes**, which needs App Tracking Transparency and contradicts the
SDK's manifest (`NSPrivacyTracking = false`). Dropplink doesn't support that setup on iOS.

**Purposes.** Apple's "Developer's Advertising or Marketing" covers showing first-party ads and sending
marketing; measuring which campaign brought a user is closest to its "Analytics" ("measure audience size or
characteristics", "effectiveness of existing product features"). We declare Analytics (and App Functionality
for the install id, which delivers deep links). If your counsel reads campaign attribution as advertising,
adding "Developer's Advertising or Marketing" is harmless over-disclosure. Never "Third-Party Advertising".

## Things that change the answers

| Situation | Change |
| --- | --- |
| You call `setTrackingEnabled(false)` for users who decline | Events, purchases, user id, email and phone become **optional** on Play. Device ID and app launches are still collected (they come from `initialize`). Apple has no optional/required distinction. |
| You only call `initialize` after the user opts in (e.g. EU / UK, see [consent.md](./consent.md)) | On Play every type may be marked **optional**, if every user gets the choice. |
| Fingerprinting on for your Android app | No new data type (the server uses the IP and the device fields already declared). Keep **Advertising or marketing** ticked. |
| Fingerprinting on for your iOS app | Not compatible with Apple's rules. Turn it off. |
| Your server sends phone numbers or other data to Dropplink (server-side events, messaging contacts) | Both forms ask about data collected **from the app**. If your app collected it, you already declare it for your own use; Dropplink receiving it as your service provider doesn't make it "shared". Data your app never collected isn't part of these forms. |
| An app directed at children | Don't use `identify` or `track`; keep fingerprinting off. See [consent.md](./consent.md#apps-for-children). |
| Flutter / React Native | Same answers: they use the native SDKs. |

# atproto deployment

Each project gets its own (sub)domain:

| Project | Domain | Source | Hosted by |
| --- | --- | --- | --- |
| Hummingbird (the app) | `hummingbird.eightybps.com` | `Web/hummingbird/` | GitHub Pages, [80bps/hummingbird.eightybps.com](https://github.com/80bps/hummingbird.eightybps.com) |
| AppSync (the reusable sync protocol) | `appsync.eightybps.com` | that repository | GitHub Pages, [80bps/appsync.eightybps.com](https://github.com/80bps/appsync.eightybps.com) |
| 80bps in general | `eightybps.com` | nothing yet | nothing yet |

Each site is a `CNAME` DNS record for its subdomain pointing at
`80bps.github.io`. Copy changes to `Web/hummingbird/` into its Pages
repository; the copy here is the one the tests check.

## Hummingbird: App Store

| | |
| --- | --- |
| App Store Connect app | [Apple ID 6829103662](https://appstoreconnect.apple.com/apps/6829103662/distribution/macos/version/inflight) |
| SKU | `APPL_HUMMINGBIRD` |
| Bundle ID | `com.eightybps.hummingbird` (all platforms; `project.yml`, `xtool.yml`) |
| Team | `NMM6M6QVAT` |
| Keychain access group | `$(AppIdentifierPrefix)com.eightybps.hummingbird.shared` |

The Linux app uses the same reverse-DNS ID (`Apps/Linux/Info.json`, the
desktop entry). Not to be confused with AppSync's app ID and the lexicon
namespaces under `com.eightybps.hummingbird`, which are protocol names, not
bundle IDs, and must not change with it.

### Export compliance

`ITSAppUsesNonExemptEncryption` is `false`. Hummingbird encrypts data
(AppSync's device-to-device inbox: P-256 key agreement and AES-GCM; plugin
credential pairing: AES-GCM and HMAC-SHA256), verifies RSA plugin signatures
and uses HTTPS. But on Apple platforms every one of those is a standard
algorithm run by Apple's own frameworks: CryptoKit (swift-crypto's `Crypto`
re-exports it there), Security, and URLSession's TLS. The encryption only
protects the user's own data between their own devices, ancillary to a media
app. So neither documentation trigger applies (no proprietary or
non-standard algorithms, and no standard algorithms instead of or in addition
to the OS's). In App Store Connect, answer that the app uses no encryption
outside Apple's operating system.

`EncryptionExportTests` checks the declaration, that `Crypto` is CryptoKit,
and that no BoringSSL or libsodium code is linked into the Apple build. Those
are only used on Linux. If it fails, revisit this and the App Store Connect
answers. This is a reading of Apple's form, not legal advice; reconsider it
if Hummingbird's main purpose ever becomes security or communications.

### Age rating and App Review notes

Age rating questionnaire: **Unrestricted Web Access: No.** The address bar
opens links only through installed sources, and sign-in pages are confined
to their source's domains (`Documentation/AgeAndParentalControls.md`).

Paste into App Review notes (guideline 4.7 / 4.7.5):

> Hummingbird plays media from sources the user installs (plugins). Some
> sources, such as general video platforms, can show content above the
> app's age rating. Hummingbird restricts them by age:
>
> - Before a source is installed, and each time one starts, the app asks the
>   Declared Age Range API for the user's age range (gates 13, 16 and 18).
>   The profile remembers only the highest age any of its devices has
>   confirmed (as a bound on the birthday, never a birth date), so a device
>   without an age signal cannot undo it. Age signals only raise it; anyone
>   may lower it, which only restricts.
> - Sources are rated. Unreviewed sources, and general video platforms, are
>   18+. A source rated above the shared age range cannot be installed or
>   run, and is hidden from the source catalog. If the user declines to share
>   their age, sources rated above "all ages" cannot be installed.
> - Below 18, each source's own restricted mode (for example YouTube's
>   age-restricted videos) is forced on and cannot be changed.
> - Parental controls are the system's (Screen Time / Family Sharing); the
>   app has no passcode of its own. When Declared Age Range reports active
>   parental controls, sources rated above the user's age, and unreviewed
>   sources, need a parent's approval: "Ask a Parent" sends a PermissionKit
>   request, and the source installs only once the parent approves.
>   Restricted modes stay on under parental controls.
> - Sign-in pages stay on the source's own domains; the app has no general
>   web browser.
>
> When neither the device nor any other device of the profile has provided
> an age range (operating systems before iOS/macOS 26, or regions where the
> API is unavailable) and the system reports no parental controls, the app
> treats the user as an adult; the system's parental controls are the way
> to restrict such devices.
>
> To try it: on a child account in a Family Sharing group, add a source by
> URL (Sources ▸ +): an unreviewed source is refused with "Ask a Parent";
> the request appears on the parent's device, and the source installs once
> approved.

The paragraph on devices without an age range is the 4.7.5 exposure: an age
restriction mechanism "based on verified or declared age" is only as strong
as the platform's signal, and with no signal the app does not restrict
(product decision, 2026-11-16). If App Review rejects that, the remedy is to
treat "unavailable" like "declined" in `AgeEvidence.isAtLeast` (one place),
not to store an age in the app.

## Hummingbird: OAuth client

Serve `Web/hummingbird/` as the site root of `hummingbird.eightybps.com`, so
the client metadata is at exactly:

`https://hummingbird.eightybps.com/oauth-client-metadata.json`

Use an `application/json` content type, HTTPS, and no redirect to a different
origin. The URL is the OAuth public client identifier, so changing it later is
an OAuth client migration rather than a transparent DNS change. Existing local
sessions can continue until they require reauthorization.

The host is fixed by the redirect URI: a native client's custom URI scheme must
be its client ID's hostname in reverse-domain order, so
`com.eightybps.hummingbird:/oauth/callback` requires a client ID on
`hummingbird.eightybps.com`. `OAuthClientMetadataTests` checks this, and that
the app's `ProfileAccountService.configuration` matches the published file.

## Lexicon authorities

An NSID's authority is its domain part reversed, without the final name
segment, and is found through a `_lexicon` TXT record there. So the two
namespaces resolve separately:

| Namespace | Lexicons | TXT record |
| --- | --- | --- |
| `com.eightybps.appsync.*` | `Lexicons/com/eightybps/appsync` | `_lexicon.appsync.eightybps.com` |
| `com.eightybps.hummingbird.*` | `Lexicons/com/eightybps/hummingbird` | `_lexicon.hummingbird.eightybps.com` |

Each namespace has its own authority DID, so that neither can publish, alter
or revoke the other's schemas, and a key compromise or transfer of one doesn't
touch the other. In particular, AppSync is a reusable protocol and must not
depend on any one app's identity:

| Namespace | Authority DID |
| --- | --- |
| `com.eightybps.appsync` | `did:plc:ku5k2fkivxead2a3h46pht7x` (`AppSyncAuthority.did`) |
| `com.eightybps.hummingbird` | `did:plc:dee4dhxgm4ripgybxegi6eg2` |

Each authority DID is also an atproto account whose handle is its project's
subdomain, so the account and the domain vouch for each other:

| Handle | DID | Verified by |
| --- | --- | --- |
| `appsync.eightybps.com` | `did:plc:ku5k2fkivxead2a3h46pht7x` | `_atproto.appsync.eightybps.com` TXT |
| `hummingbird.eightybps.com` | `did:plc:dee4dhxgm4ripgybxegi6eg2` | `_atproto.hummingbird.eightybps.com` TXT, and `/.well-known/atproto-did` on its Pages site |

Each `_atproto` TXT record is `"did=<that DID>"`, and the DID document's
`alsoKnownAs` must name the handle in turn.

A DID is the permanent authority for its namespace: moving a namespace to a
different domain changes only the TXT record, never the DID. For each
namespace:

1. Publish each JSON document in its directory as a
   `com.atproto.lexicon.schema` record in that namespace's authority DID's
   public repository. The record key is the document's full NSID.
2. Add its TXT record, pointing at that namespace's own DID:

   `_lexicon.appsync.eightybps.com TXT "did=did:plc:ku5k2fkivxead2a3h46pht7x"`

   `_lexicon.hummingbird.eightybps.com TXT "did=did:plc:dee4dhxgm4ripgybxegi6eg2"`

ATAppSync currently sends Spaces records with server-side
Lexicon validation disabled so development accounts work before publication.
Once the authority records resolve across the network, enable validation in
`ATAppSync`'s record writers.

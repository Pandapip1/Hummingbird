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

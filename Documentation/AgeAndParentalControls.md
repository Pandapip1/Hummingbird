# Age assurance and parental controls

Hummingbird runs third-party plugins ("sources"). Some of them (general video
platforms such as YouTube) carry content above the app's own age rating. This
note describes how the app restricts that content by age and by parental
controls, and why it is built this way.

## Pieces

| Piece | Where | Role |
| --- | --- | --- |
| `AgeAssurance.currentAgeRange(gates:)` | SwiftOpenUI (both backends) | The platform's age signal, asked now |
| `SourceClassifier` / `SourceClassification` | `Core/Policy/SourceClassification.swift` | Curated or unlisted; rating; restricted-mode settings |
| `SystemParentalControls.status()` / `askParent(_:)` / `parentResponses()` | SwiftOpenUI (both backends) | The system's parental controls and its ask-a-parent flow |
| `ParentalApprovals` | `Core/Policy/ParentalApprovals.swift` | Parents' approvals (profile data, synced) and pending questions |
| `ProfileAgeRange` | `Core/Policy/ProfileAgeRange.swift` | The profile's birthday bound: synced, only tightens |
| `PolicyRules` | `Core/Policy/SourceAccessPolicy.swift` | Every decision as a pure function |
| `SourceAccessPolicy` | same file | Gathers the inputs for each decision and calls the rules |
| `InstallApproval`, `LoadApproval` | same file | Tokens only the policy's rules can mint |
| `LoginNavigationScope` | `Core/Policy/LoginNavigationScope.swift` | Keeps sign-in pages on their source's domains |

## Age: asked every time, remembered only as a birthday bound

Every decision that depends on age (install, each plugin runtime start, each
rendering of a catalog list) asks `AgeAssurance` at that moment. The profile
also keeps what platforms have proved, so a device without an age signal
does not undo what another device of the same profile learned.

**The profile record is an upper bound on the birthday.** A report "at least
L years old" made on day D proves the birthday is no later than D − L years
(UTC calendar days). That bound, its measurement date and its source
(`platform`) are all that is stored: no birth date (even where the platform
has one, as systemd does: it is turned into an age bracket in SwiftOpenUI and
only the bracket's bound is kept), no upper age, no raw platform data.

- **Minimum age on a date** = full years from the bound to that date, so the
  bracket advances on exactly the bound's anniversary. A bound on 29 February
  has its anniversary on 1 March in other years. A report made on 29 February
  gives 28 February L years earlier when that year has none: the earlier day,
  so the bound never claims more age than the report proved.
- **Merging** keeps the tightest bound: the earliest latest-possible birthday,
  ties broken by measurement date, then source. That is a total order, so the
  merge is commutative and every instance converges whatever order records
  arrive in, and it can only raise the minimum age.
- **Fresh reports** are turned into a bound the same way and written to the
  profile when tighter. Declined and unavailable never write.
- **Future-dated measurements**: a local measurement is clamped to now. A
  record from another device measured more than a day in the future (a
  badly skewed clock) is ignored.
- **Effective age** for a decision: the higher of this device's report and the
  bound's minimum age today; the upper limit comes only from this device's
  report, and only if consistent. With a bound, "declined" and "unavailable"
  fall back to it (at least that old, no upper limit).
- **Raising**: only platform reports raise it, on any trusted instance of
  the profile (inside the profile trust model, like any profile record). A
  lower report, a looser synced record and a delete all leave it, and the
  instance writes its record back so the journal converges.
- **Lowering** (moving the bound later) only restricts, so anyone may do it
  after a confirmation (Settings ▸ Age & Parental Controls ▸ Lower the
  Age), no passcode. It writes a **correction**: a record whose
  `correctedAt` is the moment of lowering. Records carry the correction they
  descend from, and the merge order is: newer correction first, then the
  tightest bound. So a correction beats tighter, older bounds on every
  device; reports made after it (which inherit its `correctedAt`) can still
  tighten it, and any device's next platform report can raise it again.
  The order is total, so the merge stays commutative and convergent.
  `correctedAt` is the device clock (clamped to now; a remote one more than
  a day ahead is ignored), not the journal's HLC, which the record payload
  does not see.

Platform sources, all behind the one SwiftOpenUI API:

- **Apple** (iOS, iPadOS, visionOS, macOS 26+): Declared Age Range,
  `AgeRangeService.requestAgeRange(ageGates: 13, 16, 18, in:)`. The system may
  show its own sharing sheet the first time. It can throw "not available"
  (some regions, and macOS in practice), reported as unavailable. Older OS
  versions: unavailable.
- **Linux**: the current user's systemd JSON user record, `birthDate`
  (`YYYY-MM-DD`, added in systemd 261, settable only by an administrator with
  `homectl`), read over the `io.systemd.UserDatabase` Varlink interface
  (`/run/systemd/userdb/io.systemd.Multiplexer`). Only the range between the
  gates leaves the function; the date is never kept. No field, older systemd,
  or no userdb: unavailable.
- **Windows**: the source is WinRT
  `Windows.System.User.CheckUserAgeConsentGroupAsync(Child/Minor/Adult)` from
  the account's family settings (Windows 11; Microsoft has announced
  `CheckAgeStatusAsync` as its successor). SwiftOpenUI's Win32 backend has no
  WinRT bindings yet, so this reports unavailable until they exist.

### When the platform has no answer

Product decision: **no platform age source and no profile bound means
adult**, with no age restrictions. Older OS versions, Linux without a birth date and Windows
without family settings behave like an adult's device. Parental controls are
how a parent restricts such a device. There is no in-app "how old are you?"
prompt: an answer typed into the app would be the weakest signal available.

"Declined" is different from "unavailable": the user (or the parent managing
their account) chose not to share. SwiftOpenUI reports it as its own value
and gives it no meaning; what it means is each app's policy. Hummingbird's
(in `PolicyRules`): installing a source rated above all ages is refused with
an explanation, restricted modes are forced on, and a source already
installed still loads (it passed an age check when installed). With a
profile bound, the bound applies instead.

## Classification: the curated database

Each source is **reviewed** (on Hummingbird's curated list) or **unlisted**.
The list (`CuratedSourceDatabase`, shipped as
`Core/Policy/Resources/CuratedSources.json`) has, per plugin: id, name,
summary, config URL, the **pinned script signing key**, a category, the
plugin's own **age rating**, and its **rated settings**.

### Rated settings (per-setting age gating)

A plugin's rating can depend on its settings. `minimumAge` is the rating
with every rated setting at its safe value; each entry of `settingRatings`
says: when `setting` holds one of `values` (as the plugin stores them:
"true", a dropdown index...), the source is rated `minimumAge`, and
`safeValue` keeps it at its base rating. The effective rating is the
highest that the current settings give.

- **Loading**: a rated setting whose rating this user may not have (the same
  check as installing a reviewed source at that rating: age, the system's
  parental controls) is held at its safe value for that runtime; the stored
  value is kept and the row is shown locked ("Set by age or parental
  controls"), with Ask a Parent under parental controls.
- **Changing** a rated setting to a raising value is gated like installing
  the source at that rating; turning it back to safe is always allowed.
- **A parent's approval** of one setting is stored like a source approval,
  keyed `<plugin id>#<setting>`, synced with the profile.

Current entries: YouTube is **16+** with `allowAgeRestricted` and
`allowControversialRestricted` off, 18+ with either on. The Grayjay YouTube
plugin exposes no Restricted Mode / SafeSearch / comments setting, so 13+
can't be enforced. Odysee (`allowMatureContent`), PeerTube (`nsfwPolicy`
1/2, `allowPlayNsfwContent`) and Internet Archive (`hideAdultContent`,
`hideSensitiveContent` off) are 18+ either way, with those settings held
safe when restricted modes apply. Apple Podcasts is 13+, 18+ with
`allowExplicit`. Patreon stays **18+**: the plugin asks Patreon for
`is_nsfw` per creator in one request but exposes no NSFW or age marker on
creators or posts (and searches with `include_nsfw=true`), so there is
nothing to gate on. Nebula is **16+**.

- A config counts as the reviewed source only if its id **and** its
  `scriptPublicKey` match the entry. A config that uses a reviewed id with
  another key (or none) is unlisted, and its install preview warns "Not the
  reviewed …".
- A plugin's own rating wins; without one, its category's default applies
  (general video platforms, adult and unknown 18+; news, music and podcasts
  13+; education all ages). Unlisted sources are 18+.
- The first list was built from the official Grayjay plugins: each config
  fetched from plugins.grayjay.app and its key pinned from there. The
  community listing grayjay-sources (grayjay-sources.github.io) was only an
  input for which plugins to review; nothing is listed because it appears
  there. **The ratings in it are proposals for review.**
- **Signed updates (optional)**: `CuratedSourceUpdater` fetches a newer list
  and its detached Ed25519 signature (`<url>.sig`, base64), and
  `CuratedSourceDatabase.applyUpdate` adopts it only if the signature
  verifies under the app's built-in key, the format is understood and the
  version is newer. Accepted updates are stored (body and signature) and
  verified again at each launch. No signing key exists yet, so
  `CuratedSourceUpdater.configured` is nil and nothing is fetched.

**Discovery page** (Sources ▸ Discover): the reviewed sources by category
with their ratings. One policy query decides the list: rated above a known
age: not shown (with a note that some are hidden); needs a shared age or a
parent: shown locked with the reason and, under parental controls, Ask a
Parent; otherwise Add, which opens the usual install preview. Installing
from the page goes through the same `prepareInstall` and policy as any other
path.

## Rules

For a source with rating `m` (unlisted: 18), with the effective age (this
device's report combined with the profile's bound) and the system's
parental controls:

1. A parent's **approval** of this source, given through the system,
   allows it.
2. Age: a range at or above `m` allows; below `m` refuses (even for an
   installed source: the age may have changed). No platform age and no
   bound counts as adult, **unless the system reports parental controls**.
   Declined with no bound: an install is refused, a load is allowed (it
   passed an age check when installed).
3. Under the system's parental controls: unlisted sources also need the
   parent to allow installing software (malcontent's
   `AllowUserInstallation`; never on Apple, where the signal doesn't
   exist), and `m` must be within the system's content limit when it gives
   one (malcontent's OARS filter). Anything refused under parental controls
   becomes "needs a parent's approval", with an **Ask a Parent** button.
4. So an arbitrary (unlisted) plugin loads if the age says 18+, or a parent
   approved it through the system; with no parental controls and no age
   signal, it loads (adult by decision).
5. Restricted modes (e.g. YouTube's `allowAgeRestricted`) are forced on
   under the system's parental controls and whenever the user is not known
   (or, without parental controls, assumed) to be an adult. Forcing
   replaces the value for that runtime only; the user's stored setting is
   kept and shown locked.

Catalog visibility (task 59's discovery page): known too young without
parental controls: hidden; needs an age or a parent: shown locked with the
reason.

## Every path goes through the policy, by construction

- `InstallPreview` has a non-optional `InstallApproval`, whose initialiser is
  `fileprivate` to `SourceAccessPolicy.swift`. So no code can build a preview,
  and so call `PluginManager.commit`, without the rules' decision. Every
  install path (typed URL, QR code, grayjay:// links, sync, update, the
  discovery page) goes through `prepareInstall`, which asks the policy from
  the config alone, before the script is downloaded or run.
- `PluginRuntime.init` requires a `LoadApproval`, minted the same way, so no
  plugin JavaScript runs (including the install dry run and settings
  validation) without a load decision. `PluginManager.runtime(for:)` asks at
  every runtime start, records refusals in `loadDenials` for the plugin's
  screen, and exposes forced settings in `forcedSettings`.
- Tests mint approvals through the real rules (`testLoadApproval`), not
  through a bypass.

## Parental controls are the system's

Hummingbird has **no parental passcode** of its own: the parent's authority
is the system's, through one SwiftOpenUI API (`SystemParentalControls`).

- **Apple** (Screen Time / Family Sharing): Declared Age Range's shared
  range carries `activeParentalControls` (an option set:
  `communicationLimits`, and the deprecated
  `significantAppChangeApprovalRequired`) and `ageRangeDeclaration`
  (`selfDeclared`, `guardianDeclared`, `confirmed`). Non-empty controls or a
  guardian declaration means supervised. Screen Time's content restrictions
  themselves are only readable with Family Controls, which needs the
  `com.apple.developer.family-controls` entitlement and Apple's separate
  distribution approval (and is iOS/iPadOS only), so it is not used: a
  supervised Apple user gets no content limit from the system, and every
  refusal goes to a parent.
- **Asking a parent on Apple**: PermissionKit (`AskCenter`, iOS/macOS/
  visionOS 26.2). Its documented topics are communication and
  `SignificantAppUpdateTopic`; adding a content source is a significant
  change in what the app does, so the question is a
  `PermissionQuestion<SignificantAppUpdateTopic>` describing the source and
  its rating. The parent answers on their own device; the answer comes back
  through `AskCenter.responses(for:)`, which the app listens to for its
  lifetime. An approval (`PermissionChoice.approve`) is recorded and the
  source installs automatically.
- **Linux** (GNOME malcontent): the current user's app filter from
  accountsservice, `org.freedesktop.Accounts`, object
  `/org/freedesktop/Accounts/User<uid>`, interface
  `com.endlessm.ParentalControls.AppFilter` (properties `AppFilter (bas)`,
  `OarsFilter (sa{ss})`, `AllowUserInstallation b`,
  `AllowSystemInstallation b`; reading your own is allowed without
  authentication by default), read through `busctl` so no D-Bus library is
  linked. All defaults: not supervised. No accountsservice or malcontent:
  unavailable.
- **OARS filter → age limit**: malcontent's `OarsFilter` gives, per OARS
  category, the most intense level allowed. Each category's levels map to
  ages by libappstream's published OARS → Common Sense Media table
  (`oars_to_csm_mappings` in AppStream's `src/as-content-rating.c`, behind
  `as_content_rating_attribute_to_csm_age`, which gnome-software and
  malcontent use). Hummingbird rates sources by age only, not per category,
  so the mapping is conservative: a source rated A may contain, in any
  category, anything appropriate at A, so it fits a category allowing level
  L only if A is below the next level's age. Each category's limit is that
  age minus one (none for "intense"); the strictest category wins, never
  below 0; an unknown category or level counts as allowing only "none".
  Example: mild realistic violence allowed (moderate is 9+) → sources up to
  8 only. The curated list keeps plain age ratings; per-category OARS
  ratings for sources would allow finer matching later. malcontent has no
  ask-a-parent flow: the parent changes the child's settings instead.
- **Windows** (Family Safety): needs WinRT bindings the Win32 backend does
  not have yet: unavailable.

When the system reports no parental controls (or cannot say) and there is
no age, the user is an adult (earlier product decision).

### Approvals

`ParentalApprovals` keeps, per profile:

- **Approvals** (plugin id, when): profile data, synced through the journal
  (`com.eightybps.hummingbird.parentalApproval`, one record per source), so
  a source a parent approved on one device is approved on the profile's
  others. Only the system's answer to a question this app asked creates
  one; withdrawing one only restricts, so anyone may (and a delete from
  another instance is applied).
- **Pending questions** (question id, source, URL): on this device only,
  since the answer returns to the device that asked.

Trust (accepted, 2026-11-16): approvals and age records are profile data
and share its trust boundary. A record from another trusted instance of the
profile is accepted as is, like a subscription or a source: every instance
the user verified can change the profile, so a modified client on a trusted
instance could forge an approval or raise the age bound. An instance outside
the profile's trust cannot write either.

## Sign-in pages stay on their source's domains

Plugin sign-in and captcha sheets are confined by plugin containment
(`WebAuthSpec.navigationDomains`, Documentation/PluginSecurity.md): every
frame stays within the plugin's declared domains and the start and
completion hosts, never the plugin's "everywhere". The atproto OAuth tab
keeps its main frame on the authorization server's site
(`LoginNavigationScope.oauth`); a navigation outside is cancelled and
nothing else is opened. Together with the address bar resolving only
through plugins, this is why the app has no unrestricted web access.

## Synced sources this device refuses

A source arriving from another instance of the profile goes through the same
policy. If refused (age, parental controls), it is kept as a **locked
source**, shown in Sources under "Locked on this device" with the reason,
not reported as a sync error. Locked sources are stored with the profile and
retried whenever parental controls or the age bound change and whenever
Sources is shown (a bracket can advance by date alone); once allowed, they
install automatically.

## Open questions

- PermissionKit: `AskCenter` is listed at 26.2 and
  `askSignificantChangePermission`'s `PermissionResult` at 27.0; the plain
  `ask(_:in:)` and `responses(for:)` are used. Using the
  significant-app-update topic for "add a source" is my reading of its
  purpose, and App Review may reject it. Asking a parent goes only through
  `SystemParentalControls.askParent(_:)` / `parentResponses()` (one
  SwiftOpenUI API, behind Hummingbird's `SupervisionSource`), so another
  mechanism can replace it without touching the policy.
- The `busctl --json=short` reply shape for `GetAll` is from systemd's
  documented JSON output, not yet checked on a malcontent system.

- Declared Age Range needs the `com.apple.developer.declared-age-range`
  entitlement (added to `Apps/iOS/Hummingbird.entitlements`); the App ID
  must have the capability, or signing fails. Without it the API throws and
  every Apple device would count as "no age source".

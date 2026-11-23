# Hummingbird's plugin forks

Hummingbird runs every plugin exactly as its publisher signed it: there is no
runtime patching (`PluginRuntime` only takes a `CheckedScript`, which only
`ScriptSignature.check` can make). When a plugin needs a fix or an option the
upstream plugin lacks, Hummingbird forks it and publishes the fork under its
own identity, signed with its own key.

## Rules for a fork

- **One repository per plugin**, a fork of the upstream repository. The
  upstream stays as the `upstream` remote; Hummingbird's changes are commits
  on a `hummingbird` branch, rebased onto each upstream release.
- **Its own identity**: a new plugin `id`, the name suffixed
  "(Hummingbird)", the description saying it is Hummingbird's fork, and a
  `sourceUrl` where Hummingbird hosts it. A fork never claims the official
  plugin's id, so it never masquerades as the official plugin (and the
  curated database would treat such a config as an unlisted lookalike).
- **Signed by Hummingbird**: `scripts/sign-plugin <script> <config>` signs
  the script (RSA-4096, PKCS#1 v1.5, SHA-512, as Grayjay expects), checks
  the signature against the public key with openssl, and writes
  `scriptSignature` and `scriptPublicKey` into the config.
  `testSignerScriptOutputVerifies` checks the signer's output with
  Hummingbird's own verifier, using a throwaway GPG key and RSA key.
- **Curated**: each fork has an entry in `CuratedSources.json` with
  Hummingbird's public key pinned.

## The plugin-signing key

- A software RSA-4096 key, generated with `openssl genpkey` in a pipe
  straight into `gpg --armor --encrypt` to the maintainer's card
  encryption subkey (`CBDCE836D0CCB9FB`, NIST P-384, on the OpenPGP card).
  The plaintext private key was never written to disk.
- The encrypted key is `hummingbird-plugin-signing/plugin-signing-key.pem.asc`
  in the **main** Hummingbird checkout (the one whose `.git` every worktree
  shares). It is **never committed**: `.git/info/exclude` lists it. Back it
  up separately; without it, the forks can't be re-signed with this key.
- The public key, `hummingbird-plugin-signing/plugin-signing-key.pub.pem`,
  is committed. SHA-256 of its DER SubjectPublicKeyInfo:
  `05f46e1afb30384207a8e6693d19af9c90c1ea011d131d32dfd59bd0a31f57e2`.
- Signing decrypts the key with gpg into a pipe read by openssl; nothing is
  written to temporary files. With the card inserted, gpg asks for its PIN;
  without it, the signer fails at once without prompting.

## Current forks (local clones in ~/Projects/HummingbirdPlugins)

| Fork | Upstream | New id | Hummingbird changes |
| --- | --- | --- | --- |
| Youtube (Hummingbird) | gitlab.futo.org/videostreaming/plugins/youtube (v371) | `ce484355-23d5-44d5-95ff-aa0b1a0c2471` | Wait for generated UMP tokens before requesting media (formerly the runtime patch `youtube-366-generated-ump-pot-readiness`) |
| Patreon (Hummingbird) | gitlab.futo.org/videostreaming/plugins/patreon (v30) | `bf1ab295-96fa-445d-bb78-215116ee472e` | NSFW settings and metadata (below) |

Published from GitHub (one public repository per fork, the `hummingbird`
branch served by GitHub Pages):

- https://github.com/Pandapip1/grayjay-plugin-youtube-hummingbird →
  https://pandapip1.github.io/grayjay-plugin-youtube-hummingbird/YoutubeConfig.json
- https://github.com/Pandapip1/grayjay-plugin-patreon-hummingbird →
  https://pandapip1.github.io/grayjay-plugin-patreon-hummingbird/PatreonConfig.json

Both upstreams are GNU AGPL v3; the forks keep LICENSE, and NOTICE.md plus
a header in each script state the changes. Only signed commits are pushed.

The Patreon fork adds two settings, both off by default:

- `includeNsfwResults` ("Include NSFW results in search") sets search's
  `filter[include_nsfw]`.
- `showNsfwContent` ("Show NSFW creators and posts"): off, creators Patreon
  marks NSFW (`is_nsfw`) are left out of creator search, their posts out of
  home, search and recommendations, and their channel pages say why.

Every post item carries `isNsfw` (its creator's flag). Curated rating:
**16+** with both off, **18+** with either on (`settingRatings`). The
official Patreon plugin stays 18+. The YouTube fork has the official
plugin's rating (16+, 18+ with age- or controversy-restricted videos on).

The second former patch, `youtube-366-native-ump-legacy-path`, was bundled
but never applied (not in the patch list), so it was dropped.

## GitHub Actions secrets

Each fork repository has two Actions secrets, set 2026-11-18 for a future
signing workflow (none uses them yet):

- `PLUGIN_SIGNING_KEY`: the same RSA-4096 private key, PEM, encrypted with
  AES-256-CBC under a random password (`openssl pkey -aes-256-cbc`).
- `PLUGIN_SIGNING_KEY_PASSWORD`: that password (48 random bytes, base64),
  different per repository.

Both went from gpg's decryption of the card-protected key straight through
pipes into `gh secret set`; neither the plaintext key nor the passwords
were written to disk, a terminal or a command line.

## Releasing: cut a release = bump the version

Each fork has a Release workflow (`.github/workflows/release.yml`). Publishing
a GitHub Release tagged `v<N>` publishes version N:

1. The config's `version` becomes N; N must be higher than the version
   GitHub Pages serves now (the repository's config is the floor if Pages
   can't be read), or the run fails.
2. The script is signed as `scripts/sign-plugin` does (RSA PKCS#1 v1.5,
   SHA-512) with `PLUGIN_SIGNING_KEY`, decrypted with
   `PLUGIN_SIGNING_KEY_PASSWORD` into a pipe only; the signature is checked
   against `hummingbird-signing-key.pub.pem` in the repository.
3. The signed config and script (with icon, LICENSE and NOTICE.md) are
   deployed to GitHub Pages (source: GitHub Actions) and attached to the
   Release. Nothing is committed.

Third-party actions are pinned by commit. Only release events from the
repository itself run it; the build job reads the repository and the
secrets, the deploy job only has `pages: write` and `id-token: write`, and
the job that attaches files to the Release has `contents: write` but no
secrets and runs no repository code.

Manual releases still work: bump `version`, run `scripts/sign-plugin` (card
inserted), commit, push. Either way,
`HUMMINGBIRD_CHECK_PUBLISHED_FORKS=1 swift test --filter testPublishedForksVerify`
checks what Pages serves.

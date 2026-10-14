# Hummingbird atproto deployment

Serve `oauth-client-metadata.json` at exactly:

`https://eightybps.com/oauth-client-metadata.json`

Use an `application/json` content type, HTTPS, and no redirect to a different
origin. The URL is the OAuth public client identifier, so changing it later is
an OAuth client migration rather than a transparent DNS change. Existing local
sessions can continue until they require reauthorization.

## Lexicon authority

The `com.eightybps.hummingbird` NSID group maps to
`hummingbird.eightybps.com`. To publish the schemas:

1. Choose the atproto DID that will permanently own Hummingbird's schemas.
2. Publish each JSON document under `Lexicons/com/eightybps/hummingbird` as a
   `com.atproto.lexicon.schema` record in that DID's public repository. The
   record key is the document's full NSID.
3. Add this DNS TXT record (substituting the authority DID):

   `_lexicon.hummingbird.eightybps.com TXT "did=did:plc:ku5k2fkivxead2a3h46pht7x"`

The application currently sends Spaces journal records with server-side
Lexicon validation disabled so development accounts work before publication.
Once the authority records resolve across the network, enable validation in
`SpaceSyncEngine.pushPending()`.

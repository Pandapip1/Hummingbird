# Hummingbird atproto deployment

Serve `oauth-client-metadata.json` at exactly:

`https://eightybps.com/oauth-client-metadata.json`

Use an `application/json` content type, HTTPS, and no redirect to a different
origin. The URL is the OAuth public client identifier, so changing it later is
an OAuth client migration rather than a transparent DNS change. Existing local
sessions can continue until they require reauthorization.

## Lexicon authority

The reusable `com.eightybps.appsync` protocol and Hummingbird's
`com.eightybps.hummingbird` application schema map to
`appsync.eightybps.com`, backed by the stable authority
`did:plc:ku5k2fkivxead2a3h46pht7x`. To publish the schemas:

1. Keep `did:plc:ku5k2fkivxead2a3h46pht7x` as the permanent protocol authority;
   changing the domain must not create a new DID.
2. Publish each JSON document under `Lexicons/com/eightybps/appsync` and
   `Lexicons/com/eightybps/hummingbird` as a
   `com.atproto.lexicon.schema` record in that DID's public repository. The
   record key is the document's full NSID.
3. Add this DNS TXT record (substituting the authority DID):

   `_lexicon.appsync.eightybps.com TXT "did=did:plc:ku5k2fkivxead2a3h46pht7x"`

ATAppSync currently sends Spaces records with server-side
Lexicon validation disabled so development accounts work before publication.
Once the authority records resolve across the network, enable validation in
`ATAppSync`'s record writers.

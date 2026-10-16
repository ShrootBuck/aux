# Apple Music cloud artwork investigation

Verified on October 15, 2026 (America/Phoenix) using "Smug" by Phoqus, a library song with custom artwork.

## Result

Apple's cloud copy of the custom cover is accessible through a signed HTTPS URL. Its bytes exactly match the artwork exported from the local Music library. Discord rejects this particular URL because it is too long, but accepts a short redirect to it and requests the redirect with its image-fetching client.

This establishes URL retrieval and Discord RPC acceptance. Rendering the cover in a Discord profile was not confirmed. Aux's runtime implementation has not been changed.

## Observed evidence

| Check | Result |
| --- | --- |
| Apple Music web library artwork | Signed URL on `store-033.blobstore.apple.com`, 377 characters |
| Fresh request without cookies or an Authorization header | HTTP 200, 57,440 bytes; byte-for-byte match with local custom artwork |
| Same URL with its signature removed | HTTP 403 |
| URL expiry parameter | 86,400 seconds (24 hours) from the signature timestamp |
| Direct Discord `SET_ACTIVITY` with the Apple URL | Rejected with code 4000: `large_image` must be at most 300 characters |
| Short HTTPS redirect | 100 characters; follows to Apple's image with an exact byte match |
| Discord `SET_ACTIVITY` with the redirect | Accepted; returned an `mp:external/...` image reference |
| Incoming redirect request | Received from `Discordbot/2.0` during the test |
| Discord-rendered pixels | Unverified; the independent media-proxy request was blocked, and the profile image was not visually confirmed |
| Cleanup | Discord acknowledged clearing the test activity; temporary redirect server and Cloudflare tunnel stopped |

The redirect returned HTTP 302 to Apple's original URL. It did not upload or serve an image file. The public test was explicitly authorized, limited to one random image route, and capped at four minutes.

Signed URLs, signatures, account-specific library identifiers, and the temporary public link are intentionally omitted from this document.

## Native retrieval findings

- Music's Apple Events artwork interface exposes image data, not a public artwork URL.
- A local `MusicLibraryRequest<Song>` found the exact library song. Its `Artwork.url(width:height:)` returned a `musicKit://artwork/transient/...` URL, which Discord cannot fetch.
- Local MusicKit metadata included the corresponding cloud library ID. Its encoded `musicKit_*` fields are an observation, not an established public API contract for mapping IDs.
- Apple's documented library-song API exposes artwork metadata. Accessing that cloud API through the probe failed with `MusicKit.MusicTokenRequestError` code 5 (developer token generation) under both ad-hoc and Apple Development signing.
- The signed-in developer account's Identifiers page displayed "Access Unavailable" and required developer-program or organization-team access. Changing the local signing identity alone did not resolve token generation.
- The signed HTTPS image was obtained from the user's authenticated Apple Music web library. Retrieval through a registered Aux MusicKit app remains unverified.

## Requirements before integrating this into Aux

1. Obtain access to an explicit App ID with MusicKit enabled, configure the app accordingly, and verify that the native cloud request returns the user's custom artwork for this same song.
2. Use a stable short redirect for image URLs exceeding Discord's limit. Treat each signed image URL as a temporary bearer link; avoid recording it in public logs or source control.
3. Refresh expiring Apple URLs and keep existing fallback behavior for unavailable or unsynced artwork.
4. Confirm the rendered image in Discord, then verify ordinary track changes, artwork changes, expiry, and clearing activity.

The temporary Cloudflare tunnel was an investigation tool, not a production service. No developer enrollment, persistent service, or production integration was created by these tests.

## References

- [Apple: automatic token generation for Apple Music API](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)
- [Apple: get a library song](https://developer.apple.com/documentation/applemusicapi/get-a-library-song)
- [Apple: library-song attributes](https://developer.apple.com/documentation/applemusicapi/librarysongs/attributes-data.dictionary)
- [Discord: activity assets](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1ActivityAssets.html)
- [Discord: activity image references](https://github.com/discord/discord-api-docs/blob/main/developers/events/gateway-events.mdx)

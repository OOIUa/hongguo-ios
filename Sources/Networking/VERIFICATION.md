# Native protocol verification

Verified 2026-10-28 using the macOS build of the same Swift sources and JavaScriptCore runtime. These are anonymous, read-only probes; no account session or account write was used.

- Bundled runtime self-test: SM3 `abc`, native MD5 bridge, UTF-8/base64 conversion and 64-bit little endian conversion.
- Independent signing comparison: original Node Buffer / Node crypto and the iOS JavaScriptCore Buffer / native crypto bridge produced identical Gorgon, Helios and Medusa output under fixed clock/random sources at four consecutive timestamp variants. The requests were synthetic `example.com` inputs.
- Recommended homepage: 18 cards, advancing cursor, continuation available.
- Latest catalogue: 18 + 18 cards on adjacent pages, zero duplicate IDs, advancing cursor.
- Comic and AI catalogues: 18 cards each.
- Comic ranking: 10 cards, continuation available.
- Dynamic short-play filters: 6 groups.
- Search: 20 + 20 results on adjacent pages, zero duplicate IDs.
- First returned drama: 86 episodes; first episode returned a compatible encrypted HTTPS 1080p track.

No full request or media URLs, registered device identifiers, account credentials or media keys are included here. Successful protocol tests do not establish personal-account login or cloud-write acceptance. The media module separately verifies downloading, CENC decryption and AVFoundation decoding; an actual iPhone installation remains a separate acceptance step.

## Dependencies and sources

`PureSign.js` vendors the pure JavaScript signing and SM3 algorithms from `jackotom/hongguo-drama` commit `5febca2e5fca0fff4f4a5f21db50f5de75cbeab6`, under GPL-3.0-only; its original attribution to `woshishiq1/drpys` and `N3urda/hongguoTV` is retained in the file. `BufferRuntime.js` implements the limited Node-compatible binary operations needed by that local algorithm; native hashing/randomness use the project's `HGCrypto` bridge. JavaScript code has no networking or filesystem access.

`DramaAPI.swift`, `ProtocolJSON.swift`, and `PlaybackRegistration.swift` adapt the Android project's `Client`, `WebSource`, `AppSource`, and `PlaybackDevice` behavior, including the separately registered, unsigned playback request introduced on 2026-10-27. See the application-wide third-party notices and GPL-3.0 license.

## Reproduce

From the project root on macOS with Xcode selected:

```sh
./scripts/test-network.sh
```

This is fully offline. It checks the four pinned Node signing outputs in JavaScriptCore, optionally reruns them with an installed Node runtime, verifies long-ID JSON parsing, verifies a binary/gzip request body is signed without UTF-8 conversion, and rejects an already-cancelled catalogue query before HTTP.

`./scripts/test-network-live.sh --live` is a separate opt-in anonymous read-only catalogue/pagination probe. `./scripts/test-media-live.sh --live` covers the complete playback path. Live scripts depend on the upstream service's current availability; they do not establish personal-account acceptance.

## Review against the Android implementation

- The recommended home tab maps to the short-play catalogue sorted by `hot_score`; latest maps to `online_time`; comic maps to the comic recommendation rank. This provides the same catalogue capabilities without reproducing Android's exact page composition.
- Search cursors retain upstream offset, passback, and search ID; displayed offsets count visible results. Browse/ranking offsets count consumed upstream rows. Browse sends the most recent 180 displayed IDs. Requests are bounded to three browse iterations and eight search iterations per call, so a sparse result set can produce a short page.
- Catalogue identity is an anonymous process-scoped generated ID. Playback uses a separately registered process-scoped identity. Registration success is shared, failure has a 30-second cooldown, and no account cookies enter either flow. Android persists its catalogue identity between launches; this iOS version regenerates it at process launch.
- Metadata caches stay in memory: at most 80 details with a six-hour expiry, 16 search cursor accumulators with a ten-minute expiry, and 32 discovery filter contexts. Filter panels are bounded to three supported genres and last for the process lifetime. No raw responses, device identities, or URLs are logged or written to cache files.
- A private ephemeral URLSession disables cookie storage, HTTP cache, and redirects. Fixed official HTTPS metadata origins and explicit API/CDN fallback domain allowlists prevent credential/body forwarding via redirects. HTTP errors and malformed/empty responses fail explicitly. The 8 MB response guard currently runs after URLSession has collected a response, so it bounds parsing but is not a streaming allocation limit.
- Cancellation is checked before signing, before dispatch, after throttling, and after HTTP completion; URLSession's async call propagates in-flight task cancellation. Shared anonymous registration deliberately continues for other waiters when one viewer cancels. Cancelling a viewer prevents its later track HTTP request.
- The signer now transports request bodies through base64 across JavaScriptCore, retaining arbitrary binary/gzip bytes. `signedRequest` chooses a branch-zero URL and signs those exact query bytes. `sign(url:body:device:)` signs an already-final URL and does not alter its query; callers requiring branch zero should use `signedRequest`.
- No automatic protocol write replay exists in this module. Metadata POSTs are reads, and the anonymous registration is the only device-initialization mutation. Account writes and their replay/identity rules belong to the separate account module.

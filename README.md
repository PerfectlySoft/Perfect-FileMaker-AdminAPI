# Perfect FileMaker Admin API

<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.2%2B-orange.svg?style=flat" alt="Swift 6.2+">
    <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B%20%7C%20Linux-lightgray.svg?style=flat" alt="Platforms macOS 12+ | Linux">
    <a href="LICENSE" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache%202.0-lightgrey.svg?style=flat" alt="License Apache 2.0">
    </a>
</p>

A Swift client for the FileMaker Server Admin API (v2), which lists connected clients and
force-disconnects them. On top of it sits a policy layer, the **CWP Session Janitor**, that
periodically finds stale or excess Custom Web Publishing sessions and disconnects them to keep
FileMaker Server under its licensed concurrent-connection cap.

The Janitor has been run against a live FileMaker Server, where stuck CWP sessions would otherwise
use up the server's connection cap (200 on the server it was tested against).

## Requirements

- Swift 6.2 or later (`swift-tools-version: 6.2`, Swift 6 language mode).
- macOS 12 or later, or Linux. CI covers Swift 6.2 and 6.4 on Ubuntu 24.04 and Xcode 26.0.1 and
  26.6 on macOS, in debug and release, with warnings as errors.
- `FMAdminInsecureTLSDelegate` (see below) is Darwin-only,
  since it depends on Security-framework primitives (`SecTrust`/`SecIdentity`)
  that `swift-corelibs-foundation` doesn't implement on Linux. The supported
  production path on Linux is still to install the server's certificate into
  the system CA trust store. For local dev/test against a self-signed
  FileMaker Server, `FMAdminInsecureLinuxTransport` (see below) provides a
  Linux equivalent — pinned to one certificate you supply, rather than
  trusting any certificate the way the Darwin delegate does.

## Dependencies

None on Darwin. `Package.swift`'s `dependencies:` array lists
`async-http-client`, `swift-nio`, and `swift-nio-ssl`, but they're wired into
the target only via `condition: .when(platforms: [.linux])` — they back
`FMAdminInsecureLinuxTransport` and are never compiled into macOS builds.
Everything else uses Foundation / FoundationNetworking and `URLSession`
directly, with no third-party HTTP or JSON layer.

It is also deliberately independent of, and has zero dependency on,
[Perfect-FileMaker](https://github.com/PerfectlySoft/Perfect-FileMaker) (the classic XML CWP client) or
[Perfect-FileMaker-DataAPI](https://github.com/PerfectlySoft/Perfect-FileMaker-DataAPI). A consumer that only needs FileMaker Server
session management can pull in just this package.

## Using in your project

```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-FileMaker-AdminAPI.git", from: "1.0.0"),
```

```swift
.product(name: "PerfectFileMakerAdminAPI", package: "Perfect-FileMaker-AdminAPI"),
```

## What's here

### Raw Admin API client

- **`FMAdminClient`** — `public struct ... Sendable` wrapping the FileMaker
  Server Admin API v2 over `URLSession`. `listClients()` and
  `disconnectClient(clientID:messageText:graceTime:)`, both `async throws`.
  `disconnectClient` performs a **real** disconnect — there is no built-in
  dry-run; "would I disconnect this" is a policy decision left to the layer
  above (see the Janitor below).
- **`FMAdminSession`** (internal `actor`) — caches the Admin API's
  15-minute bearer token. Re-authenticating on every call is a known
  anti-pattern that can exhaust the session cap on its own, so token caching
  here is safety-relevant, not just an optimization.
- **`FMAdminModels`** — `Decodable`, `Sendable` response types
  (`FMAdminClientInfo`, `FMAdminGuestFile`).
- **`FMAdminError`** — `Error, Sendable`.
- **`FMAdminInsecureTLS`** — an explicit opt-in `URLSessionDelegate`
  (`FMAdminInsecureTLSDelegate`) for trusting self-signed certs, e.g.
  FileMaker Server's default dev certificate. Not marked `Sendable` itself —
  `URLSessionDelegate` conformance has its own thread-safety contract
  independent of Swift's `Sendable` checking. Opt-in only; never the default.
  **Darwin-only** (see Requirements above).
- **`FMAdminInsecureLinuxTransport`** — **Linux-only**, the Linux equivalent
  of `FMAdminInsecureTLSDelegate` above. Backed by AsyncHTTPClient/NIOSSL
  rather than `URLSession`, since Linux has no `SecTrust` to build a
  `URLSessionDelegate`-based bypass on. Pins trust to one PEM certificate —
  passed explicitly via `pinnedCertificatePath:`, or read from the
  `FMADMIN_INSECURE_CERT_PATH` environment variable — rather than trusting
  any certificate; a MITM presenting a different certificate still fails.
  Use via `FMAdminClient.insecureLinux(host:port:username:password:pinnedCertificatePath:)`.
  Logs a warning to stderr on construction. Opt-in only; never the default.

### CWP Session Janitor (policy layer)

- **`CWPSessionSelector`** — pure selection logic. Being over `maxSessions`
  is the *only* disconnect trigger; a `durationThresholdSeconds` filter only
  narrows which of the over-the-limit sessions get picked. Supports a
  `minFloor` (never disconnect below N surviving sessions) and a per-sweep
  disconnect cap so a large backlog drains gradually across sweeps rather
  than all at once.
- **`CWPSessionJanitor`** — runs one sweep: fetch clients → select
  candidates → dry-run-or-disconnect → report into a tracker. No in-loop
  retry on failure by design (the Admin Server has documented real-world
  flakiness; the caller's own poll loop retries on its next cycle).
- **`CWPSessionJanitorTracker`** — `public actor` recording last-sweep state
  (`lastSweepAt`, `considered`, `disconnected`, `dryRun`, `error`) via
  async-safe accessors, and preventing two overlapping sweeps.

## Usage

```swift
import PerfectFileMakerAdminAPI

let client = FMAdminClient(
    host: "filemaker.example.com",
    username: "admin",
    password: "••••••••"
)

let tracker = CWPSessionJanitorTracker()

await CWPSessionJanitor.sweep(
    client: client,
    durationThresholdSeconds: 3600,
    maxSessions: 150,
    minFloor: 20,
    maxDisconnectsPerSweep: 10,
    dryRun: false,
    tracker: tracker,
    log: { print($0) }
)
```

For local development against a self-signed FileMaker Server certificate on
**Darwin**, pass a `URLSession` configured with `FMAdminInsecureTLSDelegate`
into `FMAdminClient`'s `urlSession` parameter — this should never be used
against a production server with a real certificate.

On **Linux**, export the dev/test server's certificate once —

```bash
openssl s_client -connect filemaker.dev.example:16000 -showcerts </dev/null \
    2>/dev/null | openssl x509 -outform PEM > fm-dev-server.pem
```

— then either pass its path explicitly or set `FMADMIN_INSECURE_CERT_PATH`:

```swift
let client = try FMAdminClient.insecureLinux(
    host: "filemaker.dev.example",
    username: "admin",
    password: "••••••••",
    pinnedCertificatePath: "fm-dev-server.pem"
)
```

This pins trust to that one certificate rather than trusting any certificate
— never use it against a production server either.

## License

Apache 2.0. See [LICENSE](LICENSE).

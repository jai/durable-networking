# Airplane Wi-Fi boost, drop-in

Status: proposed (2026-11-17). Issue: [#2](https://github.com/jai/durable-networking/issues/2).

## Goal

Any app on DurableNetworking gets Airplane Wi-Fi boost by writing three things: where its server says the relay is,
one settings row, and one line at launch. Everything else ships here: the switch's logic, the relay kept between
launches, the status a settings row shows, and the tests.

Today only Agent Pager has it, and about 300 lines of it are in the app
([`AirplaneBoost.swift`](https://github.com/jai/agent-pager/blob/main/ios/AgentPager/Networking/AirplaneBoost.swift),
[`AirplaneRelayStore.swift`](https://github.com/jai/agent-pager/blob/main/ios/AgentPager/Security/AirplaneRelayStore.swift)).
None of it depends on Agent Pager. PRHub would have to copy it.

## What a host writes, after

```swift
// 1. Its two sessions, as today, wrapped once.
let boost = AirplaneBoost(
    live: URLSessionTransport(isInForeground: inForeground),
    reads: URLSessionTransport(isInForeground: { false }),
    relay: { try await workerClient.airplaneRelay() }   // its own authenticated config: SatmuxRelay or nil
)
let client = WorkerClient(transport: RetryingTransport(inner: boost.live), reads: RetryingTransport(inner: boost.reads))

// 2. At launch.
boost.start()

// 3. In Settings (SwiftUI), or its own row reading the same model.
AirplaneBoostRow(boost: boost)
```

And on its server, one field in its authenticated config (shape below).

## What moves here

All additive: CI's `diagnose-api-breaking-changes` stays green, and `SatmuxTransport` is unchanged.

1. **`AirplaneBoost`** (`@MainActor @Observable`), from Agent Pager's class of the same name:
   - `setting`: `.off`, `.automatic` or `.always`, persisted in `UserDefaults` under a key the host can name
     (Agent Pager passes `"airplaneWiFiBoost"` so nobody's setting resets). Setting it engages or disengages at once.
   - `.automatic` engages with `SatmuxMode.automatic` (relays while the round trip is above 300 ms, stops below
     200 ms; on main since 0.5.0). This is the default a host's switch should mean: leave it on, it boosts on a
     plane and steps aside on the ground.
   - `status`, one explicit state machine: `off`, `findingRelay`, `noRelay` (the server offers none), `notReached`
     (asked again at the next foreground), `standingBy(roundTrip:)` (automatic, link fast), `relaying(carriers:,
     roundTrip:)`. Each with a plain-English `summary` a host may show or replace.
   - `start()`: follows the setting at launch, and again when the app comes forward
     (`UIApplication`/`NSApplication.didBecomeActiveNotification`) and when the network changes (`PathWatcher`), so a
     host has no lifecycle code to write.
   - `live` and `reads`: the two `SatmuxTransport`s over one set of carriers (`sharingCarriers`).
2. **The relay kept between launches**: `AirplaneBoost.RelayStore` with `.keychain(service:account:)` (generic
   password, `AfterFirstUnlockThisDeviceOnly`, not synced; the host names the account, Agent Pager keeps
   `"airplane-relay"`) and `.inMemory` for tests. A launch on the plane engages the kept relay before its first read,
   then asks the server; a new relay or key replaces it, `nil` forgets it.
3. **`SatmuxRelay: Codable`**, as `{"host": "203.0.113.7", "port": 8444, "key": "<64 hex>"}`: one shape for the
   server's answer and the Keychain copy. Decoding checks it (a bad key fails the decode), so hosts parse at the
   boundary with `JSONDecoder` and nothing else.
4. **`AirplaneBoostRow`**, a SwiftUI view in a new product `DurableNetworkingUI`: the switch (off / on meaning
   automatic), the status line and a one-line explanation, with accessibility identifiers `airplane-boost` and
   `airplane-boost-status` for hosts' UI tests. A host with its own design tokens (Agent Pager forbids raw fonts)
   draws its own row from the same model. `DurableNetworking` itself stays free of SwiftUI.
5. **Testing pieces**, in `DurableNetworkingTesting` and `Tools/`:
   - `geo_link.py` moves to `Tools/geo_link/` (Agent Pager keeps a copy today), with the 600 ms link, SOCKS for
     direct requests and a TCP forward for carriers.
   - A host's end-to-end check fetches it, and `Tools/satmux/satmux.py`, at its pinned tag instead of copying them.

## The server's side (each host)

- One field in an **authenticated** config the app already reads, holding `SatmuxRelay`'s JSON or `null`. Agent
  Pager's is `airplane_boost` in `GET /device/config`
  ([selfhost.md §12.1](https://github.com/jai/agent-pager/blob/main/docs/api/selfhost.md)).
- Filled from three secrets, `SATMUX_HOST`, `SATMUX_PORT`, `SATMUX_PSK`; `null` unless all three are well formed.
  Never in a binary or git; never for a test or demo login.
- README gets the reference Worker function (Agent Pager's `airplaneRelay(env)`, 12 lines of TypeScript), so a
  Worker copies it.

## The relay (shared)

One relay serves every app: [agent-pager `deploy/satmux`](https://github.com/jai/agent-pager/tree/main/deploy/satmux)
(Singapore, `t4g.nano`, about USD 8 a month). Its `push-secrets` and `rotate-key` write the three secrets into
Agent Pager's Worker only. For a second app, they take a list of Workers. Moving `deploy/satmux` to its own repo is
cleaner but not needed for PRHub.

## Migration

1. **DurableNetworking** (one `feat`, about half a day): items 1–5 above, the demo switched to `AirplaneBoost` and
   `AirplaneBoostRow` (its UI test drives off → automatic → always → off on iPhone and Mac), and Agent Pager's unit
   tests moved here.
2. **Agent Pager** (net deletion): pin the new release, delete `AirplaneBoost.swift` and `AirplaneRelayStore.swift`,
   keep its own row (design tokens), pass its existing defaults key and Keychain account. Its switch then means
   automatic. `make net-e2e-airplane` and the gate's settings tests must stay green; the Worker is unchanged.
3. **PRHub** (about an hour plus its gate): its Worker returns the relay in its authenticated config, `push-secrets`
   learns its Worker, the app wraps its two sessions, calls `start()`, and adds `AirplaneBoostRow` to Settings.
4. **Any later app**: steps 3's three app lines and one server field.

## Decisions to make

- **What the switch means**: automatic (recommended: safe to leave on), with "always" only in `setting`.
- **Name**: `AirplaneBoost` (the reader's word, as the apps already say), over `SatmuxBoost` (the vendor's).
- **`DurableNetworkingUI`**: ship the row (recommended: PRHub and later apps get a tested control for free), or
  leave every host to draw its own.
- **The relay's repo**: stays in agent-pager for now (recommended), or moves out when a third app joins.

## Not in this

- Request bodies through the relay: upstream `satmux.py` sends none, so writes stay direct.
- Streams (`StreamingTransport`) and background uploads: they stay direct.

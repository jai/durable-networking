import DurableNetworking
import Foundation
import Observation
import Synchronization

/// Airplane Wi-Fi: a screen's six reads over an emulated geostationary link (600 ms round trip,
/// Demo/server/geo_link.py), directly or through a satmux relay (`SatmuxTransport`).
///
/// - Direct, each load opens new connections through the link, as an app does when it comes back after the link has
///   been idle: TCP and TLS, then the request.
/// - Boosted, the reads go as ground fetches over the carriers the boost keeps open to the relay; the relay fetches
///   on the ground (here: on this machine, past the link).
///
/// - Auto, the carriers stay open and the reads go through them only while the round trip they measure is high
///   (`SatmuxMode.automatic`): over the satellite link they do; over the ground link (no emulated delay, the relay
///   reached directly) they don't.
///
/// The servers: `demo_server.py`, the relay (`Tools/satmux/satmux.py server`) and `geo_link.py` in front of both
/// (docs/end-to-end-walkthrough.md).
@MainActor
@Observable
final class AirplaneModel {
    struct Setup {
        /// The demo server by a name that resolves to 127.0.0.1 (sslip.io): the system routes loopback and
        /// local-network addresses around a proxy, and the relay must reach the same URL.
        var origin = URL(string: "http://127.0.0.1.sslip.io:8787")!
        var link = SOCKSProxy(host: "127.0.0.1", port: 1_081)
        var relayHost = "127.0.0.1"
        /// The relay past the emulated link.
        var relayPort = 8_445
        /// The same relay without it: the ground link.
        var groundRelayPort = 8_444
        /// The key the demo's relay is started with (ci.yml, docs/end-to-end-walkthrough.md): a demo value, not a
        /// secret.
        var relayKey = String(repeating: "5a", count: 32)

        static func from(_ environment: [String: String]) -> Setup {
            var setup = Setup()
            if let origin = environment["DEMO_AIRPLANE_ORIGIN"].flatMap(URL.init(string:)) {
                setup.origin = origin
            }
            return setup
        }
    }

    enum Boost: String {
        case off, on, auto
    }

    private(set) var boost = Boost.off
    /// Satellite: through `geo_link.py`'s 600 ms round trip. Ground: straight to the servers.
    private(set) var isOnGround = false
    private(set) var status = "Boost: off"
    private(set) var loads: [String] = []
    private(set) var isLoading = false

    @ObservationIgnored private let setup: Setup
    @ObservationIgnored private let direct: ColdDirect
    @ObservationIgnored private let transport: SatmuxTransport
    @ObservationIgnored private var watch: Task<Void, Never>?

    init(setup: Setup) {
        self.setup = setup
        direct = ColdDirect(policy: Self.policy(proxy: setup.link))
        transport = SatmuxTransport(direct: direct)
    }

    /// On, or off when on.
    func toggleBoost() async {
        await set(boost == .on ? .off : .on)
    }

    /// Auto, or off when auto.
    func toggleAuto() async {
        await set(boost == .auto ? .off : .auto)
    }

    /// Satellite or ground: the direct path and the carriers both move to the other.
    func toggleLink() async {
        isOnGround.toggle()
        direct.renew(policy: Self.policy(proxy: isOnGround ? nil : setup.link))
        await set(boost)
    }

    private func set(_ next: Boost) async {
        watch?.cancel()
        boost = next
        guard next != .off else {
            await transport.disengage()
            status = "Boost: off"
            return
        }
        do {
            let port = isOnGround ? setup.groundRelayPort : setup.relayPort
            let relay = try SatmuxRelay(host: setup.relayHost, port: port, keyHex: setup.relayKey)
            await transport.engage(relay, mode: next == .auto ? .automatic : .always)
            watch = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshStatus()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            status = "Boost: bad relay setup"
        }
    }

    private static func policy(proxy: SOCKSProxy?) -> SessionPolicy {
        SessionPolicy(requestTimeout: 30, waitsForConnectivity: false, socksProxy: proxy)
    }

    /// Six reads at once, as a screen opening does; records how long until the last answered, and how many came
    /// through the relay.
    func loadScreen() async {
        isLoading = true
        defer { isLoading = false }
        direct.renew(policy: nil)
        let started = ContinuousClock.now
        let transport = transport
        let origin = setup.origin
        let answers = await withTaskGroup(of: Answer.self) { group in
            for n in 1...6 {
                group.addTask {
                    do {
                        let request = URLRequest(url: origin.appending(path: "screen/\(n)"))
                        let (data, response) = try await transport.send(request)
                        return response.statusCode == 200 && !data.isEmpty
                            ? (SatmuxTransport.isRelayed(response) ? .relayed : .direct) : .failed
                    } catch {
                        return .failed
                    }
                }
            }
            var answers: [Answer] = []
            for await answer in group {
                answers.append(answer)
            }
            return answers
        }
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        let relayed = answers.filter { $0 == .relayed }.count
        let ok = answers.filter { $0 != .failed }.count
        let path = boost == .off ? "direct" : boost == .on ? "boost" : "auto"
        loads.append("\(path) \(String(format: "%.2f", elapsed)) s · \(ok)/6 loaded · \(relayed) via relay")
    }

    private func refreshStatus() async {
        let open = await transport.openCarriers
        let trip = await transport.roundTrip.map { " · \(Int($0 / .milliseconds(1))) ms round trip" } ?? ""
        let relaying = await transport.isRelaying
        guard !Task.isCancelled else {
            return
        }
        switch boost {
        case .off:
            status = "Boost: off"
        case .on:
            status = "Boost: on · \(open) carriers\(trip)"
        case .auto:
            status = "Boost: auto, \(relaying ? "relaying" : "direct") · \(open) carriers\(trip)"
        }
    }

    private enum Answer: Sendable {
        case direct, relayed, failed
    }
}

/// The direct path, with new connections for each load: a fresh session, as after the link has dropped idle ones.
private final class ColdDirect: HTTPTransport {
    private let policy: Mutex<SessionPolicy>
    private let current: Mutex<URLSessionTransport>

    init(policy: SessionPolicy) {
        self.policy = Mutex(policy)
        current = Mutex(URLSessionTransport(policy: policy))
    }

    /// A fresh session; with `policy`, the next ones use it.
    func renew(policy next: SessionPolicy?) {
        current.withLock { current in
            if let next {
                policy.withLock { $0 = next }
            }
            current = URLSessionTransport(policy: policy.withLock { $0 })
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await current.withLock { $0 }.send(request)
    }
}

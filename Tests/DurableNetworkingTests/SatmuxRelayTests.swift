@testable import DurableNetworking
import Foundation
import Synchronization
import Testing

/// SatmuxTransport against satmux's own relay (Tools/satmux/satmux.py, run here) in front of the demo server.
@Suite(.serialized, .enabled(if: LocalRelay.python != nil, "needs python3"))
struct SatmuxRelayTests {
    @Test func aReadGoesThroughTheRelay() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 3)
            await transport.engage(relay.relay)
            var request = URLRequest(url: relay.origin.appending(path: "echo"))
            request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            #expect(response.statusCode == 200)
            #expect(SatmuxTransport.isRelayed(response))
            let echo = try JSONDecoder().decode(Echo.self, from: data)
            #expect(echo.headers["Authorization"] == "Bearer secret-token")
            #expect(echo.headers["User-Agent"] == "curl/8.7.1") // The relay's own: it made the request.
            #expect(direct.count == 0)
            #expect(await transport.openCarriers == 3)
            await transport.disengage()
        }
    }

    @Test func manyReadsAtOnceAndLargeAnswers() async throws {
        try await LocalRelay.with { relay in
            let transport = SatmuxTransport(direct: RecordingTransport(), carriers: 4)
            await transport.engage(relay.relay)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for n in 0..<24 {
                    group.addTask {
                        let (data, response) = try await transport.send(
                            URLRequest(url: relay.origin.appending(path: "screen/\(n)"))
                        )
                        #expect(SatmuxTransport.isRelayed(response))
                        #expect(response.statusCode == 200)
                        #expect(data.count > 16_384) // More than one relay frame.
                        let screen = try JSONDecoder().decode(Screen.self, from: data)
                        #expect(screen.screen == "\(n)")
                        #expect(screen.rows.count == 150)
                    }
                }
                try await group.waitForAll()
            }
            await transport.disengage()
        }
    }

    @Test func theRelayFollowsRedirects() async throws {
        try await LocalRelay.with { relay in
            let transport = SatmuxTransport(direct: RecordingTransport(), carriers: 1)
            await transport.engage(relay.relay)
            let (data, response) = try await transport.send(URLRequest(url: relay.origin.appending(path: "moved")))
            #expect(response.statusCode == 200)
            #expect(try JSONDecoder().decode(Echo.self, from: data).path == "/echo")
            await transport.disengage()
        }
    }

    @Test func writesAndWhatTheRelayCannotReachGoDirect() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 1)
            await transport.engage(relay.relay)
            var write = URLRequest(url: relay.origin.appending(path: "writes"))
            write.httpMethod = "POST"
            write.httpBody = Data("{}".utf8)
            _ = try await transport.send(write)
            // The relay answers 502 with no satmux marker when it can't make the request.
            _ = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:9/unreachable")!))
            #expect(direct.urls == [write.url!, URL(string: "http://127.0.0.1:9/unreachable")!])
            await transport.disengage()
        }
    }

    @Test func aWrongKeyNeverOpensACarrierAndRequestsGoDirect() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 2, warmWait: .milliseconds(500))
            let wrong = try SatmuxRelay(
                host: "127.0.0.1", port: Int(relay.relay.port), keyHex: String(repeating: "ab", count: 32)
            )
            await transport.engage(wrong)
            _ = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(direct.count == 1)
            #expect(await transport.openCarriers == 0)
            await transport.disengage()
        }
    }

    @Test func disengagedSendsDirect() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 1)
            await transport.engage(relay.relay)
            _ = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            await transport.disengage()
            _ = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(direct.count == 1)
            #expect(await transport.relay == nil)
        }
    }

    @Test func aSharingTransportUsesTheSameCarriers() async throws {
        try await LocalRelay.with { relay in
            let otherDirect = RecordingTransport()
            let transport = SatmuxTransport(direct: RecordingTransport(), carriers: 2)
            let sharing = transport.sharingCarriers(direct: otherDirect)
            await transport.engage(relay.relay)
            let (_, response) = try await sharing.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(SatmuxTransport.isRelayed(response))
            #expect(await sharing.openCarriers == 2)
            await sharing.disengage()
            _ = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(await transport.relay == nil)
            #expect(otherDirect.count == 0)
        }
    }

    @Test func carriersComeBackAfterTheRelayRestarts() async throws {
        try await LocalRelay.with { relay in
            let transport = SatmuxTransport(direct: RecordingTransport(), carriers: 2)
            await transport.engage(relay.relay)
            _ = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            try relay.restartRelay()
            let (_, response) = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(SatmuxTransport.isRelayed(response))
            await transport.disengage()
        }
    }

    @Test func automaticStaysDirectOnAFastLink() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 2)
            await transport.engage(relay.relay, mode: .automatic)
            try await Self.untilMeasured(transport)
            let (_, response) = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(!SatmuxTransport.isRelayed(response))
            #expect(direct.count == 1)
            #expect(await !transport.isRelaying)
            #expect(await transport.openCarriers == 2) // Warm for when the link slows.
            await transport.disengage()
        }
    }

    @Test func aModeRelaysWhileTheRoundTripIsAboveItsMark() async throws {
        try await LocalRelay.with { relay in
            let direct = RecordingTransport()
            let transport = SatmuxTransport(direct: direct, carriers: 2)
            // Any measured round trip is above zero: as on a plane.
            await transport.engage(relay.relay, mode: .whenRoundTrip(above: .zero, below: .zero))
            try await Self.untilMeasured(transport)
            #expect(await transport.isRelaying)
            let (_, slow) = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(SatmuxTransport.isRelayed(slow))

            // The same relay with marks no local link reaches: as on landing. The carriers stay.
            await transport.engage(relay.relay, mode: .whenRoundTrip(above: .seconds(10), below: .seconds(5)))
            #expect(await !transport.isRelaying)
            let (_, fast) = try await transport.send(URLRequest(url: relay.origin.appending(path: "echo")))
            #expect(!SatmuxTransport.isRelayed(fast))
            #expect(direct.count == 1)
            #expect(await transport.openCarriers == 2)
            await transport.disengage()
        }
    }

    /// Waits until a carrier has measured the round trip (each pings when it opens).
    private static func untilMeasured(_ transport: SatmuxTransport) async throws {
        for _ in 0..<100 where await transport.roundTrip == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await transport.roundTrip != nil)
    }
}

private struct Echo: Decodable {
    var path: String
    var headers: [String: String]
}

private struct Screen: Decodable {
    struct Row: Decodable {
        var id: String
    }

    var screen: String
    var rows: [Row]
}

/// Answers 299 to everything and keeps the URLs it was sent.
private final class RecordingTransport: HTTPTransport {
    private let sent = Mutex<[URL]>([])

    var urls: [URL] {
        sent.withLock { $0 }
    }

    var count: Int {
        urls.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.withLock { $0.append(request.url!) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 299, httpVersion: nil, headerFields: nil)!)
    }
}

/// satmux.py's relay and the demo server, on loopback, for one test. Its processes are started and stopped from the
/// test's own task.
final class LocalRelay: @unchecked Sendable {
    static let python: URL? = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let keyHex = String(repeating: "5a", count: 32) // A test key: the relay runs on loopback for one test.

    let origin: URL
    let relay: SatmuxRelay
    private var processes: [Process]

    private init(origin: URL, relay: SatmuxRelay, processes: [Process]) {
        self.origin = origin
        self.relay = relay
        self.processes = processes
    }

    static func with(_ body: (LocalRelay) async throws -> Void) async throws {
        let server = try launch(["Demo/server/demo_server.py", "--port", "0"], until: "demo server on ")
        let port = Int.random(in: 20_000...40_000)
        let satmux = try launchRelay(port: port)
        let local = LocalRelay(
            origin: URL(string: server.line.components(separatedBy: "demo server on ").last!)!,
            relay: try SatmuxRelay(host: "127.0.0.1", port: port, keyHex: keyHex),
            processes: [server.process, satmux]
        )
        defer {
            local.processes.forEach { $0.terminate() }
        }
        try await body(local)
    }

    func restartRelay() throws {
        processes[1].terminate()
        processes[1].waitUntilExit()
        processes[1] = try Self.launchRelay(port: Int(relay.port))
    }

    private static func launchRelay(port: Int) throws -> Process {
        try launch(
            ["Tools/satmux/satmux.py", "server", "--host", "127.0.0.1", "--port", "\(port)"],
            environment: ["SATMUX_PSK": keyHex], until: "Listening on"
        ).process
    }

    private static func launch(_ arguments: [String], environment: [String: String] = [:], until marker: String)
        throws -> (process: Process, line: String) {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-u"] + arguments
        process.currentDirectoryURL = repo
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        var seen = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                break
            }
            seen += String(decoding: chunk, as: UTF8.self)
            if let line = seen.components(separatedBy: "\n").first(where: { $0.contains(marker) }) {
                return (process, line.trimmingCharacters(in: .whitespaces))
            }
        }
        process.terminate()
        throw LaunchFailed(output: seen)
    }

    struct LaunchFailed: Error {
        var output: String
    }
}

import Foundation
import SwiftUI

/// The demo app. `DEMO_SERVER_URL` names the server (default the local one, Demo/server/demo_server.py); the launch
/// argument `-reset` starts with an empty outbox, no kept reads and a server that has forgotten everything.
/// `DEMO_AIRPLANE_ORIGIN` names the server as the airplane Wi-Fi section reaches it (`AirplaneModel.Setup`).
@main
struct DurableNetworkingDemoApp: App {
    @State private var model: DemoModel = {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["DEMO_SERVER_URL"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:8787") ?? URL(fileURLWithPath: "/")
        let directory = URL.applicationSupportDirectory.appending(path: "DurableNetworkingDemo")
        return DemoModel(
            server: server, directory: directory, reset: ProcessInfo.processInfo.arguments.contains("-reset")
        )
    }()

    @State private var airplane = AirplaneModel(setup: .from(ProcessInfo.processInfo.environment))

    var body: some Scene {
        WindowGroup {
            DemoView(model: model, airplane: airplane)
        }
    }
}

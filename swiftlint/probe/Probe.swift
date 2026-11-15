// Not built: what swiftlint/hosts.yml must flag (lines 4, 7, 8, 11) and let through (the rest). CI lints it with the
// rules fetched by parent_config from this commit, as a host does.
import Foundation
import Network
// URLSession in a comment is fine
let note = "URLSession in a string is fine"
let bad = URLSession.shared
let config = URLSessionConfiguration.ephemeral
let ok = URLSessionTransport(policy: .quick)
let ok2 = URLSessionStreamingTransport(quietLimit: 3)
let monitor = NWPathMonitor()
func application(_ app: Any, handleEventsForBackgroundURLSession identifier: String) {}
// swiftlint:disable:next no_direct_networking
let allowed = URLSession.shared // the reason
let request = URLRequest(url: URL(fileURLWithPath: "/"))

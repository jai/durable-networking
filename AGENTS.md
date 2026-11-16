# durable-networking

Instructions for agents working in this repo.

## About this repo

See README.md.

Rules for this package:
- Nothing app-specific: no routes, models, hosts or app names. Hosts give it requests, decoders and keys.
- It is the only code in Jai's apps that may touch `URLSession` or Network.framework
  (`swiftlint/hosts.yml`, which hosts take by `parent_config`). A new kind of network use is added here, not
  excepted in a host.
- Swift 6 strict concurrency; iOS 26 / macOS 26.

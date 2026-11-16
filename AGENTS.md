# durable-networking

Instructions for agents working in this repo.

<!-- BEGIN jai/ci standard section -->
## CI, releases and deploys

This repo follows [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md), the
one place for these rules: push to main (no branches or pull requests), main stays green,
release-please releases hourly, the release tag deploys, and what you may run on Jai's
Macs. Read it before you change a workflow, release, deploy or run work on a Mac.
<!-- END jai/ci standard section -->

## About this repo

**Checks:** run `make setup` once per clone, and `make check` before you push.

See README.md.

Rules for this package:
- Nothing app-specific: no routes, models, hosts or app names. Hosts give it requests, decoders and keys.
- It is the only code in Jai's apps that may touch `URLSession` or Network.framework
  (`swiftlint/hosts.yml`, which hosts take by `parent_config`). A new kind of network use is added here, not
  excepted in a host.
- Swift 6 strict concurrency; iOS 26 / macOS 26.
- **Never breaking** (Jai, 2026-11-16: "always latest, never breaking"). Apps take every release automatically, so
  a release must never break one. Add; never remove or change a public signature (a new parameter, even with a
  default, is a change: add an overload). Deprecate instead of removing. CI's `test` job runs
  `swift package diagnose-api-breaking-changes` against the latest `vX.Y.Z` tag and fails on any break, which also
  holds the release. A deliberate break needs Jai's OK first and a major version.

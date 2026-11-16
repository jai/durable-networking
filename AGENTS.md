# durable-networking

Instructions for agents working in this repo.

<!-- BEGIN jai/ci standard section -->
## Shipping (standard for all of Jai's projects)

- **Push to main.** Work on `main` in your own clone or worktree. No feature branches and
  no pull requests. The only pull requests are the ones bots open (release-please);
  they merge themselves once green. Dependabot is off (Jai, 2026-11-15).
- **Land a change:** commit small (Conventional Commits, signed), `git pull --rebase origin
  main`, run this repo's fast checks, push. A push rejected because main moved means
  someone landed first: rebase, run the checks again, push again. Never force-push.
- **Main stays green.** Watch the run for your commit (`gh run watch`). If your push turns
  main red, fixing it is your next task: fix forward, or `git revert` your commit, within
  the hour.
- **Deploy through CI.** For conformance and correctness, production deploys run in the
  repo's deploy workflow. A manual deploy is fine in an exceptional case or when the user
  asks for one.
- **Releases are not yours to cut.** An hourly job tests main's newest commit and releases
  it if it passes. Do not tag or bump versions by hand.
- **Unfinished work** goes behind a feature flag, not on a branch.
- **Parallel agents:** one worktree each, small changes, rebase often.
- **Where CI runs and what you may run on Jai's Macs:**
  [RULES.md in jai/ci](https://github.com/jai/ci/blob/main/RULES.md).
<!-- END jai/ci standard section -->

## About this repo

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

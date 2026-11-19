# CI workflow

The CI workflow for DurableNetworking. Part 1 follows the [pinned standard linked from the cleanup prompt](https://github.com/jai/ci/blob/8c65b2fcdda2257c81eb773f42f227c30ae1ebda/docs/workflow.md). Part 2 is custom to DurableNetworking. Swift package tests run natively on macOS, as the cleanup prompt explicitly permits.

# Part 1: Standard for each repo

## Flow

- [ ] Agents push to `main`.
- [ ] After the push, the release workflows make the release with no person.
- [ ] Standard tools and standard make targets do the work.
- [ ] Shell scripts are bash.
- [ ] Each name says what the thing does: each workflow, make target, hook, script and file.

## Components

- [ ] Each component that ships has its own name, workflows, release tag and version.

## Release candidate (RC)

- [ ] An external clock starts `generate-release-candidate` and nothing more. The GitHub schedule is not reliable.
- [ ] Each repo sets its own clock interval.
- [ ] `generate-release-candidate` sets the next version with semantic versioning, from the conventional commits (git-cliff).
- [ ] It tags the head of `main` as `rc-<component>-v<version>-<short hash>`.
- [ ] One RC for each component at a time. The RC workflow cuts nothing while a release run of that component is queued or running.
- [ ] RC tags stay after the release, as the record of what was tested.
- [ ] The RC tag starts `release`.

## Release

- [ ] `release` runs all tests of that component on the RC commit, through `workflow_call`. The tests run in the release run, so its concurrency group holds until the end.
- [ ] If all tests pass, `release` makes the release tag (`<component>-v<version>`) and the GitHub Release, with release notes from git-cliff.
- [ ] If a test fails, `release` stops. The next RC gets the same version.
- [ ] The job that makes the release tag gets its GitHub App token after the tests, because the token stops after 1 hour.

## Test types

- [ ] Unit: the code only. No app, no simulator, no storage, no network.
- [ ] Integration: one component with its own local storage or local services.
- [ ] UI: the app screens on fixed test data.
- [ ] End-to-end: the deployed system.

## Workflows

| Workflow | Runs on |
| --- | --- |
| `lint-<component>` | Push to the component, and RC |
| `test-unit-<component>` | Push to the component, and RC |
| `test-integration-<component>` | Push to the component, and RC |
| `test-ui-<component>` | RC only (from `release`) |
| `deploy-<component>` | Release tag |
| `lint-workflows` | Push that changes `.github/workflows/**` |
| `generate-release-candidate` | The external clock |
| `notify-update-available` | The external clock, each hour |
| `release` | RC tag |

## Other workflow names

These workflows do not follow the `lint-`, `test-` and `deploy-` names in the Workflows table. They are the only exceptions.

| Workflow | What it does | Why the name is different |
| --- | --- | --- |
| `generate-release-candidate` | Tags the RC | It is part of the release flow, not a check of one component |
| `release` | Tests the RC and makes the release tag | It is part of the release flow, not a check of one component |
| `lint-workflows` | Runs actionlint on the workflow files | The workflow files are not a component |
| `notify-update-available` | Each hour, tells the app the newest build that external TestFlight testers can install, for the "Update available" message | It is for the app users, not a check of one component |

## Make targets

| Target | Runs |
| --- | --- |
| `make lint-<component>` | The same check as the `lint-<component>` workflow |
| `make test-<type>-<component>` | The same tests as the `test-<type>-<component>` workflow |
| `make lint` | All lint targets |
| `make all-tests` | All test targets |

## Git and Claude Code hooks

- [ ] Before each commit, a git hook runs `make lint-<component>` for each component that has staged files.
- [ ] Before each push, a git hook runs `make test-unit-<component>` for each component that the push changes.
- [ ] The git hooks are entries in `.pre-commit-config.yaml`.
- [ ] A Claude Code hook, `.claude/hooks/block-no-verify.py`, stops a `git commit` or `git push` that has `--no-verify`.

## iOS apps

- [ ] The app release tag starts Xcode Cloud. Xcode Cloud only builds the archive and sends it to TestFlight external testers.
- [ ] The unit tests run with `swift test` on Swift packages, with no simulator.
- [ ] Xcode test plans are the only source of the UI tests. Each plan has its full test target and names only the skipped tests, so a new test class runs without a change to a file.

## Update available

- [ ] If the app has an "Update available" message, `notify-update-available` runs each hour from the external clock.
- [ ] It asks App Store Connect for the newest build that the external TestFlight group can install. If that build is new, it writes the version and build where the app reads them.
- [ ] Apple does not report when it approves a build, so the workflow asks each hour. A build shows "Update available" within one hour after Apple approves it.

# Part 2: SDK checks and releases

The cleanup standard was approved for this repository on 2026-11-19. CI changes across all three kits were explicitly authorized by Jai in the kit-owned test migration thread.

## Component and triggers

`sdk` is this repository’s package, versioned by `vX.Y.Z` for SwiftPM. The Swift libraries and relay support form the SDK. The demo apps exercise the SDK and are test consumers, not separately shipped products.

`lint-sdk`, `test-unit-sdk` and `test-integration-sdk` run on changed main commits and through `workflow_call` on each SDK RC. `lint-workflows` checks workflow changes. `test-ui-sdk` runs only from `release`, on iPhone and native macOS. There is no mixed `ci.yml` or release-please lane.

`generate-release-candidate` is started by the external release clock every three hours. It reads conventional commits with git-cliff and tags main as `rc-sdk-v<version>-<commit>`. A queued/running SDK release prevents another candidate. A failed candidate stays recorded; a later fix makes the next candidate. `release` owns its concurrency group until all gates finish. Lint and unit checks start first; integration follows unit success, then full UI follows all cheaper gates. Only then does it obtain publishing credentials and tag the tested commit.

## Test boundaries

- `DurableNetworkingTests` and `DurableNetworkingTestingTests` contain wire, state, retry, deadline and policy logic with scripted dependencies. Deadline and retry waits use an injected clock.
- `DurableNetworkingIntegrationTests` owns the real queue/read-store files and local relay processes. Python template-file and generated-vector comparisons run here too. Network, filesystem, processes and real elapsed-time APIs are banned from the Swift unit folders by SwiftLint.

Native UI plans include complete XCTest targets, with Xcode’s standard retry-on-failure and two iterations. They drive demo screens against controlled data/local hosts. These are UI/component integration checks, not deployed-system E2E checks. This repository does not add deployed E2E tests during cleanup.

## Setup, checks and cleanup

Each job checks out sources, prepares its pinned tools/dependencies and destination or local services, then runs its named checks. Lint includes typechecking/building shipped Swift products and the API compatibility comparison. The lint workflow also compiles both demo consumers, without running UI automation. Hooks format/lint staged files and run the unit target before push; they do not require a full app build.

Native jobs use the dedicated Zoomies Mac pool; desktop UI jobs use `mac-desktop`. Push triggers are restricted to trusted `main`; RC test workflows are called from the repository’s release workflow. No fork pull-request trigger runs on the home lab. Small release/metadata and workflow-lint jobs use hosted Ubuntu runners.

Jobs clean their own `.build`, generated Xcode projects, derived data, Node dependencies and local services. UI jobs create and delete their own simulator, and upload original result bundles/screenshots before cleanup. Toolchain, SwiftPM download, npm and mise caches belong to host maintenance and remain reusable, so net-zero job products does not promise identical host disk usage. Keep diagnostics for seven days; bound host caches between jobs rather than deleting another job’s shared state.

## Commands

- `make lint-sdk`: formatting, static analysis, package build and API compatibility.
- `make lint-workflows`: actionlint.
- `make test-unit-sdk`: isolated Swift tests.
- `make test-integration-sdk`: local storage/service and fixture tests; prepare the local chat host where applicable.
- `make test-ui-sdk PLATFORM=ios SIMULATOR=<owned-id>` or `PLATFORM=mac`: native UI plan against prepared local services.
- `make lint` and `make all-tests`: all corresponding named targets; UI setup remains explicit.

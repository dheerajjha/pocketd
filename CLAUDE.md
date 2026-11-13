# pocketd

pocketd turns an iPhone into a local model server that speaks the Ollama and OpenAI wire formats, inside an iOS app.
`Sources/PocketdKit` is the server and its API, a Swift package with no inference dependency. The app target (`App/`,
generated from `project.yml` by XcodeGen) adds llama.cpp through LocalLLMClient and Apple's FoundationModels.
`CONTRIBUTING.md` holds the rules for routes, the package boundary and capability claims.

## Build and verify
- `make test` runs the package tests in about a second. `make verify` runs them and then compiles the app for a
  simulator, and is what "it builds" means here. `make app` only runs `xcodegen generate`; a green `make app` says
  nothing about whether the app compiles.
- The app needs Xcode 27, because it calls iOS 27 SDK API. Command-line builds pass `-skipMacroValidation`, since
  LocalLLMClient's macro plugin otherwise waits for a "Trust & Enable" click that no headless build can give.
- `make catalogue` checks that every catalogue model URL resolves at its recorded size; the memory-fit badge is
  computed from `sizeBytes`. `make smoke BASE=http://<phone-ip>:11434 KEY=pk-...` exercises a running server on a device.
- CI runs on every push to `main` and every pull request: package tests on macOS 26 and 15, and a simulator build of
  the app on Xcode 27.

## Simulator and device limits
- A simulator gives the app about 722 MB (`os_proc_available_memory()`, which the no-memory-limit entitlements file does
  not change). Only SmolLM2 360M fits, and it is correctly refused tools, so checking that a model calls a tool and the
  tool writes needs a physical device. llama.cpp runs on the simulator's CPU, so simulator speed means nothing.
- `make device-install DEVICE=<udid>` builds Release and stamps `CURRENT_PROJECT_VERSION` with a timestamp, so the
  build on the phone can be identified. Record something as verified on a device only against a build you can name;
  when a claim or a capture depends on exactly which code is running, use a TestFlight build.
- Debug builds started from Xcode load Pocketd Pro from `App/Resources/Pocketd.storekit`. A simulator launched from the
  command line ignores that file; pass `-pocketd.proOverride on|off|early` instead.

## Upload-time rule
App Intent, App Shortcut and Control strings must not name Apple products (iPhone, iPad, Apple Watch, Siri). Nothing
fails locally; Apple rejects the build during processing (ITMS-90626). Before an upload, `grep -i` the built app's
`Metadata.appintents/extract.actionsdata` and the widget extension's.

## What belongs in this repository
It is a public MIT repository that holds only the product. Listing copy, store screenshots, competitor material and the
tooling that builds them live outside the checkout in `../pocketd-store`, and `.gitignore` backstops the usual paths.
`reference/` holds other projects' code fetched by `reference/sync.sh` and is never committed. Commit messages are
plain sentences that say why. Search from the repository root: the laptop server lives in `Sources/PocketdKit/Server`,
outside `App/`. `docs/` publishes through GitHub Pages on every push to `main`.

## Store copy
The listing describes the build on the store, not `main`. The app is iPhone-only, and analytics reporting is on by
default (`optOutTrackingByDefault: false`), so the listing can't claim iPad support or "no telemetry".

# Repository guide for coding agents

## Project context

superuse is a macOS 26+ menu bar utility for screenshots and clipboard history. It is a Swift Package Manager project using AppKit and Apple system frameworks, with no third-party dependencies or backend services.

Read [README.md](README.md) for user behavior and [DEV.md](DEV.md) for build, signing, architecture, and testing instructions. [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) explains design decisions; [docs/VERIFICATION.md](docs/VERIFICATION.md) records earlier checks and remaining manual work. Dated verification notes are not evidence that a new change was tested.

## Setup and validation commands

Use macOS with the full Xcode 27+ toolchain, Swift 6.4, and its macOS SDK. The manifest declares Swift tools 6.0 and a macOS 26 deployment target; guarded macOS 27 APIs still require the newer SDK at compile time.

Run commands from the repository root:

| Command | Purpose |
| --- | --- |
| `swift build --product superuse` | Compile without packaging or a configured signing identity |
| `swift test` | Run all Swift Testing suites |
| `swift test --filter SuseCoreTests` | Run core model, selection, geometry, and stitching tests |
| `swift test --filter SuseAppTests` | Run AppKit integration, layout, and login-item tests |
| `swift test --filter InterfaceLayoutTests` | Run layout checks across supported appearances |
| `./scripts/build-app.sh release` | Assemble and sign `dist/superuse.app` |
| `./scripts/build-app.sh debug` | Assemble a debug app at the same output path |
| `zsh -n scripts/build-app.sh` | Check packaging script syntax |
| `git diff --check` | Check whitespace errors before delivery |

There is no separate dependency-install step, formatter configuration, or CI workflow. Diagnose toolchain issues with `xcode-select -p`, `xcodebuild -version`, and `swift --version`; do not assume Linux can build AppKit targets.

For behavior changes, add or update meaningful regression coverage and run affected suites. Run the full suite for changes spanning shared code or multiple features. For documentation-only changes, validate links, command accuracy, and whitespace; repeat application tests only when the change or new evidence warrants it.

## Architecture and code conventions

- Keep Foundation/CoreGraphics models and algorithms in `Sources/SuseCore/`, isolated from the AppKit lifecycle. The app composition root is in `Sources/Suse/App/`; reusable contracts and helpers are in `Sources/Suse/Shared/`.
- Features in `Sources/Suse/Features/` implement `@MainActor FeatureModule`, expose commands and settings views, and register in `AppCoordinator.configureFeatures()`. Feature implementations must not call one another; shared code must not depend on concrete features.
- Match existing four-space indentation, lowerCamelCase members, UpperCamelCase types, and descriptive test names. Prefer existing helpers and small types over speculative abstractions.
- Keep AppKit calls and UI state on `@MainActor`. Preserve actor-based processing in `ScrollStitcher` and ordered persistence in `ClipboardDisk`. Respect isolation and `Sendable` constraints rather than suppressing checks.
- Preserve task cancellation, single-resume continuations, timer cleanup, and the shutdown sequence that stops features and flushes pending clipboard writes.

## Native UI rules

- Use AppKit for macOS UI. Do not introduce SwiftUI or UIKit for ordinary features or styling changes.
- Reuse `UI`, `ActionButton`, native toolbars, semantic colors, system fonts, tooltips, and accessibility labels. Current app strings are in Simplified Chinese; keep new user-facing copy consistent.
- Use Liquid Glass for floating controls. Keep lists, text editors, settings content, and image canvases readable without glass backgrounds; group adjacent glass controls with `NSGlassEffectContainerView`.
- Guard macOS 27-only APIs with availability checks and preserve macOS 26 behavior. Offscreen layout images do not fully validate glass rendering or actual hover behavior.
- Preserve the screenshot toolbar's anchor when editing controls expand or status text changes.
- The packaged icon comes from `scripts/make-icon-v2.swift`; the menu bar template image lives in `Sources/Suse/Shared/AppIcon.swift`. The older `scripts/make-icon.swift` is not used by the packaging script.

## Compatibility and behavior to preserve

- The product and display name are `superuse`; internal targets remain `Suse` and `SuseCore`. Read display text through `AppIdentity`.
- Preserve bundle ID `app.suse.mac`, existing UserDefaults keys, and `Suse/clipboard-history.json` unless the task explicitly includes a migration. Cosmetic renames must not reset data or system permissions.
- Keep command ID `screenshot.region` for saved shortcut compatibility. Defaults are ⇧⌘A for screenshots, ⌃⌥V for history, and ⌃⌥Space for the toolbox.
- Screenshot selection freezes the desktop, distinguishes clicks from drags, and stays within one display. Review and annotations reuse the overlay. Preserve Retina pixel dimensions and coordinate handling for negative display origins.
- Scrolling capture uses manual downward scrolling and is bounded to 30,000 pixels in height or 48 million pixels.
- Clipboard recording and sensitive-marker filtering default to enabled; persistence defaults to disabled. Preserve the 100-entry default, 50/100/200 choices, 8 MiB item limit, and 32 MiB total across insertion, editing, and restoration.
- Login-item state comes from `SMAppService.mainApp`, not a stored toggle. Opening or refreshing settings must not register the app. `.notFound` allows an explicit registration attempt; errors restore the actual system state. Login launches suppress the toolbox, while manual launches show it.

## Tests and manual checks

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, and `#require`), not XCTest test cases. AppKit suites use `@MainActor` and serialization where needed; preserve that isolation.

Use dedicated test pasteboards, temporary directories, isolated UserDefaults suites, and `LoginItemService` doubles. Never use real clipboard history as test data or register actual login items in automated tests. Cover cancellation, denied permissions, capacity limits, and recovery paths when relevant.

For optional layout previews:

```sh
SUSE_UI_PREVIEW_DIRECTORY="$PWD/.build/ui-previews" swift test --filter InterfaceLayoutTests
```

These render light, dark, and high-contrast layouts without changing system appearance. Use the manual checklist for live capture, actual hover, cross-app paste, multiple displays, accessibility, login, and permission prompts. Distinguish automated checks from manual observations in reports.

## Packaging and signing

Follow [DEV.md](DEV.md#signing-and-packaging) and the [packaging skill](.agents/skills/package-app/SKILL.md). Use `scripts/build-app.sh` for app delivery. Both configurations overwrite `dist/superuse.app`; the default is debug, and the output targets the host architecture.

- Identity precedence is `SIGNING_IDENTITY`, then `.signing-identity.local`. Reuse local configuration; do not overwrite or commit it. The example certificate name is not a bundled identity.
- Missing configuration, invalid certificates, and `SIGNING_IDENTITY=-` must fail. Do not add an ad-hoc fallback or an identifier-only designated requirement.
- Preserve certificate identity, bundle ID, and installation path. Do not recreate certificates or reset system privacy permissions as a routine workaround.
- Before overwriting a running development bundle, quit that exact instance normally so history can flush. Do not terminate unrelated installed copies by process name.
- Verify new bundles as documented in DEV.md. A leftover bundle is not evidence of a successful build. Keep designated requirements and certificate fingerprints out of public reports.
- The script does not notarize or publish releases. Treat distribution signing and notarization as separate work.

## Privacy and public repository hygiene

This repository is public. Keep personal paths, private domains, real clipboard content, screenshots of user data, certificate fingerprints, credentials, and private keys out of source, tests, documentation, commit messages, and reports.

Keep `.build/`, `.swiftpm/`, `dist/`, `.signing-identity.local`, local environment files, signing material, and logs ignored. Use placeholders in examples. Inspect staged content, including image metadata, before publishing; ignore rules do not remove information already tracked or present in history.

Preserve opt-in local persistence, file mode `0600`, directory mode `0700`, and deletion of the saved file when persistence is disabled. History is not encrypted by the app. Retain sensitive-marker filtering and app exclusions without claiming they detect every secret.

Respect macOS screen recording, clipboard, and Accessibility permissions. Direct paste must retain focus, modifier-release, and pasteboard-change checks, with manual-copy fallback on failure.

## Documentation and delivery

- Keep README.md in English and focused on product features, usage, permissions, and user privacy. Put technical setup, signing, architecture, testing, and implementation details in DEV.md.
- Keep AGENTS.md focused on instructions for coding agents. Update it when repository workflows or constraints change.
- Keep changes scoped to the task and preserve unrelated work. When committing, use the existing short `feat:`, `fix:`, `docs:`, or `chore:` subject style.
- Summarize the resulting behavior, checks actually run, and any manual verification that remains. Do not claim CI or hardware coverage that was not performed.

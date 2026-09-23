# Development guide

For features and usage, see [README.md](README.md). Repository-specific instructions for coding agents live in [AGENTS.md](AGENTS.md).

## Stack and requirements

superuse is a Swift Package Manager executable built with AppKit, ScreenCaptureKit, CoreGraphics, Carbon global hotkeys, and ServiceManagement. It uses native Liquid Glass and has no SwiftUI, third-party package dependencies, or backend services.

| Purpose | Requirement |
| --- | --- |
| Run the app | macOS 26 or later |
| Build from source | Full Xcode 27+ installation with Swift 6.4 and the macOS SDK |
| Package a signed app | A usable code-signing certificate and its private key in the Keychain |

The manifest declares Swift tools 6.0 and a macOS 26 deployment target. Source code also references macOS 27 APIs behind availability checks, so use the newer SDK when compiling. The current project has been verified with macOS 27 and Xcode 27 on Apple Silicon.

Check the selected toolchain when diagnosing build failures:

```sh
xcode-select -p
xcodebuild -version
swift --version
```

## Local development

```sh
git clone https://github.com/aiomni/superuse.git
cd superuse
swift build --product superuse
swift test
```

There is no separate dependency-install step. You can also open `Package.swift` in Xcode for editing and debugging. Compilation and tests do not require a configured signing identity.

Use the packaged `.app` to exercise screen recording, permissions, and login-item behavior. The executable produced by `swift build` alone does not provide the complete app bundle and its permission metadata.

## Signing and packaging

The [packaging skill](.agents/skills/package-app/SKILL.md) documents the full app-delivery workflow. Use `scripts/build-app.sh` rather than duplicating its packaging logic.

### Configure an identity

List the usable code-signing identities on your Mac:

```sh
security find-identity -v -p codesigning
```

For a new checkout, copy the template:

```sh
cp .signing-identity.example .signing-identity.local
```

Edit `.signing-identity.local` to contain the SHA-1 fingerprint or full name of an available identity. Prefer a fingerprint when multiple certificates have the same name. Preserve any existing local configuration.

The template's `Suse Local Development` value is an example certificate name; copying it does not create a certificate. For local use, create or reuse a self-signed Code Signing certificate through Keychain Access's Certificate Assistant, or use an existing Apple Development identity. Reuse the same certificate for later builds.

The environment variable `SIGNING_IDENTITY` takes precedence over the local file. Replace the placeholder below with your own identity:

```sh
SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/build-app.sh release
```

### Build a bundle

After configuring a signing identity:

```sh
./scripts/build-app.sh release
open dist/superuse.app
```

The script compiles the `superuse` product, copies `Resources/Info.plist`, generates the icon with `scripts/make-icon-v2.swift`, creates the bundle, signs it, and verifies its signature.

Pass `debug` for a debug build. Omitting the argument also selects debug. Both configurations write to `dist/superuse.app` and build the host architecture, not a Universal binary automatically.

> [!IMPORTANT]
> Packaging fails for missing configuration, an unavailable certificate, or `SIGNING_IDENTITY=-`. It must not fall back to ad-hoc signing. Keep the signing certificate, bundle ID, and installation path stable to preserve system permission identity. A certificate with the same name is not necessarily the same signing identity.

Quit the exact development instance before overwriting its bundle so pending history writes can finish. For regular use, install the app at a stable path such as `/Applications/superuse.app`.

Verify newly generated output:

```sh
plutil -lint dist/superuse.app/Contents/Info.plist
codesign --verify --deep --strict dist/superuse.app
file dist/superuse.app/Contents/MacOS/superuse
```

When investigating signing changes, inspect the designated requirement locally with `codesign -d -r- dist/superuse.app`. Redact certificate fingerprints before sharing the output. Do not treat a leftover bundle as evidence that a failed build succeeded.

Switching from an ad-hoc signature or changing certificates can require reauthorizing the installed app for screen recording. Do not routinely reset system permissions or recreate certificates to fix a build. Distribution to other Macs uses Developer ID signing and notarization; the script does not notarize or publish releases.

## Architecture

| Location | Responsibility |
| --- | --- |
| `Sources/SuseCore/` | Clipboard models, shortcut values, capture selection, screen geometry, and scrolling stitcher |
| `Sources/Suse/App/` | Composition root, lifecycle, menu bar, toolbox, settings, and login items |
| `Sources/Suse/Shared/` | Feature contracts, shortcut registration, settings, app identity, icons, and AppKit helpers |
| `Sources/Suse/Features/Clipboard/` | Clipboard polling, persistence, history panel, and direct paste |
| `Sources/Suse/Features/Screenshot/` | Screen acquisition, selection overlays, review, annotations, and scrolling capture |
| `Sources/Suse/Features/Pins/` | Session snapshots, floating image/text panels, visibility, and Pin management |
| `Tests/SuseCoreTests/` | Model, coordinate, selection, and stitching tests |
| `Tests/SuseAppTests/` | AppKit integration, layout, and login-item tests |
| `scripts/` | App packaging and icon generation |
| `Resources/` | Bundle metadata and icon assets |

Features implement `@MainActor FeatureModule`, expose `AppCommand` values and settings views, and are registered in `AppCoordinator.configureFeatures()`. They own their state and services independently. Feature implementations do not call one another, and the shared layer does not depend on concrete features.

The composition root injects the shared `PinPresenting` contract into screenshot and clipboard modules. `PinsModule` owns `PinStore` and `PinWindowController` instances; screenshots and clipboard history never access those concrete types. Pin management has no default global shortcut. `AppCommand.defaultShortcut` may be nil, while saved shortcut overrides and disabled states retain their existing behavior.

Pin snapshots live only in memory. Text Pins edit their own snapshot through validated `PinStore.updateText` calls, leaving the source history entry unchanged. Each text view has its own native undo manager (up to 50 undo groups); typing, plain-text paste, and IME updates retain native selection and undo state. Editing replaces the previous allocation, including at the window-count limit, and may leave an empty note. Preflight rejects edits that exceed the shared content budget, with a last-accepted-value fallback for changes that bypass preflight. The editor uses the injected pasteboard for copy, cut, and paste, including context-menu actions. Clipboard Pin reads the selected entry directly, without copying it through the system pasteboard. Screenshot Pin uses `AnnotationCanvas.renderedImage()` and completes only after the snapshot is accepted. Screenshot crops are detached from their parent display bitmap so a small Pin does not retain a full frozen desktop. Encoded clipboard images are checked for dimensions and estimated decoded size before decoding. The content budget is separate from clipboard-history limits and does not represent a hard ceiling on process RSS, undo history, or transient render buffers.

Pin panels use `.floating`, `.nonactivatingPanel`, `.canJoinAllSpaces`, and `.fullScreenAuxiliary`. Their native titled windows and `NSToolbar` follow Preview: the visible title is hidden, Copy and More remain available, and an `NSToolbarItemGroup` for zoom appears at widths of 480 points or more. Smaller windows access zoom directly through More rather than a nested toolbar overflow menu. AppKit supplies the toolbar glass; the centered image canvas and editable plain text remain outside glass. Short text notes size to their content, and image layout clamps scroll offsets after resizing to preserve canvas margins. The menu bar provides an independent recovery path for `ignoresMouseEvents`. Capture suppression uses scoped tokens separately from per-item hidden state: every screenshot exit resumes its token, including cancellation and errors. A new Pin created during capture becomes visible after the overlay closes. Explicit history removals close associated Pins; eviction and editing do not. Shutdown closes panels and releases snapshots without writing them to disk.

AppKit state lives on the main actor. `ScrollStitcher` handles image processing in an actor, and `ClipboardDisk` serializes persistence using revision numbers. Shutdown stops feature activity and awaits pending clipboard writes.

Screenshot selection uses a frozen desktop image. `CaptureSelectionState` handles hit testing and click-versus-drag behavior; `SelectionController` owns the overlays; `CaptureReviewController` handles in-place editing and export. Both control bars keep their anchor when annotations or status text change.

`CapturePixelSampler` maps Quartz display coordinates to snapshot pixels and converts a single pixel to sRGB with a reusable bitmap context. `CaptureLoupeView` magnifies the frozen source without interpolation, centers the sampled pixel even at display edges, and passes mouse events through to selection. Each selection session shares its RGB/HEX/HSL format across displays. `SelectionWindow` routes Shift and Command-C to the hovered display during selection; these handlers stop when the selection freezes, preserving review and text-editing shortcuts. The loupe and selection border never enter the exported image.

Screenshot controls use native accessory-bar buttons with persistent bezels on a dark Liquid Glass surface, including the matching high-contrast appearance. Main actions stay in one row; dimensions and copy/save feedback appear in a separate badge near the selection. Annotation tools are always visible and the canvas accepts drawing immediately. Scrolling capture is disabled only while annotations remain; undoing or clearing all annotations restores it.

`MosaicFilter` in `SuseCore` downsamples the source image and existing annotations into small tile bitmaps. Each mosaic annotation keeps its bitmap and draws it without interpolation inside its rectangle, preserving the original export dimensions and earlier redactions. Solid redaction remains a separate tool. Mosaic areas have an opaque backing, including when the source has transparency or tile allocation fails.

`SelectionWindow` routes screenshot shortcuts before the focused canvas or control consumes key events. Esc cancels the session, and the review's native button key equivalents provide undo and redo using the canvas's existing undo manager. Attached sheets and text responders retain their own shortcut handling.

Use native AppKit controls and semantic colors. Liquid Glass belongs to floating controls; content, lists, and text editors retain readable backgrounds. The packaged icon is generated by `scripts/make-icon-v2.swift`; the menu bar template image is drawn by `AppIcon.swift`. The older `scripts/make-icon.swift` is not used by the current packaging script.

### Compatibility and limits

The product is named `superuse`, but Swift targets remain `Suse` and `SuseCore`. Preserve bundle ID `app.suse.mac`, existing UserDefaults keys, and the `Suse` application-support directory to retain data and authorization identity.

The screenshot command keeps ID `screenshot.region` so existing shortcuts and disabled states survive the earlier feature consolidation. Display text reads the app name through `AppIdentity`.

Clipboard history defaults to 100 entries, with 50/100/200 choices, an 8 MiB per-entry limit, and a 32 MiB aggregate limit. Insertion, restoration, and editing enforce these bounds. Scrolling capture is limited to 30,000 pixels in height or 48 million pixels and preserves original image pixels in accepted strips.

Login-item state comes from `SMAppService.mainApp`. Opening settings does not register the app. An initial `.notFound` still allows an explicit registration attempt; failures restore the actual system state, and required approval is handled through System Settings. Login launches suppress the toolbox, while manual launches show it.

## Tests and UI verification

```sh
swift test
swift test --filter SuseCoreTests
swift test --filter SuseAppTests
swift test --filter InterfaceLayoutTests
```

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, and `#require`). AppKit suites use main-actor isolation and serialization where needed. Tests use dedicated pasteboards, isolated UserDefaults suites, temporary files, and login-item service doubles; they do not read real clipboard history or register real login items.

Coverage includes bounded history, sensitive markers, persistence deletion, pixel-level stitching, selection and coordinate conversion, annotation export, anchored toolbar layout, and login-item recovery. Check `swift test list` for the current test inventory instead of relying on a fixed test count.

Pin tests cover snapshot independence, count and decoded-memory limits, nested capture suppression, early screenshot cancellation without permission requests, annotated Pin exports, clipboard deletion versus eviction, selection copying, image copies after scaling, click-through recovery, and window cleanup. `PinGeometryTests` covers negative display origins and recovery after display removal. Pin layout checks include minimum-size windows in all four supported appearances. Tests use dedicated pasteboards and temporary persistence URLs, and keep Pin windows offscreen; real focus, drag, window-server glass, and full-screen behavior require manual checks.

Generate optional layout previews:

```sh
SUSE_UI_PREVIEW_DIRECTORY="$PWD/.build/ui-previews" swift test --filter InterfaceLayoutTests
```

The layout tests render light, dark, and high-contrast appearances without changing system appearance. Offscreen rendering cannot fully reproduce window-server glass effects, actual hover, or system permission flows.

Use [docs/VERIFICATION.md](docs/VERIFICATION.md) for manual checks of live capture, scrolling, multiple displays, cross-app paste, login items, and accessibility. The [implementation notes](docs/IMPLEMENTATION.md) provide additional architectural context. Both documents are currently in Chinese.

There is no configured CI workflow or formatter. For script or documentation changes, relevant checks include:

```sh
zsh -n scripts/build-app.sh
git diff --check
```

## Privacy and public repository hygiene

Clipboard persistence is disabled by default. Enabling it writes to `~/Library/Application Support/Suse/clipboard-history.json` with mode `0600`; the created directory uses `0700`. Disabling persistence deletes the saved file while preserving in-memory entries. The app does not encrypt the history file.

Sensitive filtering respects concealed, transient, autogenerated, and password-manager pasteboard markers. It cannot identify every secret. Keep application exclusions, permission checks, and direct-paste focus, modifier-release, and pasteboard-change checks intact.

This is a public repository. Keep local signing configuration, environment files, certificates, private keys, logs, and build output ignored. Build output can contain absolute machine paths and signing information. Never include private paths, certificate fingerprints, real clipboard content, or screenshots of private data in source, tests, documentation, or reports.

Inspect staged content before committing, including image metadata. Ignore rules do not remove data already tracked or stored in Git history. Use synthetic data and placeholders for examples and verification.

Keep [README.md](README.md) focused on English user-facing documentation. Put build, signing, architecture, testing, and implementation details in this file; put agent-specific rules in [AGENTS.md](AGENTS.md).

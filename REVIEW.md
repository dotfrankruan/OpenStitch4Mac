# Independent code review — OpenStitch for Mac vs. the iOS original

Reviewer: code-reviewer (independent, read-only on sources). Date: 2026-10-27.
Baseline: `1069e27` (`feat: port OpenStitch to a native macOS SwiftUI app`).
Reference spec: `/Users/frankruan/Code/OpenStitch` (README, `ImageStitcher.swift`, `ContentView.swift`,
`ResultView.swift`, `ImageStitcherTests.swift`).

Scope of this review: functional parity of the stitching engine, CoreGraphics/concurrency correctness,
macOS UX/native behaviour, project/build sanity, and independent execution (clean build, full test run,
launch + window inspection, standalone engine/loader experiments).

Verdict: **no blockers found.** The engine is a faithful, line-by-line port and the happy path is correct
and verified. Two majors: the preview of tall results degrades to a narrow strip, and Finder "Open With"
is not registered because the bundle declares no document types. Everything else is minor/nit.

---

## Findings, severity-ranked

### MAJOR-1 — Tall results preview as a narrow strip instead of fit-to-width
Files: `OpenStitch/Views/ResultView.swift:169-181` (preview generation), `:42-57` (display sizing),
`OpenStitch/Stitching/ImageLoader.swift:84-106` (`downscaled`).

`prepare()` renders the on-screen preview with `ImageLoader.downscaled(image, maxDimension: 6000)`, i.e. it
caps the **longest edge**. For a long screenshot the longest edge is the height, so the preview's *width*
shrinks by `6000 / height`. The view then does `scale = min(1, fitWidth / preview.width)`, which never
upscales, so a preview narrower than the sheet is shown at its native (small) width, centred with large
empty margins.

Why it matters: this is the app's primary output view. Any result taller than ~8,300 px (≈3.2 iPhone
screens) starts shrinking; realistic multi-screen results become a thin, unreadable strip.

Measured (sheet fit width = 900 − 48 = 852 pt, source width 1179 px):

| Result height | Preview | Displayed width |
|---|---|---|
| 4,200 px | 1179 × 4200 | 852 pt (fills) |
| 6,000 px | 1179 × 6000 | 852 pt (fills) |
| 8,300 px | 852 × 6000 | 852 pt (boundary) |
| 10,000 px | 707 × 6000 | 707 pt |
| **13,218 px (verified in the running app)** | **581 × 6000** | **581 pt** |
| 20,000 px | 354 × 6000 | 354 pt |
| 60,000 px (engine limit) | 118 × 6000 | 118 pt |

The 13,218 px row was reproduced by launching the built app with ten 1280×1500 overlapping screenshots
(`OPENSTITCH_AUTOSTITCH=1`, result reported as `1,280 × 13,218 px · 10 screenshots`); the preview occupied
roughly two-thirds of the available width with empty margins on both sides.

Secondary issue in the same code: previews are generated in *pixels* but displayed in *points*. On a 2×
display, a 1,179 px preview shown at 852 pt is upscaled 1.45×, so even the "fills" cases are soft.

Suggested fix: generate the preview from the *display* geometry, not a generic long-edge cap. E.g. compute
`targetWidth = min(image.width, fitWidth * 2)` and cap total pixels (or height) rather than the long edge;
then in the view use `scale = fitWidth / preview.width` (no `min(1)`) so the image always fills the width,
relying on `.interpolation(.high)` for the (rare) extreme-tall case; for results near the 60,000 px limit,
render a fit-width tiled/segmented preview instead of one texture. A cheap partial fix that removes the
strip for all realistic results: cap by width and allow upscaling — never let the preview's width fall
below the display width.

### MAJOR-2 — Finder "Open With" / Dock drop is not registered (no document types in Info.plist)
Files: `OpenStitch.xcodeproj/project.pbxproj:319-336` (generated Info.plist keys), `OpenStitch/AppDelegate.swift:35-39`
(`application(_:open:)`), built `Info.plist`.

The app implements `application(_:open:)` and a command-line hook, and the port claims Finder/command-line
open support, but the bundle declares **no `CFBundleDocumentTypes`/`LSItemContentTypes`**. Verified on the
built product: `plutil -p …/Info.plist` has no document-type keys, and the LaunchServices record for
`com.frankruan.OpenStitchMac` has no claimed UTIs/bindings. Consequences: PNGs/HEICs are not offered
"Open With → OpenStitch" in Finder, the app cannot be made a default handler, and dragging a file onto the
Dock icon does not hand the file to the app. Only `open -a <path>` and the debug command-line path work;
drag-into-window and the file importer are unaffected.

Suggested fix: ship a real `Info.plist` (keep `GENERATE_INFOPLIST_FILE = YES` for the generated keys, or set
`INFOPLIST_FILE` to a checked-in plist) containing `CFBundleDocumentTypes` for `public.image`
(`LSHandlerRank = Alternate`, `CFBundleTypeRole = Viewer`) plus `LSItemContentTypes = [public.image]`.
Also worth adding `CFBundleTypeExtensions` for png/jpg/jpeg/heic/tiff.

### MINOR-1 — Total screenshot count is unbounded (cap only applies per import)
Files: `OpenStitch/Model/StitchWorkspace.swift:35`, `:64-67`, `:156-168`.

`maximumSelectionCount = 20` is applied to each `add(urls:)` batch only; repeated imports can grow
`screenshots` without limit (iOS replaces the whole list on each picker selection, so its 20 limit is
effectively total). `stitch()` then decodes every full-resolution image at once and additionally allocates
the up-to-60,000-px-tall output context, so a user who imports 20 files five times can push the stitch
toward ~1 GB+ of live bitmaps and fail with `renderingFailed`/memory pressure rather than a clear error.
Fix: enforce a total cap (e.g. 20, matching the README) when appending, or reject/ask to trim; wrap
per-image loads in `autoreleasepool` and consider releasing source images after the render.

### MINOR-2 — `NSSavePanel.runModal()` from inside the result sheet
File: `OpenStitch/Stitching/ImageExporter.swift:21`.

The save panel is run app-modally on top of a SwiftUI sheet. It works, but it is not a native sheet, can
produce nested-modal oddities, and blocks the run loop. Prefer
`panel.beginSheetModal(for: NSApp.keyWindow ?? window)` with a completion handler, or present the save
panel from the main window instead of the sheet.

### MINOR-3 — Import order is not guaranteed to be the user's selection order
Files: `OpenStitch/Views/ContentView.swift:23-34` (`fileImporter`), `:58-63` (drop).

iOS uses `PhotosPicker(selectionBehavior: .ordered)`, preserving click order. `NSOpenPanel`/`.fileImporter`
returns the selection in display order (typically name order), so "select in top-to-bottom order" only works
if the filenames happen to sort correctly. The UI does explain ordering and offers drag/arrow reordering, so
this is a documented, mitigated gap rather than a bug; consider noting it in the empty state/help, or
sorting dropped files by name for predictability.

### MINOR-4 — Import can race with stitching and can blank an already-presented result sheet
Files: `OpenStitch/Model/StitchWorkspace.swift:48-113`, `:100-108`; `OpenStitch/Views/ContentView.swift:35-39`;
`OpenStitch/OpenStitchApp.swift:18-23`.

`add(urls:)` does not check `isBusy` and always sets `result = nil`. The File-menu "Add Screenshots…"
command is not disabled while busy, and a drop can arrive while the result sheet is up. Outcomes: a stale
sheet with no content (`if let result` fails while `isShowingResult` is true), or an import that completes
after a stitch and clears the just-produced result. Fix: guard `add` on `isBusy`, clear `isShowingResult`
when clearing `result`, and disable import commands while busy.

### MINOR-5 — Accessibility gaps on icon-only controls and the preview
Files: `OpenStitch/Views/ScreenshotRow.swift:43-62`, `:25`; `OpenStitch/Views/ResultView.swift:48`.

The up/down/trash row buttons are icon-only and carry `.help(...)` but no `.accessibilityLabel`, so
VoiceOver may announce only "button" (`.help` is a tooltip, not an accessibility label). The result preview
uses `Image(decorative:)` with no `.accessibilityLabel`, so the main output has no description. Add
`.accessibilityLabel("Move screenshot \(index + 1) up")` etc. and an image description including dimensions.

### MINOR-6 — Temporary PNG lifecycle vs. ShareLink / Open in Preview
Files: `OpenStitch/Views/ResultView.swift:169-187`, `OpenStitch/Stitching/ImageLoader.swift:131-136`.

A temp PNG is written on every result presentation (even if the user only copies), and it is deleted in
`onDisappear`. For a 60,000-px result this is a large encode/temp file on every view, and deleting the file
while a share/Preview session may still reference it can break the hand-off. Prefer writing lazily when
Share/Preview is first used, keeping the file until the next result (or app quit), or using
`NSItemProvider`/`NSWorkspace` with a file the system can own.

### MINOR-7 — No sandbox/security-scoped handling; ad-hoc, non-distributable build
Files: `OpenStitch.xcodeproj/project.pbxproj:319-336`; `OpenStitch/Stitching/ImageLoader.swift:50-75`.

The app is currently unsandboxed (`ENABLE_APP_SANDBOX` absent, no entitlements file), so reading
fileImporter/drag URLs works. If the app is ever sandboxed or hardened for distribution, every URL from
`fileImporter`/`.dropDestination` must be wrapped in `startAccessingSecurityScopedResource()`/
`stopAccessing…` or imports will fail. The build is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`,
`ENABLE_HARDENED_RUNTIME = NO`), which is fine for local use but not distributable — state this in the
README. (Not a current bug.)

### MINOR-8 — Test coverage gaps for the new macOS-specific code
Files: `OpenStitchTests/QAExtraTests.swift` (currently a no-op placeholder, modified concurrently by the QA
pass during this review), `OpenStitchTests/ImageStitcherTests.swift`.

The engine has good tests (7, ported and extended with order/normalisation/too-tall cases). There are no
tests for `ImageLoader` (EXIF orientation handling, full-resolution load, `downscaled`, PNG round-trip,
`isSupportedImage`), no test at/near the 60,000 px limit, and no test for the preview-scaling math that
MAJOR-1 breaks. I exercised those paths with standalone harnesses (below); they should be turned into unit
tests.

### MINOR-9 — No README in the macOS repo
The iOS original has a README; the macOS repo has none. Build/run/test commands, the feature set, the
deliberate deviations from iOS, the shortcuts (⌘O, ⌘↩, ⌘E, ⇧⌘⌫, Esc, ⌘S), the 20-image/60,000-px limits, and
the "not notarised / local use" caveat should be documented.

### NIT-1 — `SendableImage` / `SendableBox` are unnecessary; comments are inaccurate
File: `OpenStitch/Stitching/ImageLoader.swift:6-16` (also used in `StitchWorkspace.swift:82`, `:158-168`,
`ResultView.swift:171-177`).

The current SDK declares `extension CGImage : @unchecked Sendable`, so `CGImage` already crosses
`Task.detached` boundaries and `StitchResult` is implicitly `Sendable`. The wrappers are harmless but the
comment ("it simply is not annotated Sendable by the SDK") is wrong for this toolchain (Swift 6 build
succeeds without them). Either remove them or correct the comment.

### NIT-2 — Misleading comment in `loadImage`
File: `OpenStitch/Stitching/ImageLoader.swift:71-74`. The comment says thumbnails "can overshoot slightly
when the source is small", but no clamping is done (and none is needed when `maxPixelSize == fullSize`).
Remove or fix the comment.

### NIT-3 — Background-fill deviation from iOS is deliberate and justified
File: `OpenStitch/Stitching/ImageStitcher.swift:114-116`, `:129-130`.

iOS fills with `UIColor.systemBackground` (black in dark mode); the port always fills white. In practice the
tiles cover the canvas completely (overlap rounding can only duplicate rows, never leave gaps), so the fill
is only visible for alpha-bearing inputs; white is the more predictable choice for screenshot content. Keep
it, but note it in REVIEW/README as a deliberate deviation. Same for `CGImage`/`CGContext` instead of
`UIImage`/`UIGraphicsImageRenderer`, file import instead of `PhotosPicker`, and save panel instead of
Photos — all justified and correctly implemented.

### NIT-4 — Duplicate ⌘↩ key equivalent on the menu command and the bottom-bar button
Files: `OpenStitch/OpenStitchApp.swift:24-29`, `OpenStitch/Views/ContentView.swift:155-165`.

The same shortcut is declared twice. Usually the menu wins and the button shortcut is inert, but when the
menu item's validation is stale/disabled (see "not verified" below) the duplicate can swallow the shortcut.
Declaring it once (menu command only, button without shortcut) is cleaner.

### NIT-5 — Debug-only verification hook in production source
File: `OpenStitch/Views/ContentView.swift:232-239`. The `OPENSTITCH_AUTOSTITCH` hook is `#if DEBUG`-guarded
and useful for automated verification, but should be mentioned in the README or moved to a test target.

---

## Feature parity table (iOS → macOS)

| iOS feature | macOS implementation | Status |
|---|---|---|
| Import 2–20 screenshots via PhotosPicker, ordered | `fileImporter([.image], multiple)` + per-import cap of 20 (`ContentView.swift:23-34`, `StitchWorkspace.swift:35`) | Partial — order not guaranteed, total count not capped (MINOR-1/3) |
| Preserve order; move up/down; delete | `List` drag reorder + arrow buttons + trash per row (`ContentView.swift:108-130`, `ScreenshotRow.swift`) | Full |
| Automatic adjacent-overlap detection | Identical engine, identical constants (analysisWidth 144, 0.08/0.92 bounds, 0.105 threshold, 0.08 inset, 0.9 row trim, 2e-6 length bias) | Full — parity verified line-by-line and by execution |
| Normalise differing widths to first image's width | Identical math, CGContext renderer (`ImageStitcher.swift:99-120`) | Full |
| Stitched long-image preview | Result sheet with scrollable preview (`ResultView.swift`) | Partial — tall results preview as a narrow strip (MAJOR-1) |
| Save to Photos | `NSSavePanel` PNG export, full resolution (`ImageExporter.swift:12-26`) | Equivalent (justified deviation) |
| System share sheet | `ShareLink(item: tempPNG)` + Copy to clipboard + Open in Preview (`ResultView.swift:93-130`) | Equivalent, superset |
| Explicit error for unmatchable images / unreadable files / too tall | Same `StitchError` cases and user-facing strings, plus import alerts | Full |
| 20-image and 60,000-px limits | 60,000 px enforced (`ImageStitcher.swift:88-90`); 20 only per import | Partial (MINOR-1) |
| Only "add to Photos" permission, no library read | N/A — no photo-library access at all | Better (justified) |
| Everything processed on-device | No networking code anywhere in the target | Full (verified by reading) |
| Photos permission-denied message | N/A | N/A |

---

## What I verified by execution

Environment: Xcode 27 / macOS 27 SDK, macOS 26 host. Derived data: `.review-build/` (git-ignored).
Commands from the task brief, verbatim.

1. **Clean build** — `xcodebuild … -derivedDataPath .review-build CODE_SIGNING_ALLOWED=NO build`:
   `BUILD SUCCEEDED`, exit 0. Only warning: `Metadata extraction skipped, no AppIntents.framework dependency
   found` (benign, AppIntents unrelated). No Swift concurrency warnings under `SWIFT_VERSION = 6.0`.
2. **Full test run** — `xcodebuild test … -destination 'platform=macOS'`: `TEST SUCCEEDED`, 8 tests
   (7 `ImageStitcherTests` + the then-placeholder `QAExtraTests.testPlaceholder`), 0 failures, 1.79 s.
   Note: `QAExtraTests.swift` was being modified concurrently by the QA teammate during this review.
3. **Built product inspection** — `Info.plist` has `CFBundleIdentifier com.frankruan.OpenStitchMac`,
   `LSMinimumSystemVersion 14.0`, icon keys; `AppIcon.icns` present; ad-hoc/linker-signed, no entitlements,
   no document types. `lsregister` record shows no claimed UTIs (MAJOR-2 evidence). Shared scheme exists and
   wires the test target correctly (`TEST_HOST`, `BUNDLE_LOADER`, target dependency, `TestTargetID`).
4. **App launch / window behaviour** — launched `.review-build/…/OpenStitch.app/Contents/MacOS/OpenStitch`
   directly (own instances, quit after use; the Lead's concurrently-running instance was not touched).
   `CGWindowList` helper: **exactly one main window per instance**, 980×720, title "OpenStitch"; the result
   sheet is the only extra window. Captured and inspected: empty state (dark mode, centred
   ContentUnavailableView, "Choose Screenshots…" + drag hint), 2-screenshot list (thumbnails, filenames,
   dimensions, arrows/trash, "Stitch 2"), and the result sheet for a 10-screenshot tall stitch
   (1,280 × 13,218 px, overlaps 195–204 px) — which is where MAJOR-1 was reproduced visually.
5. **Menu structure** — read via System Events: File menu contains "Add Screenshots…" with ⌘O and no
   "New Window" (single-window design holds); a "Stitch" menu exists with "Stitch Screenshots", "Show
   Result", "Clear Screenshots"; Window menu has no "New Window".
6. **Standalone engine harness** (`swiftc -O -swift-version 6` with the unmodified engine sources):
   - 3-image stitch: 240×980, overlaps `[140, 140]`, height math exact.
   - Orientation/flip: stitched row 0 equals first image's top row; last row equals third image's bottom row
     — confirms the bottom-left-origin mirroring in `render` is correct.
   - `notEnoughImages` for 1 image; `noOverlap(0)` for unrelated images; `resultTooTall` with a reduced limit;
     width normalisation (480-wide second image → 240-wide output, overlap ~140); 1-px images rejected
     cleanly.
7. **Standalone loader harness**: EXIF orientation 6 JPEG (400×200 raw) → `metadata` 200×400 and
   `loadImage` 200×400 (transform applied, width/height swap correct); full-resolution PNG load returns exact
   1280×4200; PNG write→read round-trip; `isSupportedImage` true for png/jpg/heic/tiff/gif, false for
   pdf/txt/no-extension; temp PNG creation/removal; preview downscale/fit math reproduced numerically
   (MAJOR-1 table).

## What I verified by reading only (not executed)

- Keyboard shortcuts/menu command behaviour: two concurrently running OpenStitch instances (mine and the
  Lead's, same bundle id) made synthetic keystrokes unsafe to target; AX `enabled` states read from a
  non-frontmost app are unreliable. **Risk worth a manual check:** whether the `.commands` menu items
  re-validate against the `@Observable` workspace (if they do not, "Stitch Screenshots" could stay disabled
  and swallow ⌘↩). The menu structure itself was confirmed.
- End-to-end save panel, clipboard copy, `ShareLink`, Open in Preview.
- Drag & drop from Finder (code path and `.dropDestination(for: URL.self)` usage read; not exercised).
- VoiceOver/accessibility output; light-mode appearance (only dark mode was captured); window-close → Dock
  reopen behaviour of the single `Window` scene; sandboxed operation.

## Engine parity detail (line-by-line, iOS → macOS)

Identical: configuration defaults; normalisation target (first image's pixel width) and rounded height;
`GrayImage` analysis width 144, height rounding, device-gray context, 8 % horizontal inset, 8 % min / 92 %
max overlap bounds, `min - 1` clamp, mean absolute row difference / (count·255), 0.9 row trim, `2e-6` per-row
length bias, `maximumDifference 0.105` acceptance, overlap pixel scaling by
`imageHeight / analysisHeight` and rounding, output-height formula, 60,000 px limit, error cases/messages.
The macOS-only differences are the `CGImage`/`CGContext` types, the explicit bottom-left→top-down mirroring
in `render` (correct, and verified by row comparison), an added `outputHeight > 0` guard (improvement), and
the white background fill (deliberate, justified). I found no behavioural divergence in the engine.

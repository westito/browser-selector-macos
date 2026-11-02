# BrowserSelector

macOS browser chooser. Registered as the default handler for `http`/`https`; when a link is opened it
shows a popup at the mouse cursor listing Safari first, then every Google Chrome profile (picture,
name, account e-mail, highlight color), opens the link in the chosen one and quits. No dock icon, no
menu bar item, no window (`LSUIElement` + `.accessory` activation policy).

## Product decisions (made by the user — do not change without asking)

- Browser list is **Safari + Chrome profiles only**. No other browsers, no other Chromium browsers.
- **Every link launch refreshes asynchronously.** The popup opens immediately from the cache, a
  background scan runs, and the open list updates in place when it finishes. A link launch with no
  cache does one blocking scan instead. The app does not quit until the refresh has finished (bounded
  by the 15 s termination timer), so the cache is updated even when the user picks quickly.
- An **incomplete scan** (Chrome installed but `Local State` unreadable — Chrome rewrites it while
  running) must never replace a good list: it is not pushed into the popup and not saved over an
  existing cache. Only a direct launch or a cache-less first scan may degrade to Safari only.
- The popup ends with a **Copy Link** row (arrow keys, Return, `c`, ⌘C) that copies the URL(s) as
  newline-separated plain text and quits.
- Launching without a URL rescans, offers to become the default browser, shows one summary `NSAlert`
  (the only window the app ever shows), then quits.
- `CFBundleURLTypes` registers **only http and https**. Do not add schemes; any URL the system hands
  to the app (e.g. `file://`) must simply be opened in the chosen browser.

## Layout

All sources are in `BrowserSelector/` (file-system-synchronized group — new `.swift` files are picked
up automatically, no pbxproj edit needed).

| File | Role |
| --- | --- |
| `main.swift` | AppKit entry point (no SwiftUI `App`/`Scene`, so no window can ever open) |
| `AppDelegate.swift` | URL intake, link flow vs. direct-launch flow, background refresh, copy, termination gating, default-browser registration |
| `BrowserEntry.swift` | Codable, `Sendable` model; `colorARGB` is Chrome's signed 32-bit ARGB |
| `BrowserDiscovery.swift` | Synchronous, thread-safe scan: Safari + Chrome `Local State` → `profile.info_cache`; returns `ScanResult { entries, isComplete }` |
| `BrowserStore.swift` | Cache in `~/Library/Application Support/BrowserSelector/` (`browsers.json`, `icons/*.png`); main-actor icon memo |
| `BrowserLauncher.swift` | Opens URLs; completion-based |
| `PickerPanelController.swift` | Borderless key-able `NSPanel` at the cursor, live resize on update, dismissal (`pick` / `copy` / `cancel`) |
| `PickerView.swift` | `@Observable PickerModel` + SwiftUI popup; keys ↑/↓, Return, Esc, 1–9, `c`/⌘C |

`Info.plist` lives at the **repo root**, not in `BrowserSelector/`: inside the synchronized group it
gets copied into Copy Bundle Resources and triggers a build warning. `INFOPLIST_FILE = Info.plist`
with `GENERATE_INFOPLIST_FILE = YES` — Xcode merges both.

## Constraints and gotchas

- **App Sandbox must stay off** (`ENABLE_APP_SANDBOX = NO`). The sandbox blocks reading Chrome's
  `Local State` and launching other apps. The Xcode template had it on.
- **Never terminate before the launch completes.** `NSWorkspace.open` is asynchronous; quitting right
  after it cancels the request. `http` usually survives the race, `file://` (delivered as a document)
  does not. Every exit (pick, copy, cancel) goes through `requestTermination()`, which quits only once
  no launch and no background refresh is in flight (`terminateIfIdle()`), with a 15 s hard timer.
  Do not call `NSApp.terminate` directly from the picker paths.
- **Chrome profiles** are opened with `/usr/bin/open -n -b com.google.Chrome --args
  --profile-directory=<dir> <urls>`. It is the only way that honours the profile while Chrome is
  already running; the NSWorkspace APIs cannot express it.
- **http and https are one "default browser" setting.** After `setDefaultApplication` succeeds for
  `http`, a request for `https` returns a spurious error. Request each scheme only while it still
  points elsewhere and judge success by the resulting handler, not by thrown errors.
- Build settings use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 5 mode). Top-level code in
  `main.swift` is nonisolated, hence the `MainActor.assumeIsolated` wrapper; the delegate is held by a
  global because `NSApplication.delegate` is weak.
- The background refresh runs `BrowserStore.refresh()` off the main thread, so `BrowserDiscovery`,
  `BrowserStore` and `BrowserEntry` are `nonisolated` (only the icon memo is `@MainActor`). Icon PNGs
  are rendered into an `NSBitmapImageRep` context — never `NSImage.lockFocus()`, which is not
  thread-safe. After a refresh the icon memo is invalidated because file names are reused.
- `@Observable` skips notifications for equal values, so `PickerModel.update(entries:)` bumps an
  `iconRevision` counter to force rows to reload their icons.
- Chrome `Local State` keys used: `name`, `gaia_name`, `user_name`, `profile_highlight_color`
  (fallback `default_avatar_fill_color`), `is_ephemeral`. Profile picture:
  `<profile dir>/Google Profile Picture.png`. A malformed `Local State` must degrade to Safari only.

## Build, install, verify

```sh
xcodebuild -project BrowserSelector.xcodeproj -scheme BrowserSelector -configuration Release build
rm -rf /Applications/BrowserSelector.app
ditto ~/Library/Developer/Xcode/DerivedData/BrowserSelector-*/Build/Products/Release/BrowserSelector.app /Applications/BrowserSelector.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/BrowserSelector.app
```

- **Do not launch the app without the user's permission**: a direct launch changes the system default
  browser. Test the picker with `open -a /Applications/BrowserSelector.app "<url>"` — it never touches
  the default-browser setting. Quit a running copy before reinstalling.
- Check the registered handler with a small Swift script calling
  `NSWorkspace.shared.urlForApplication(toOpen:)` for `http://` and `https://` URLs.
- Debug and Release copies in DerivedData register with LaunchServices under the same bundle id
  (`it.marcell.BrowserSelector`). The installed copy in `/Applications` must be the default handler.
- Logs: `log show --predicate 'subsystem == "it.marcell.BrowserSelector"' --last 10m --info`
  (categories `app` and `launch`; received URLs are logged as private).

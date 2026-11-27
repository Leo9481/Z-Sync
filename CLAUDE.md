# Project brief: personal iOS browser, forked from Z-Sync

This repo is a personal fork of Z-Sync (github.com/Kjell6/Z-Sync), an iOS companion app that mirrors the Zen Browser desktop sidebar over Firefox Sync. The goal is to grow it into a full, minimal iOS browser with strong ad blocking and Raindrop.io bookmarks.

Items marked **(verify)** are assumptions made before reading the code. Check them in the repo first and tell the user if they are wrong.

## Constraints

- The owner (Leo) has **no Mac**. Everything is built by GitHub Actions on macOS runners. You cannot build or run the app locally, so push changes and read the workflow logs (`gh run list`, `gh run view --log-failed`).
- CI must produce an **unsigned .ipa** as a downloadable artifact. Leo signs and sideloads it himself, so no certificates or provisioning profiles in the workflow.
- Personal use only. The repo stays public, but there is no App Store release or distribution. Keep the existing MIT license and copyright notices, and keep MPL 2.0 attribution for any Zen assets that are kept.
- Leo cannot see the app running on your side. He tests on his iPhone and reports back. After each milestone, say clearly what to test and what to look for.
- The iOS project is SwiftUI generated with XcodeGen (`ios/project.yml`) **(verify)**. Never hand-edit a `.xcodeproj`. Edit the XcodeGen config.

## Working rules

- Work on a branch and open pull requests. Do not push directly to `main`.
- Keep changes small and each one buildable. Push, check that CI passes, then move on.
- Before any large refactor, explain the plan and ask first.
- Do not break the existing Z-Sync sync code. Read `shared/contract/` (the sync spec and golden JSON) before touching sync **(verify)**.
- Use only features that exist in the app's minimum iOS version. Ask Leo which iOS version his phone runs if it matters.
- Explain things plainly. Leo is a technical hobbyist, not a professional iOS developer.

## Existing app (keep)

The current Z-Sync sidebar screen stays as a **1:1 real-time mirror of the desktop Zen sidebar**: Essentials grid at the top, the "Default Workspace" header, folders (Anime, Slingshot, TV Box), the scrollable list of open tabs, and a bottom bar with an archive button, a search field and settings.

## Target design

### 1. Browser shell
- `WKWebView`-based browser with a minimal Safari-style UI.
- Floating buttons in a **frosted-glass** style built on SwiftUI blur materials with a custom tint and border. Do not depend on Apple's native Liquid Glass API, so the look stays stable across iOS versions.
- Two extra quick buttons beyond Safari's: **fullscreen** (hides the bars) and **quick bookmark** (tap saves to a default Raindrop collection, long-press chooses a collection). The quick-bookmark icon is Raindrop's cloud logo.
- The browser is the app's root screen. Bottom bar is one row, laid out like Safari's (decided with Leo, 2026-11-27):
  `[‹ ›]  [☰  ⤢  domain  ☁  ↻]  [⧉]`. Left: a back/forward capsule, with forward only shown when there is a page to go forward to. Center: the address pill holding the page menu, fullscreen, the domain, Raindrop quick bookmark and reload/stop, with tighter side padding than Safari so the domain keeps room. Right: the tabs button.
- No close (✕) button, no second row, no gradient or scrim behind the bar. No microphone or voice search (Leo uses the keyboard's dictation).

### 2. Tab manager (Safari-style)
- A tab grid like Safari's, using `LazyVGrid` and thumbnails from `WKWebView.takeSnapshot`.
- Bottom bar with a **"Private | Tabs"** pill, a `+` button, and a done button. It also holds the **sidebar** button (the only way into the sidebar) and a **Raindrop bookmarks** button that opens all Raindrop collections and bookmarks.
- Each card has a close button at the top right and a **"send to desktop" button at the bottom left**, with a short confirmation (checkmark) after sending.
- Memory: use the efficient, standard approach. Keep a few live web views (`OpenPagesStore.liveLimit`), and let the rest sleep with their snapshot and history and wake on demand. Persist tabs so they survive restarts. Tabs do not expire by default.
- Mobile tabs are **separate from desktop tabs**. Nothing syncs automatically from mobile to desktop.
- **Private section (Leo, 2026-11-27):** private tabs become their own section, like Safari's `[Private | N Tabs]` pill in the overview, instead of a single page made private from a blank tab. Switching the pill switches between two separate decks. + opens a new tab in whichever section is showing.
  - Every private tab behaves as incognito: its own non-persistent `WKWebsiteDataStore`, no history entries, no saved cookies, cache or site data, and no thumbnails written to disk.
  - **Setting: "Lock private tabs"** (off by default). It asks for Face ID / Touch ID or the device passcode (`LAContext`, `.deviceOwnerAuthentication`) **every time** the private section is opened. No grace period. While locked or in the app switcher, the private section shows a blurred cover, never page content.
  - **Setting: "Keep private tabs"** (off by default). Off: all private tabs close when you switch back to normal tabs or the app is closed. On: the list of private tabs (address and title only) stays in the private section. All their browsing data is still wiped: each kept tab reloads fresh, signed out, with no cookies or history. The kept list is stored encrypted with iOS Data Protection (`completeUnlessOpen` or stricter) and never in the App Group or iCloud backups.

### 3. Sidebar view
- A separate button opens the existing sidebar screen above.
- Tapping a tab or pinned tab there opens a **local copy** as a mobile tab. This replaces the current quick browser.

### 4. Send to desktop (Send Tab to Device)
- Decided 2026-11-27: implement Firefox's **Send Tab to Device** over Firefox Account device commands, not by writing a tab into the spaces collection. A spaces write only shows up after desktop Zen re-syncs (often a restart). Send Tab arrives within seconds, in the active workspace.
- Register the app as an FxA device with the send-tab command so it also shows in desktop Zen's "Send to device" list. Receiving on the phone is checked when the app opens (no Mozilla push credentials).
- Verify the protocol against Mozilla's docs and the Firefox iOS / application-services source before coding. Keep it separate from the spaces sync code.
- **Share sheet redesign (decided with Leo, 2026-11-27):** sharing a link from any app shows two choices instead of the pin-into-a-space screen: **Open in Z-Browser** (opens it as a regular new tab) and **Send to device** (lists the devices on the Firefox account). The pin/workspace picker goes away.
  - "Open in Z-Browser" needs the share extension to launch the main app. Apple has no official API for this, so it walks the responder chain to `UIApplication.open(_:options:completionHandler:)` with the `zsync://open?url=` link. It may break in a future iOS. If it fails, fall back to saving the link in the App Group for the app to open next time it comes to the front.
  - "Open in Z-Browser" can ship before Send Tab. The device list arrives with milestone 5.

### 5. Ad blocking
Leo's benchmark is sketchy streaming sites full of popups, popunders, fake play buttons and banners. YouTube is not a priority.

Order of work:
1. **Native popup and redirect blocking**, with no filter lists. Use `WKUIDelegate` to deny new-window requests without a real user gesture, and `WKNavigationDelegate` to cancel cross-site redirects that happen without a user gesture.
2. **Filter lists** from the uBlock Origin ecosystem (uAssets repo: uBlock filters, annoyances, plus EasyList and EasyPrivacy) **(verify current URLs)**. Compile them to WebKit content-blocker rules. Apple limits rules per list, so load several lists and prioritize **(verify the current cap)**.
3. **Cosmetic filters and scriptlets** using Brave's `adblock-rust` crate, with uBO's scriptlet resources, injected through `WKUserScript` at document start. The Rust library is cross-compiled for iOS inside the CI workflow.
4. **Automatic list updates:** conditional HTTP requests on launch and periodically, recompile only changed lists, and swap them in without blocking page loads.

Known ceiling: WebKit does not let apps cancel arbitrary network requests, so this will not match uBlock Origin on desktop. The target is clearly better than Brave for iOS, which uses only a reduced static rule set.

### 6. Raindrop.io bookmarks
- Raindrop.io is the bookmarks manager, integrated directly. It uses a REST API with OAuth **(verify current docs, endpoints and rate limits)**.
- Collections map to folders. Provide a bookmarks view, the quick-save button, and add/remove support.
- Leo will create the Raindrop developer app and provide the keys. Never commit secrets. Use CI secrets and local config.

### 7. Page translator and dark mode (must-haves, added 2026-11-27)
Both live in the page menu (the ☰ button in the address pill).
- **Translate page:** use Apple's on-device Translation framework (private, free, no API key). Collect the page's text nodes with an injected script, translate them in batches with `TranslationSession`, and write them back in place. Offer "Show original" to undo. The framework's programmatic API needs iOS 18, so on iOS 17 hide the item. **(Verify the current API before coding.)**
- **Dark mode for websites:** one global toggle in the menu, applied to every page. Use Dark Reader's dynamic theme engine (MIT license), injected as a `WKUserScript`, so pages that are already dark stay as they are. Allow turning it off for one site. **(Verify the license and the current release.)**

### 8. Browser-only VPN (Proton WireGuard), added 2026-11-27
- Goal: a toggle that sends only the browser's traffic through Leo's Proton VPN. The rest of the phone is untouched. iCloud Private Relay can't be used (no API for third-party browsers), and Proton offers no SOCKS/HTTP proxies, so this is the route.
- How: run a userspace WireGuard client inside the app (for example wireguard-go with a userspace network stack, exposing a local SOCKS5 proxy, like wireproxy). Point WebKit at it with `WKWebsiteDataStore.proxyConfigurations` (iOS 17+). This is the same pattern Onion Browser uses for Tor. Build the library in CI, like adblock-rust. **(Verify current libraries, licenses and the proxyConfigurations behaviour before coding.)**
- Leo imports a WireGuard config file downloaded from his Proton account. The file holds a private key: store it in the Keychain only, never in the repo, logs or CI.
- Scope of the toggle: start with a global on/off in the page menu or settings. Consider "always on for private tabs" later. Runs only while the app is open. It uses one of Proton's device connections.
- While the toggle is on and a check or fallback is still running, fail closed: pages wait or show an error instead of loading directly.
- **Server check (Leo, 2026-11-27):** each config is tied to one Proton server. WireGuard has no "is the server up" ping, so the check is: bring up the tunnel, wait for a handshake, then load a small test URL through it, with a short timeout. Run it when the toggle is switched on, when the app returns to the front, and when page loads start failing through the tunnel.
- **Fallback cascade:** Leo can import a few configs in a priority order he sets. If the check fails on config 1, try config 2, then 3, and so on. Show which server is in use. **If every config fails (Leo, 2026-11-27):** show a popup that says no VPN server answered, and turn the feature off automatically, so browsing goes on over the normal connection. Leo turns it back on himself. Periodically retry the preferred config so it switches back once that server is up again.

### 9. Performance pass (Leo, 2026-11-27)
- Leo finds some animations laggy, mostly the tab ones: the page flying into the overview, the overview deck, and swiping between tabs. Do a proper, measured optimization rather than guesswork.
- Approach: profile with Instruments (SwiftUI and Time Profiler templates, Animation Hitches) on a CI-built, development-signed run where possible. Otherwise add `os_signpost` intervals around the transitions and log hitch timings in a debug setting Leo can read. Usual suspects: snapshot captures on the main thread during a transition, SwiftUI view bodies re-running for every card each frame, shadows and blur materials without `compositingGroup`/`drawingGroup`, oversized thumbnails, and waking sleeping web views mid-animation.
- Target: a steady 120 Hz on ProMotion phones for the tab transitions, with Leo's real tab count (30+).

### 10. Downloads (Leo, 2026-11-27)
- A **Downloads** panel listing ongoing downloads (progress, cancel) and completed ones (open, share, show in Files). Reachable from the ☰ menu and the existing download capsule.
- The list lives in memory only: it is empty again after the app is quit. The files themselves stay where they were saved.
- **Settings → Downloads → Save to:** pick a default folder with Apple's folder picker (`UIDocumentPickerViewController` for folders): iCloud Drive, On My iPhone, or any Files provider. Keep it as a security-scoped bookmark. If the folder is gone or access lapses, fall back to the app's own Documents folder (today's behaviour) and say so.
- Build on the existing `BrowserDownloads.swift`.

### 11. Backup: import and export (Leo, 2026-11-27)
- **Settings → Backup:** Export a full backup, and Import one. Leo chooses the file or folder each time with Apple's Files picker.
- **What a backup holds:** all app settings (search engines, translation, dark mode and its per-site list, content blocking and per-site switches, site permissions, toolbar, private-tab settings) and the open normal tabs (address, title, order). Possibly browsing history and the Raindrop link state once those exist.
- **What it never holds:** private tabs, caches, thumbnails, website data such as cookies and logins, and secrets: the Firefox Account session and Raindrop tokens stay in the Keychain, so Leo signs in again after a restore.
- **Format:** one versioned JSON file (`Z-Browser-backup-YYYY-MM-DD.json`), so later versions can still read older backups.
- **Import:** shows what the backup contains and asks before replacing the current settings. Tabs are added to the open ones, not swapped in.
- **Automatic backup:** off, daily, weekly or monthly, into a folder Leo picks (security-scoped bookmark), keeping the last few files (for example 5).
  - iOS has no reliable timer for apps. The backup runs when the app opens or comes to the front and the last one is older than the interval. A `BGAppRefreshTask` is added as a bonus when iOS allows it.
  - Show the date of the last successful backup, and a clear note if the folder can't be reached.

## Suggested order of work

1. Get the fork building: unsigned-IPA workflow in GitHub Actions, and confirm it installs on Leo's phone.
2. Browser shell: `WKWebView`, address and search bar, minimal UI, and opening sidebar tabs locally.
3. Page menu tools: translator and dark mode for websites.
4. Tab manager: grid, thumbnails, persistence, "Private | Tabs" pill with the private section, its lock and its keep setting.
4b. Performance pass on the tab animations, right after the tab manager lands.
5. Send to desktop.
6. Popup and redirect blocking.
7. Raindrop.io integration and quick-bookmark button.
8. Filter lists, then cosmetic filters and scriptlets, then auto-updates.
9. Browser-only VPN through Proton WireGuard.
9b. Downloads panel and default save folder; then backup (import/export and automatic). The order of these can move if Leo asks.
10. Frosted-glass polish and fullscreen button, tuned on the real phone.

## Open questions to answer by reading the code first

- How does Z-Sync read and write tabs and spaces over Firefox Sync, and can it add a tab to the default space?
- How is the quick in-app browser structured, and what is the cleanest way to replace it?
- Which iOS deployment target does the project use?
- Which CI workflow already exists, if any?

## Verified facts (checked against upstream commit 1afe98d)

- `AGENTS.md` holds upstream's rules. Where it conflicts with this file, this file wins. In particular, Android parity does not apply (this fork is iOS-only, leave `android/` untouched), and version or build bumps are fine here.
- XcodeGen is confirmed (`ios/project.yml`). A generated `ios/ZenCompanion.xcodeproj` is also committed. CI regenerates it, so still never hand-edit it.
- Deployment target: iOS 17.0, iPhone and iPad. Leo runs iOS 27 / iPadOS 27 and sideloads with FlareStore. Keep 17.0 for now and decide later whether raising it is worth it.
- The app icon is an Icon Composer `AppIcon.icon`, so builds need Xcode 26 or newer.
- Targets: `ZenCompanion` app, `ShareExtension`, `ZenCompanionTests`. Both shipping targets use App Group `group.de.kjell.zencompanion` and a shared keychain group. Signing is overridden through a gitignored `ios/Config/Team.local.xcconfig`.
- The fork's IDs are `io.github.leo9481.zenbrowser` (app), `.share` (extension) and App Group `group.io.github.leo9481.zenbrowser` (also hard-coded in `ios/Shared/Data/AppGroup.swift`). That way it installs next to the App Store Z-Sync. Logger subsystems and error domains still say `de.kjell.zencompanion`, which is harmless. The committed `.xcodeproj` still has the old IDs until someone regenerates it on a Mac; CI regenerates it on every build.
- There was no CI before this fork. The workflow in `.github/workflows/` is ours.
- Send to desktop: `SpacesSyncService.addTab(url:title:to:folderId:kind:)` with `kind: .normal` writes an unpinned tab at the space root. It only works if the desktop pref `zen.spaces-sync.normal-tabs` is on. Otherwise the spec requires falling back to pinned (`AddTabOutcome.fellBackToPinned`). There is no default-space concept in code (the share sheet uses the last-used space, then the first one).
- The quick browser is `ios/ZenCompanion/Browser/MiniBrowser*` (already has a glass chrome, an open-pages overview, a navigation policy and history). Plan to grow it rather than rewrite.
- Content blocking exists: bundled EasyList and EasyPrivacy (`Browser/ContentBlocking/`, updated by `scripts/content-blocking/update-blocklists.sh`) plus DuckDuckGo autoconsent for cookie banners.

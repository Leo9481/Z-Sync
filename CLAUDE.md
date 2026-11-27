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
- Two extra quick buttons beyond Safari's: **fullscreen** (hides the bars) and **quick bookmark** (tap saves to a default Raindrop collection, long-press chooses a collection).

### 2. Tab manager (Safari-style)
- A tab grid like Safari's, using `LazyVGrid` and thumbnails from `WKWebView.takeSnapshot`.
- Bottom bar with a **"Private | Tabs"** pill, a `+` button, and a done button.
- Each card has a close button at the top right and a **"send to desktop" button at the bottom left**, with a short confirmation (checkmark) after sending.
- Leo often has around 30 tabs open, so keep only a few live web views in memory. The rest become snapshots and reload on demand. Persist tab state (for example `interactionState`) so tabs survive app restarts.
- Mobile tabs are **separate from desktop tabs**. Nothing syncs automatically from mobile to desktop.

### 3. Sidebar view
- A separate button opens the existing sidebar screen above.
- Tapping a tab or pinned tab there opens a **local copy** as a mobile tab. This replaces the current quick browser.

### 4. Send to desktop
- Sends the tab's link so it appears as a **regular open tab in the Default Workspace** in desktop Zen, in the same list as the other open tabs. No space picker, since Leo uses only the Default Workspace.
- Z-Sync already has a "share a link into a space" feature **(verify)**. Reuse it if it can add a normal tab to the default space, and tell Leo if it cannot.

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

## Suggested order of work

1. Get the fork building: unsigned-IPA workflow in GitHub Actions, and confirm it installs on Leo's phone.
2. Browser shell: `WKWebView`, address and search bar, minimal UI, and opening sidebar tabs locally.
3. Tab manager: grid, thumbnails, persistence, "Private | Tabs" pill.
4. Send to desktop.
5. Popup and redirect blocking.
6. Raindrop.io integration and quick-bookmark button.
7. Filter lists, then cosmetic filters and scriptlets, then auto-updates.
8. Frosted-glass polish and fullscreen button, tuned on the real phone.

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

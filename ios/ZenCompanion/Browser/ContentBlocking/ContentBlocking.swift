import CryptoKit
import Foundation
import Observation
import UIKit
import WebKit

/// What the quick browser can block. Each has its own switch.
enum BlockCategory: String, CaseIterable, Sendable {
    case ads
    case trackers
    case cookieBanners = "cookie_banners"
}

/// The key a site's own switches are stored under: the host without `www.`.
func blockingSiteKey(_ host: String) -> String {
    var key = host.lowercased()
    while key.hasSuffix(".") { key.removeLast() }
    if key.hasPrefix("www.") { key.removeFirst(4) }
    return key
}

/// The three switches in Settings, and the sites where one of them is turned
/// off from the browser menu. A site can only turn off what Settings has on.
struct ContentBlockingSettings: Equatable, Sendable {
    var ads = true
    var trackers = true
    var cookieBanners = true
    var offForSites: [BlockCategory: Set<String>] = [:]

    func isOn(_ category: BlockCategory) -> Bool {
        switch category {
        case .ads: return ads
        case .trackers: return trackers
        case .cookieBanners: return cookieBanners
        }
    }

    /// On in Settings and not turned off for the site of `host`.
    func isOn(_ category: BlockCategory, host: String?) -> Bool {
        guard isOn(category) else { return false }
        guard let host else { return true }
        return !(offForSites[category] ?? []).contains(blockingSiteKey(host))
    }

    func with(_ category: BlockCategory, on: Bool) -> ContentBlockingSettings {
        var copy = self
        switch category {
        case .ads: copy.ads = on
        case .trackers: copy.trackers = on
        case .cookieBanners: copy.cookieBanners = on
        }
        return copy
    }

    func withSite(_ category: BlockCategory, host: String, on: Bool) -> ContentBlockingSettings {
        var copy = self
        let site = blockingSiteKey(host)
        var sites = copy.offForSites[category] ?? []
        if on { sites.remove(site) } else { sites.insert(site) }
        copy.offForSites[category] = sites
        return copy
    }

    /// Every switch that is on in Settings is off for this site.
    func allOff(for host: String) -> Bool {
        let active = BlockCategory.allCases.filter { isOn($0) }
        return !active.isEmpty && !active.contains { isOn($0, host: host) }
    }

    var cookieBannerSitesOff: Set<String> { offForSites[.cookieBanners] ?? [] }
}

/// What the card at the top of the browser menu says.
enum BlockingCard: Equatable {
    /// Something was blocked on this page.
    case blocked(Int)
    /// The page was reloaded once with blocking off.
    case showingOriginal
    /// Every switch that is on in Settings is off for this site.
    case offForSite(String)
    case hidden

    static func of(settings: ContentBlockingSettings, host: String?, blockedCount: Int, showingOriginal: Bool) -> BlockingCard {
        guard let host, !host.isEmpty else { return .hidden }
        if showingOriginal { return .showingOriginal }
        if settings.allOff(for: host) { return .offForSite(blockingSiteKey(host)) }
        if blockedCount > 0 { return .blocked(blockedCount) }
        return .hidden
    }
}

/// One of the two filter lists, as shipped and as downloaded.
enum FilterList: String, CaseIterable, Sendable {
    case easylist
    case easyprivacy
    // uBlock Origin's own lists (uBlockOrigin/uAssets, GPLv3), meant to be
    // used along EasyList and EasyPrivacy. Fetched by CI at build time and
    // weekly by the app; a build without them still blocks with the two above.
    case ublockFilters = "ublock-filters"
    case ublockBadware = "ublock-badware"
    case ublockQuickFixes = "ublock-quick-fixes"
    case ublockPrivacy = "ublock-privacy"
    case ublockUnbreak = "ublock-unbreak"
    // Domain lists, as uBlock Origin and DNS blockers use them: hosts of ad
    // networks, trackers and device telemetry the lists above leave out.
    // Peter Lowe's list is on by default in uBlock Origin; HaGeZi's Multi
    // LIGHT (GPLv3) is the low-breakage edition, built only from domains
    // seen on top-1M lists.
    case peterLowe = "peter-lowe"
    case hageziLight = "hagezi-light"

    var url: URL {
        switch self {
        case .easylist: return URL(string: "https://easylist.to/easylist/easylist.txt")!
        case .easyprivacy: return URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
        case .ublockFilters: return URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!
        case .ublockBadware: return URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!
        case .ublockQuickFixes: return URL(string: "https://ublockorigin.github.io/uAssets/filters/quick-fixes.txt")!
        case .ublockPrivacy: return URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!
        case .ublockUnbreak: return URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!
        case .peterLowe: return URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!
        case .hageziLight: return URL(string: "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/light.txt")!
        }
    }

    /// The switches the list belongs to. Unbreak holds exceptions for both,
    /// and an exception only undoes rules in the same compiled list.
    var categories: [BlockCategory] {
        switch self {
        case .easylist, .ublockFilters, .ublockBadware, .ublockQuickFixes, .peterLowe: return [.ads]
        // Mostly trackers and telemetry, and the Trackers list has the room.
        case .easyprivacy, .ublockPrivacy, .hageziLight: return [.trackers]
        case .ublockUnbreak: return [.ads, .trackers]
        }
    }

    /// Lists made mostly of domain rules, checked by how many they hold; uBO's
    /// lists are mostly patterns and exceptions, so they are checked by size.
    var isDomainList: Bool { [.easylist, .easyprivacy, .peterLowe, .hageziLight].contains(self) }
}

/// When to download fresh lists, and which downloads to trust.
enum FilterListUpdates {
    /// Checked once a day: HaGeZi publishes daily and uBlock Origin's lists
    /// expire after five days. A list that hasn't changed costs one small
    /// request ("only if changed").
    static let interval: TimeInterval = 24 * 60 * 60
    /// Well above the real lists, so a broken server can't fill the phone.
    static let maxBytes = 16 * 1024 * 1024
    /// Both real lists have tens of thousands; far fewer means a bad download.
    static let minRules = 1_000

    /// A clock set back (or a date in the future) counts as due.
    static func isDue(lastUpdate: Date?, now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= interval || lastUpdate > now
    }

    /// The text, when it is a usable copy of `list`.
    static func accept(_ text: String, for list: FilterList) -> String? {
        if list.isDomainList { return accept(text) != nil ? text : nil }
        // uBO's lists open with their title; a broken server sends a page.
        guard text.hasPrefix("! Title:") || text.hasPrefix("[Adblock") else { return nil }
        let rules = text.split(separator: "\n").filter { !$0.hasPrefix("!") }.count
        return rules >= 20 ? text : nil
    }

    /// The parsed list, or nil when the download isn't a usable filter list.
    static func accept(_ text: String) -> BlockList? {
        guard text.hasPrefix("[Adblock") else { return nil }
        let list = BlockList.parse(text)
        return list.ruleCount >= minRules ? list : nil
    }

    /// The copy to use when both parse: the downloaded one only when it is at
    /// least as new as the bundled one, so a newer list that came with an app
    /// update isn't held back by an older download. Versions are fixed-width
    /// timestamps (`202610242150`), so plain string order is newness; a version
    /// missing on either side keeps the download, as before.
    static func chooseList(bundled: BlockList?, downloaded: BlockList?) -> BlockList? {
        guard let downloaded else { return bundled }
        guard let bundled else { return downloaded }
        guard let bundledVersion = bundled.version, let downloadedVersion = downloaded.version else { return downloaded }
        return downloadedVersion >= bundledVersion ? downloaded : bundled
    }

    /// `24 Oct 2026 21:50 UTC` from the list header becomes `24 Oct 2026`.
    static func displayDate(_ lastModified: String) -> String? {
        let parts = lastModified.split(separator: " ").prefix(3)
        return parts.count == 3 ? parts.joined(separator: " ") : nil
    }
}

/// Wraps the autoconsent bundle so it does nothing on the sites in `skip`.
/// The check uses the top page's host, which frames read from `ancestorOrigins`.
func consentScriptSource(bundle: String, skip: Set<String>) -> String {
    let sites = skip.sorted()
        .map { "\"" + $0.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\"" }
        .joined(separator: ",")
    return """
    (function () {
      var skip = [\(sites)];
      var host = location.hostname;
      try {
        var a = location.ancestorOrigins;
        if (a && a.length) host = new URL(a[a.length - 1]).hostname;
      } catch (e) {}
      host = host.toLowerCase().replace(/^www\\./, '');
      if (skip.indexOf(host) !== -1) return;
    \(bundle)
    })();
    """
}

/// What one web view should have: which compiled rule lists (by identifier,
/// so a weekly refresh counts as a change), and which sites the cookie banner
/// script skips (nil: no script at all).
struct BlockingConfiguration: Equatable {
    var ruleLists: [String]
    var consentSkip: Set<String>?
}

/// The app's content blocker: the switches, the parsed lists and their
/// compiled WebKit rule lists. Lists load and compile in the background at
/// app start; until then nothing is blocked, which only matters for a page
/// opened in the first moments after the first launch.
@MainActor
@Observable
final class ContentBlocker {
    static let shared = ContentBlocker()

    private(set) var settings = ContentBlockingSettings()
    /// False until the setup question was answered.
    private(set) var asked = true
    /// The ad list's own date, for the caption in Settings.
    private(set) var lastModified: String?

    @ObservationIgnored private var lists: [FilterList: BlockList] = [:]
    @ObservationIgnored private var ruleLists: [BlockCategory: [WKContentRuleList]] = [:]
    @ObservationIgnored private var consentBundle: String?
    @ObservationIgnored private let preferences: PreferencesStoring
    @ObservationIgnored private var started = false

    init(preferences: PreferencesStoring = AppServices.preferences) {
        self.preferences = preferences
    }

    func start() {
        guard !started else { return }
        started = true
        settings = loadSettings()
        asked = preferences.bool(Keys.asked, scope: .standard)
        Task {
            // The lists compiled last time, at once: pages are protected from
            // the first moment, while the current texts are read and checked.
            await restoreCompiledLists()
            // Half a megabyte: read off the main thread, while the first page
            // starts. Pages set up before it arrives skip cookie banners once.
            consentBundle = await Task.detached(priority: .userInitiated) {
                Bundle.main.url(forResource: "autoconsent", withExtension: "js")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }.value
            await loadLists()
            await updateIfDue()
        }
        // An app left open for days still updates: checked each time it comes back.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.updateIfDue() }
            }
        }
    }

    @ObservationIgnored private var updating = false

    /// Downloads what changed, once a day, and swaps in the new rules. The
    /// rules in use stay in place while the new ones compile.
    private func updateIfDue() async {
        guard !updating else { return }
        let last = preferences.string(Keys.updatedAt, scope: .standard).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        // Nothing to keep current while both list switches are off.
        guard settings.ads || settings.trackers, FilterListUpdates.isDue(lastUpdate: last, now: Date()) else { return }
        updating = true
        defer { updating = false }
        let result = await Self.downloadLists()
        // Checked, even when nothing changed: the next check is a day later.
        if result.checked {
            preferences.setString(String(Date().timeIntervalSince1970), Keys.updatedAt, scope: .standard)
        }
        if result.changed { await loadLists() }
    }

    /// The compiled lists last used, looked up by the identifiers saved after
    /// they compiled. Looking up is quick; compiling is what takes a minute.
    private func restoreCompiledLists() async {
        guard ruleLists.isEmpty, let store = WKContentRuleListStore.default() else { return }
        var restored: [BlockCategory: [WKContentRuleList]] = [:]
        for category in [BlockCategory.ads, .trackers] {
            let ids = preferences.string(Keys.compiled(category), scope: .standard)?
                .split(separator: "\n").map(String.init) ?? []
            var lists: [WKContentRuleList] = []
            for id in ids {
                guard let list = await store.lookUp(id) else { lists = []; break }
                lists.append(list)
            }
            if !lists.isEmpty { restored[category] = lists }
        }
        // `loadLists` may have finished first; its lists are newer.
        if ruleLists.isEmpty, !restored.isEmpty { ruleLists = restored }
    }

    func update(_ settings: ContentBlockingSettings) {
        self.settings = settings
        saveSettings(settings)
    }

    /// The answer to the setup question: the three switches, saved at once.
    func answerSetup(_ settings: ContentBlockingSettings) {
        update(settings)
        preferences.setBool(true, Keys.asked, scope: .standard)
        asked = true
    }

    /// True when a resource the page loaded is on an active list. Used for the
    /// count on iOS, where WebKit doesn't report what it blocked.
    func blocks(_ url: URL, pageHost: String?) -> Bool {
        guard let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return lists.contains { entry in
            entry.key.categories.contains { settings.isOn($0, host: pageHost) }
                && entry.value.blocks(requestHost: host, pageHost: pageHost)
        }
    }

    /// True when a new window to `url`, opened by a page on `openerHost`, is
    /// an ad by the lists of a switch that is on for that page.
    func blocksPopup(_ url: URL, openerHost: String?) -> Bool {
        guard let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return lists.contains { entry in
            entry.key.categories.contains { settings.isOn($0, host: openerHost) }
                && entry.value.blocksPopup(host: host, openerHost: openerHost)
        }
    }

    /// What a web view needs for a page on `host`; `original` turns blocking off.
    func configuration(host: String?, original: Bool) -> BlockingConfiguration {
        if original { return BlockingConfiguration(ruleLists: [], consentSkip: nil) }
        let wanted = [BlockCategory.ads, .trackers]
            .filter { settings.isOn($0, host: host) }
            .flatMap { (ruleLists[$0] ?? []).compactMap(\.identifier) }
        let skip = settings.isOn(.cookieBanners) && consentBundle != nil ? settings.cookieBannerSitesOff : nil
        return BlockingConfiguration(ruleLists: wanted, consentSkip: skip)
    }

    /// Puts a configuration on a web view's content controller. The caller
    /// adds its own scripts afterwards, because this clears them.
    func apply(_ configuration: BlockingConfiguration, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        for list in ruleLists.values.joined() where configuration.ruleLists.contains(list.identifier) {
            controller.add(list)
        }
        controller.removeAllUserScripts()
        if let skip = configuration.consentSkip, let consentBundle {
            controller.addUserScript(WKUserScript(
                source: consentScriptSource(bundle: consentBundle, skip: skip),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            ))
        }
    }

    // MARK: - Lists

    private func loadLists() async {
        // Each list's text (the copy to use) and its domain rules.
        var texts: [FilterList: String] = [:]
        var loaded: [FilterList: BlockList] = [:]
        for list in FilterList.allCases {
            guard let read = await Task.detached(priority: .utility, operation: { Self.readList(list) }).value else { continue }
            texts[list] = read.text
            loaded[list] = read.domains
        }
        lists = loaded
        lastModified = loaded[.easylist]?.lastModified

        // The ad lists' hiding rules go to the cosmetic engine (adblock-rust).
        let cosmetic = FilterList.allCases
            .filter { $0.categories.contains(.ads) }
            .compactMap { texts[$0] }
            .joined(separator: "\n")
        if !cosmetic.isEmpty { CosmeticEngine.shared.load(cosmetic) }

        var compiled: [BlockCategory: [WKContentRuleList]] = [:]
        for category in [BlockCategory.ads, .trackers] {
            let sources = FilterList.allCases.compactMap { list -> RuleSource? in
                guard list.categories.contains(category), let text = texts[list], let domains = loaded[list] else { return nil }
                return RuleSource(list: list, text: text, domains: domains)
            }
            guard !sources.isEmpty else { continue }
            compiled[category] = await Self.ruleLists(for: category, sources)
        }
        // Swapped in per category, and only when it compiled: a category that
        // failed keeps the rules it had.
        for (category, lists) in compiled where !lists.isEmpty {
            ruleLists[category] = lists
            preferences.setString(lists.compactMap(\.identifier).joined(separator: "\n"), Keys.compiled(category), scope: .standard)
        }
        await Self.removeStaleRuleLists(keeping: Set(ruleLists.values.joined().compactMap(\.identifier)))
    }

    /// One list's text and domain rules, on its way to a compiled list.
    private struct RuleSource: Sendable {
        let list: FilterList
        let text: String
        let domains: BlockList
    }

    /// The copy to use, with its domain rules: the downloaded copy when it is
    /// accepted and at least as new as the bundled one, otherwise the bundled.
    private nonisolated static func readList(_ list: FilterList) -> (text: String, domains: BlockList)? {
        let bundledText = Bundle.main.url(forResource: list.rawValue, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let downloadedText = (try? String(contentsOf: downloadedFile(list), encoding: .utf8))
            .flatMap { FilterListUpdates.accept($0, for: list) }
        let bundled = bundledText.map { BlockList.parse($0) }
        let downloaded = downloadedText.map { BlockList.parse($0) }
        guard let chosen = FilterListUpdates.chooseList(bundled: bundled, downloaded: downloaded) else { return nil }
        // `chooseList` hands back one of the two, unchanged.
        if let downloaded, let downloadedText, chosen.version == downloaded.version,
           chosen.lastModified == downloaded.lastModified, chosen.ruleCount == downloaded.ruleCount {
            return (downloadedText, chosen)
        }
        guard let bundledText else { return nil }
        return (bundledText, chosen)
    }

    /// WebKit caps a compiled list at 150,000 rules; a little room is kept.
    private nonisolated static let maxRulesPerList = 149_000

    /// The category's compiled lists: every member's domain rules and pattern
    /// rules, blocks first and exceptions after, split into as many lists as
    /// the cap needs (each with all the exceptions). Looked up by a hash of
    /// the texts, so they are compiled again only when a list changed. If
    /// WebKit refuses them, the domain rules alone are used, as before.
    private static func ruleLists(for category: BlockCategory, _ sources: [RuleSource]) async -> [WKContentRuleList] {
        guard let store = WKContentRuleListStore.default() else { return [] }
        let hash = await Task.detached(priority: .utility) { () -> String in
            var hasher = SHA256()
            hasher.update(data: Data("v\(NetworkFilters.version)".utf8))
            for source in sources {
                hasher.update(data: Data(source.list.rawValue.utf8))
                hasher.update(data: Data(source.text.utf8))
            }
            return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        }.value
        let prefix = "zsync-\(category.rawValue)-\(hash)-"

        // Already compiled: every part, in order.
        var found: [WKContentRuleList] = []
        while let part = await store.lookUp(prefix + String(found.count)) { found.append(part) }
        if !found.isEmpty { return found }
        let fallback = prefix + "domains"
        if let existing = await store.lookUp(fallback) { return [existing] }

        let parts = await Task.detached(priority: .utility) { () -> [String] in
            var blocks: [String] = []
            var exceptions: [String] = []
            for source in sources {
                blocks += source.domains.blockRules()
                exceptions += source.domains.exceptionRules()
            }
            for source in sources {
                for rule in NetworkFilters.rules(in: source.text) {
                    if rule.exception { exceptions.append(rule.json) } else { blocks.append(rule.json) }
                }
            }
            if category == .ads { blocks += NetworkFilters.builtInAds.map(\.json) }
            // Lists overlap (a tracker on two lists): each rule once, in order.
            var seen = Set<String>()
            blocks = blocks.filter { seen.insert($0).inserted }
            exceptions = exceptions.filter { seen.insert($0).inserted }
            let room = max(10_000, maxRulesPerList - exceptions.count)
            var parts: [String] = []
            var start = 0
            repeat {
                let chunk = blocks[start..<min(start + room, blocks.count)]
                parts.append("[" + (Array(chunk) + exceptions).joined(separator: ",") + "]")
                start += room
            } while start < blocks.count
            return parts
        }.value

        var compiled: [WKContentRuleList] = []
        for (index, json) in parts.enumerated() {
            guard let list = await store.compile(prefix + String(index), json) else {
                compiled = []
                break
            }
            compiled.append(list)
        }
        if !compiled.isEmpty { return compiled }

        // WebKit refused a part: the domain rules alone, which always compiled before.
        NSLog("Content blocking: %@ pattern rules refused, using domain rules only", category.rawValue)
        for index in parts.indices { await store.remove(prefix + String(index)) }
        let json = await Task.detached(priority: .utility) { () -> String in
            var seen = Set<String>()
            let blocks = sources.flatMap { $0.domains.blockRules() }.filter { seen.insert($0).inserted }
            let exceptions = sources.flatMap { $0.domains.exceptionRules() }.filter { seen.insert($0).inserted }
            return "[" + (blocks + exceptions).joined(separator: ",") + "]"
        }.value
        return await store.compile(fallback, json).map { [$0] } ?? []
    }

    /// Compiled lists this version no longer uses, so the store doesn't grow
    /// every week.
    private static func removeStaleRuleLists(keeping current: Set<String>) async {
        guard !current.isEmpty, let store = WKContentRuleListStore.default() else { return }
        for old in await store.availableIdentifiers() where old.hasPrefix("zsync-") && !current.contains(old) {
            await store.remove(old)
        }
    }

    /// Asks for every list "only if changed" (the server's `ETag` and
    /// `Last-Modified` from last time). Each new copy that passes replaces its
    /// own file, so one list that fails doesn't hold the others back.
    /// `checked`: at least one server answered; `changed`: a file was replaced.
    private nonisolated static func downloadLists() async -> (checked: Bool, changed: Bool) {
        let folder = downloadedFile(.easylist).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        var checked = false
        var changed = false
        for list in FilterList.allCases {
            let file = downloadedFile(list)
            // Validators only count while the file they describe is there.
            let haveFile = FileManager.default.fileExists(atPath: file.path)
            let etag = haveFile ? defaults.string(forKey: "content_blocking_etag_\(list.rawValue)") : nil
            let modified = haveFile ? defaults.string(forKey: "content_blocking_modified_\(list.rawValue)") : nil
            switch await fetch(list.url, etag: etag, lastModified: modified) {
            case .notModified:
                checked = true
            case .fetched(let text, let newEtag, let newModified):
                checked = true
                guard FilterListUpdates.accept(text, for: list) != nil else { continue }
                guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
                defaults.set(newEtag, forKey: "content_blocking_etag_\(list.rawValue)")
                defaults.set(newModified, forKey: "content_blocking_modified_\(list.rawValue)")
                changed = true
            case .failed:
                continue
            }
        }
        return (checked, changed)
    }

    private enum FetchResult {
        case notModified
        case fetched(text: String, etag: String?, lastModified: String?)
        case failed
    }

    /// The body as text, or nil on any failure. Reading stops at the size
    /// limit, so a broken server can't fill memory.
    private nonisolated static func fetch(_ url: URL, etag: String?, lastModified: String?) async -> FetchResult {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200,
              response.expectedContentLength <= Int64(FilterListUpdates.maxBytes) else { return .failed }
        let newEtag = http.value(forHTTPHeaderField: "ETag")
        let newModified = http.value(forHTTPHeaderField: "Last-Modified")
        guard let text = await read(bytes, expected: response.expectedContentLength) else { return .failed }
        return .fetched(text: text, etag: newEtag, lastModified: newModified)
    }

    private nonisolated static func read(_ bytes: URLSession.AsyncBytes, expected: Int64) async -> String? {
        var data = Data()
        data.reserveCapacity(max(0, Int(min(expected, Int64(FilterListUpdates.maxBytes)))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > FilterListUpdates.maxBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func downloadedFile(_ list: FilterList) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("content-blocking", isDirectory: true)
            .appendingPathComponent("\(list.rawValue).txt")
    }

    // MARK: - Settings storage

    private enum Keys {
        static let asked = "content_blocking_setup_asked"
        static let updatedAt = "content_blocking_lists_updated_at"
        /// The compiled lists last in use, one identifier per line.
        static func compiled(_ category: BlockCategory) -> String { "content_blocking_compiled_\(category.rawValue)" }
        static func on(_ category: BlockCategory) -> String { "content_blocking_\(category.rawValue)" }
        static func sites(_ category: BlockCategory) -> String { "content_blocking_off_for_sites_\(category.rawValue)" }
    }

    private func loadSettings() -> ContentBlockingSettings {
        var loaded = ContentBlockingSettings()
        for category in BlockCategory.allCases {
            let key = Keys.on(category)
            let on = preferences.hasObject(key, scope: .standard) ? preferences.bool(key, scope: .standard) : true
            loaded = loaded.with(category, on: on)
            let sites = preferences.string(Keys.sites(category), scope: .standard)?
                .split(separator: "\n").map(String.init) ?? []
            loaded.offForSites[category] = Set(sites)
        }
        return loaded
    }

    private func saveSettings(_ settings: ContentBlockingSettings) {
        for category in BlockCategory.allCases {
            preferences.setBool(settings.isOn(category), Keys.on(category), scope: .standard)
            let sites = (settings.offForSites[category] ?? []).sorted().joined(separator: "\n")
            preferences.setString(sites, Keys.sites(category), scope: .standard)
        }
    }
}

/// Completion-handler calls wrapped for async use; errors only mean "no list".
private extension WKContentRuleListStore {
    func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
    }

    func compile(_ identifier: String, _ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Content rule list %@ failed to compile: %@", identifier, error.localizedDescription) }
                continuation.resume(returning: list)
            }
        }
    }

    func remove(_ identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }

    func availableIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
    }
}

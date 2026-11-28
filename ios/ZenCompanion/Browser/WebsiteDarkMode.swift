import Foundation
import WebKit

/// Dark mode for websites, built on Dark Reader's dynamic theme engine (MIT,
/// https://github.com/darkreader/darkreader). The library is fetched by CI at a
/// pinned version (see the workflow) and bundled as `darkreader.js`.
///
/// One global switch, plus a list of sites it is turned off for. The web view
/// also asks pages for their own dark look (`prefers-color-scheme: dark`).
@MainActor
enum WebsiteDarkMode {
    /// Its own world, so the page's scripts cannot see or break it.
    static let world = WKContentWorld.world(name: "ZBrowserDarkMode")

    private static let enabledKey = "websiteDarkMode.enabled"
    private static let offSitesKey = "websiteDarkMode.offSites"

    /// The bundled library, or nil if the build did not include it. Read once,
    /// and early, away from the main thread: see `preload`.
    private nonisolated static let library: String? = Bundle.main
        .url(forResource: "darkreader", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Whether the build has the library, without reading it: the menu asks
    /// this while it draws.
    nonisolated static let isAvailable = Bundle.main.url(forResource: "darkreader", withExtension: "js") != nil

    /// Reads the library and builds the script now, so the first page or
    /// menu that needs them does not wait on the file. Call off the main thread.
    nonisolated static func preload() {
        _ = enableScript
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func isOff(forHost host: String?) -> Bool {
        guard let site = site(host) else { return false }
        return offSites.contains(site)
    }

    static func setOff(_ off: Bool, forHost host: String?) {
        guard let site = site(host) else { return }
        var sites = offSites
        if off { sites.insert(site) } else { sites.remove(site) }
        UserDefaults.standard.set(Array(sites).sorted(), forKey: offSitesKey)
    }

    /// Whether a page on this host gets the dark look.
    static func applies(to host: String?) -> Bool {
        isAvailable && isEnabled && !isOff(forHost: host)
    }

    /// The library (once per document) and the call that turns it on. A page
    /// that already has it just turns it back on.
    /// Built once: the library is large, and every change of a page's
    /// settings adds the script again.
    nonisolated static let enableScript: String? =
        library.map { "if (!window.DarkReader) {\n" + $0 + "\n}\n" + bootstrap }

    static let disableScript = "if (window.DarkReader) { DarkReader.disable(); }"

    static func addScript(to controller: WKUserContentController) {
        guard let source = enableScript else { return }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))
    }

    private static var offSites: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: offSitesKey) ?? [])
    }

    /// `www.example.com` and `example.com` are one site.
    private static func site(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Turns Dark Reader on at once, so the page never flashes white. It is
    /// not turned off for pages that look dark already: having dark-mode
    /// styles is not the same as using them (Wikipedia ships them but stays
    /// light unless its own setting says otherwise), and Dark Reader keeps
    /// an already dark page dark. "On for this site" covers the rest.
    private nonisolated static let bootstrap = """
    (function () {
      if (!window.DarkReader) { return; }
      try { DarkReader.setFetchMethod(window.fetch.bind(window)); } catch (e) {}
      DarkReader.enable({ brightness: 100, contrast: 95, sepia: 0 });
    })();
    """
}

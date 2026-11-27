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

    /// The bundled library, or nil if the build did not include it.
    private static let library: String? = Bundle.main
        .url(forResource: "darkreader", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static var isAvailable: Bool { library != nil }

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
    static var enableScript: String? {
        library.map { "if (!window.DarkReader) {\n" + $0 + "\n}\n" + bootstrap }
    }

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
    private static let bootstrap = """
    (function () {
      if (!window.DarkReader) { return; }
      try { DarkReader.setFetchMethod(window.fetch.bind(window)); } catch (e) {}
      DarkReader.enable({ brightness: 100, contrast: 95, sepia: 0 });
    })();
    """
}

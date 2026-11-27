import Foundation
import WebKit

/// Dark mode for websites, built on Dark Reader's dynamic theme engine (MIT,
/// https://github.com/darkreader/darkreader). The library is fetched by CI at a
/// pinned version (see the workflow) and bundled as `darkreader.js`.
///
/// One global switch, plus a list of sites it is turned off for. Pages that
/// already have their own dark look (they declare `color-scheme: dark` or
/// style `prefers-color-scheme: dark`) keep it: the web view asks for dark,
/// and Dark Reader steps aside.
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

    /// The library and the call that turns it on.
    static var enableScript: String? {
        library.map { $0 + "\n" + bootstrap }
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

    /// Turns Dark Reader on at once, so the page never flashes white, then
    /// turns it off again if the page turns out to have a dark look of its own.
    private static let bootstrap = """
    (function () {
      if (!window.DarkReader) { return; }
      try { DarkReader.setFetchMethod(window.fetch.bind(window)); } catch (e) {}
      DarkReader.enable({ brightness: 100, contrast: 95, sepia: 0 });

      function hasOwnDarkLook() {
        var meta = document.querySelector('meta[name="color-scheme"]');
        if (meta && /\\bdark\\b/.test(meta.content || '')) { return true; }
        var sheets = document.styleSheets;
        for (var i = 0; i < sheets.length; i++) {
          var owner = sheets[i].ownerNode;
          if (owner && owner.classList && owner.classList.contains('darkreader')) { continue; }
          var rules;
          try { rules = sheets[i].cssRules; } catch (e) { continue; }
          if (!rules) { continue; }
          for (var j = 0; j < rules.length; j++) {
            var media = rules[j].media;
            if (media && /prefers-color-scheme\\s*:\\s*dark/.test(media.mediaText)) { return true; }
          }
        }
        return false;
      }

      function check() {
        if (hasOwnDarkLook()) { DarkReader.disable(); }
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', check, { once: true });
      } else {
        check();
      }
    })();
    """
}

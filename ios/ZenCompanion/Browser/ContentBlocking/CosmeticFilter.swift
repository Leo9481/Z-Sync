import Foundation
import WebKit

/// Cosmetic filtering: the `##` rules of the ad lists, which hide what
/// network blocking leaves on a page (empty ad slots, ad boxes, overlays).
/// The rules are matched by Brave's adblock-rust (`rust/zb-adblock`), the
/// same engine Brave uses:
///
/// - When a page starts, its script asks for the page's own rules (its
///   site's `##` rules and exceptions) and hides them with one stylesheet.
/// - Then it reports the classes and ids the page uses, as they appear, and
///   hides those the lists' generic rules name, unless the page's site has
///   a `$generichide` exception.
///
/// Each selector is added on its own, so one the browser can't read doesn't
/// take the others with it. Procedural rules (`:has-text`, …) and scriptlets
/// aren't applied yet.
enum CosmeticFilter {
    static let world = WKContentWorld.world(name: "ZBrowserCosmetic")
    static let handlerName = "zbCosmetic"

    static func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))
    }

    static let script = """
    (function () {
      if (window.__zbCosmetic) { return; }
      window.__zbCosmetic = true;
      var handler = window.webkit.messageHandlers.\(handlerName);
      var style = null;
      var applied = new Set();
      function hide(selectors) {
        if (!selectors || !selectors.length) { return; }
        if (!style || !style.isConnected) {
          style = document.createElement('style');
          (document.head || document.documentElement).appendChild(style);
        }
        var sheet = style.sheet;
        if (!sheet) { return; }
        selectors.forEach(function (selector) {
          if (applied.has(selector)) { return; }
          applied.add(selector);
          try { sheet.insertRule(selector + '{display:none!important}', sheet.cssRules.length); } catch (e) {}
        });
      }

      var exceptions = [];
      var seenClasses = new Set(), seenIds = new Set();
      var newClasses = [], newIds = [];
      var timer = null;
      function note(element) {
        if (element.nodeType !== 1) { return; }
        var id = element.id;
        if (id && !seenIds.has(id)) { seenIds.add(id); newIds.push(id); }
        var list = element.classList;
        if (list) {
          for (var i = 0; i < list.length; i++) {
            var name = list[i];
            if (!seenClasses.has(name)) { seenClasses.add(name); newClasses.push(name); }
          }
        }
      }
      function scan(root) {
        note(root);
        if (root.querySelectorAll) { root.querySelectorAll('[id],[class]').forEach(note); }
      }
      function flush() {
        timer = null;
        if (!newClasses.length && !newIds.length) { return; }
        var request = { op: 'generic', classes: newClasses, ids: newIds, exceptions: exceptions };
        newClasses = []; newIds = [];
        handler.postMessage(request).then(hide, function () {});
      }
      function later() { if (!timer) { timer = setTimeout(flush, 200); } }
      function watchGeneric() {
        function start() {
          scan(document.documentElement);
          flush();
          new MutationObserver(function (records) {
            records.forEach(function (record) {
              if (record.type === 'attributes') { note(record.target); return; }
              record.addedNodes.forEach(function (node) { if (node.nodeType === 1) { scan(node); } });
            });
            later();
          }).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id']
          });
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
          start();
        }
      }

      handler.postMessage({ op: 'page', url: location.href }).then(function (reply) {
        if (!reply) { return; }
        hide(reply.hide);
        if (!reply.generichide) {
          exceptions = reply.exceptions || [];
          watchGeneric();
        }
      }, function () {});
    })();
    """

    /// Answers the page script. Weak to the model, which owns the web view.
    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        private weak var model: MiniBrowserModel?

        init(model: MiniBrowserModel) {
            self.model = model
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let body = message.body as? [String: Any], let model, model.cosmeticFilteringApplies else {
                replyHandler(nil, nil)
                return
            }
            switch body["op"] as? String {
            case "page":
                guard let url = body["url"] as? String else { replyHandler(nil, nil); return }
                CosmeticEngine.shared.pageResources(for: url) { resources in
                    Task { @MainActor in replyHandler(resources, nil) }
                }
            case "generic":
                let request: [String: Any] = [
                    "classes": body["classes"] as? [String] ?? [],
                    "ids": body["ids"] as? [String] ?? [],
                    "exceptions": body["exceptions"] as? [String] ?? [],
                ]
                CosmeticEngine.shared.genericSelectors(request) { selectors in
                    Task { @MainActor in replyHandler(selectors, nil) }
                }
            default:
                replyHandler(nil, nil)
            }
        }
    }
}

/// The adblock-rust engine, used from one serial queue. Built in the
/// background from the ad lists each time they load; pages opened before it
/// is ready get no cosmetic filtering.
final class CosmeticEngine: @unchecked Sendable {
    static let shared = CosmeticEngine()

    private let queue = DispatchQueue(label: "io.github.leo9481.zenbrowser.cosmetic", qos: .userInitiated)
    private var engine: OpaquePointer?

    /// Replaces the engine with one built from `listText` (lists joined by newlines).
    func load(_ listText: String) {
        queue.async {
            let built = listText.withCString { zb_engine_new($0) }
            if let old = self.engine { zb_engine_free(old) }
            self.engine = built
        }
    }

    /// The page's own hiding rules: `["hide": [...], "exceptions": [...], "generichide": Bool]`.
    func pageResources(for url: String, completion: @escaping @Sendable ([String: Any]?) -> Void) {
        queue.async {
            guard let engine = self.engine,
                  let json = url.withCString({ zb_engine_url_cosmetic(engine, $0) })
            else { completion(nil); return }
            let text = String(cString: json)
            zb_string_free(json)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                completion(nil)
                return
            }
            completion([
                "hide": object["hide_selectors"] as? [String] ?? [],
                "exceptions": object["exceptions"] as? [String] ?? [],
                "generichide": object["generichide"] as? Bool ?? false,
            ])
        }
    }

    /// Generic selectors for a page's classes and ids.
    func genericSelectors(_ request: [String: Any], completion: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            guard let engine = self.engine,
                  let data = try? JSONSerialization.data(withJSONObject: request),
                  let json = String(decoding: data, as: UTF8.self).withCString({ zb_engine_hidden_selectors(engine, $0) })
            else { completion([]); return }
            let text = String(cString: json)
            zb_string_free(json)
            completion((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] ?? [])
        }
    }
}

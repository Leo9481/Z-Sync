import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Where the page on screen stands with translation.
enum PageTranslationState: Equatable {
    case original
    case working
    case translated
    case sameLanguage
    case failed(String)
}

/// The text collected from one page, waiting for Apple's translation session.
/// Each text's index is the id the page script knows its text node by.
struct PageTranslationJob: Equatable {
    let id = UUID()
    /// BCP-47 code of the page's language, as detected on the device.
    let source: String
    let texts: [String]
}

/// Collects a page's visible text and writes translations back in place,
/// keeping every original so "Show original" puts them back exactly.
/// Runs in its own world: the page cannot see or change it.
enum PageTranslationScript {
    static let world = WKContentWorld.world(name: "ZBrowserTranslate")

    /// Returns the texts, in document order. A second run starts from the
    /// originals, so it never translates a translation.
    static let collect = """
    var Z = window.__zbTranslate;
    if (!Z) { Z = window.__zbTranslate = { nodes: [], originals: [] }; }
    if (Z.observer) { Z.observer.disconnect(); Z.observer = null; }
    for (var k = 0; k < Z.nodes.length; k++) { Z.nodes[k].nodeValue = Z.originals[k]; }
    Z.nodes = []; Z.originals = []; Z.index = new Map(); Z.written = new Map();
    var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1, TEXTAREA: 1, INPUT: 1,
                 SELECT: 1, OPTION: 1, SVG: 1, MATH: 1, KBD: 1, SAMP: 1, VAR: 1 };
    var letter = /\\p{L}/u;
    Z.accept = function (node) {
      if (!letter.test(node.nodeValue || '')) { return NodeFilter.FILTER_REJECT; }
      for (var e = node.parentElement; e; e = e.parentElement) {
        if (skip[e.tagName.toUpperCase()]) { return NodeFilter.FILTER_REJECT; }
        if (e.getAttribute('translate') === 'no' || e.classList.contains('notranslate')) {
          return NodeFilter.FILTER_REJECT;
        }
        if (e.isContentEditable) { return NodeFilter.FILTER_REJECT; }
      }
      return NodeFilter.FILTER_ACCEPT;
    };
    var root = document.body || document.documentElement;
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: Z.accept });
    var out = [];
    var node;
    while ((node = walker.nextNode()) && Z.nodes.length < 5000) {
      Z.index.set(node, Z.nodes.length);
      Z.nodes.push(node);
      Z.originals.push(node.nodeValue);
      out.push(node.nodeValue.trim());
    }
    return out;
    """

    static let handlerName = "zbTranslate"

    /// After the first pass: watches the page for text it adds or changes
    /// (infinite scroll, a feed, a menu opening) and reports it in small
    /// batches, a moment after the page settles. Text this script wrote
    /// itself is recognised and left alone.
    static let observe = """
    var Z = window.__zbTranslate;
    if (!Z || !Z.accept) { return 0; }
    if (Z.observer) { Z.observer.disconnect(); }
    var pending = new Set();
    var timer = null;
    function flush() {
      timer = null;
      var ids = [], texts = [];
      pending.forEach(function (node) {
        if (!node.isConnected) { return; }
        var value = node.nodeValue || '';
        var idx = Z.index.get(node);
        if (idx !== undefined) {
          if (Z.written.get(node) === value) { return; }
          Z.originals[idx] = value;
        } else {
          if (Z.nodes.length >= 20000) { return; }
          if (Z.accept(node) !== NodeFilter.FILTER_ACCEPT) { return; }
          idx = Z.nodes.length;
          Z.index.set(node, idx);
          Z.nodes.push(node);
          Z.originals.push(value);
        }
        if (!/\\p{L}/u.test(value)) { return; }
        ids.push(idx);
        texts.push(value.trim());
      });
      pending.clear();
      if (ids.length) {
        window.webkit.messageHandlers.\(handlerName).postMessage({ ids: ids, texts: texts });
      }
    }
    Z.observer = new MutationObserver(function (records) {
      records.forEach(function (r) {
        if (r.type === 'characterData') { pending.add(r.target); return; }
        r.addedNodes.forEach(function (n) {
          if (n.nodeType === 3) { pending.add(n); }
          else if (n.nodeType === 1) {
            var w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT);
            var t;
            while ((t = w.nextNode())) { pending.add(t); }
          }
        });
      });
      if (!timer) { timer = setTimeout(flush, 400); }
    });
    Z.observer.observe(document.body || document.documentElement,
                       { childList: true, subtree: true, characterData: true });
    return 1;
    """

    /// Receives the text the page adds while it is translated.
    final class Handler: NSObject, WKScriptMessageHandler {
        private weak var model: MiniBrowserModel?

        init(model: MiniBrowserModel) {
            self.model = model
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let ids = body["ids"] as? [Int],
                  let texts = body["texts"] as? [String],
                  ids.count == texts.count else { return }
            let batch = PageTextBatch(ids: ids, texts: texts)
            Task { @MainActor [weak model] in
                model?.receiveNewPageText(batch)
            }
        }
    }

    /// Arguments: `ids` and `texts`, the same length. Keeps each node's own
    /// leading and trailing spaces, so words do not run together.
    static let apply = """
    var Z = window.__zbTranslate;
    if (!Z) { return 0; }
    for (var i = 0; i < ids.length; i++) {
      var node = Z.nodes[ids[i]];
      if (!node) { continue; }
      var original = Z.originals[ids[i]];
      var lead = original.match(/^\\s*/)[0];
      var trail = original.match(/\\s*$/)[0];
      var value = lead + texts[i] + trail;
      if (Z.written) { Z.written.set(node, value); }
      node.nodeValue = value;
    }
    return ids.length;
    """

    static let restore = """
    var Z = window.__zbTranslate;
    if (!Z) { return 0; }
    if (Z.observer) { Z.observer.disconnect(); Z.observer = null; }
    for (var k = 0; k < Z.nodes.length; k++) { Z.nodes[k].nodeValue = Z.originals[k]; }
    Z.nodes = []; Z.originals = []; Z.index = new Map(); Z.written = new Map();
    return 0;
    """
}

/// Text the page added or changed while translated, by node id.
struct PageTextBatch: Sendable {
    let ids: [Int]
    let texts: [String]
}

extension MiniBrowserModel {
    /// The on-device translation session needs iOS 18.
    static var canTranslate: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    var isTranslationOn: Bool {
        translation == .translated || translation == .working
    }

    func toggleTranslation() {
        if isTranslationOn { showOriginalText() } else { startTranslation() }
    }

    /// Collects the page's text and detects its language. The translation
    /// itself runs in `runTranslation`, once the view hands over a session.
    func startTranslation() {
        guard let webView else { return }
        translation = .working
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(
                    PageTranslationScript.collect,
                    arguments: [:],
                    in: nil,
                    contentWorld: PageTranslationScript.world
                )
                let texts = (result as? [String]) ?? []
                guard translation == .working else { return }
                guard !texts.isEmpty else {
                    translation = .failed("Nothing to translate on this page.")
                    return
                }
                let sample = String(texts.prefix(300).joined(separator: " ").prefix(6000))
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(sample)
                guard let language = recognizer.dominantLanguage else {
                    translation = .failed("Couldn't tell what language this page is in.")
                    return
                }
                let pageLanguage = Locale.Language(identifier: language.rawValue).languageCode
                let myLanguage = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en").languageCode
                if pageLanguage != nil, pageLanguage == myLanguage {
                    translation = .sameLanguage
                    restoreOriginalText()
                    return
                }
                translationJob = PageTranslationJob(source: language.rawValue, texts: texts)
            } catch {
                translation = .failed("This page can't be translated.")
            }
        }
    }

    func showOriginalText() {
        stopTranslationFeed()
        translationJob = nil
        translation = .original
        restoreOriginalText()
    }

    /// A new document: nothing on it is translated.
    func resetTranslation() {
        stopTranslationFeed()
        translationJob = nil
        translation = .original
    }

    /// Text the translated page added, from the page script.
    func receiveNewPageText(_ batch: PageTextBatch) {
        translationFeed?.yield(batch)
    }

    private func stopTranslationFeed() {
        translationFeed?.finish()
        translationFeed = nil
    }

    private func restoreOriginalText() {
        webView?.callAsyncJavaScript(
            PageTranslationScript.restore,
            arguments: [:],
            in: nil,
            in: PageTranslationScript.world,
            completionHandler: nil
        )
    }

    /// Translates the collected texts in batches and writes each batch back
    /// as soon as it is done, so the top of the page changes first.
    @available(iOS 18.0, *)
    func runTranslation(_ session: TranslationSession) async {
        guard let job = translationJob, let webView else { return }
        do {
            try await translate(
                PageTextBatch(ids: Array(job.texts.indices), texts: job.texts),
                job: job,
                session: session,
                in: webView
            )
            guard translationJob?.id == job.id else { return }
            translation = .translated
        } catch {
            guard translationJob?.id == job.id else { return }
            translationJob = nil
            translation = .failed("Translation didn't work: the language may not be supported or downloaded.")
            restoreOriginalText()
            return
        }

        // The session stays open while the page is translated: what the page
        // adds later (scrolling, a feed, a menu) is translated as it comes.
        let (stream, feed) = AsyncStream.makeStream(of: PageTextBatch.self)
        stopTranslationFeed()
        translationFeed = feed
        do {
            _ = try await webView.callAsyncJavaScript(
                PageTranslationScript.observe,
                arguments: [:],
                in: nil,
                contentWorld: PageTranslationScript.world
            )
        } catch {
            return
        }
        for await batch in stream {
            guard translationJob?.id == job.id else { break }
            // One batch failing (a stray phrase in another language) does
            // not stop the rest of the page.
            try? await translate(batch, job: job, session: session, in: webView)
        }
    }

    /// Translates `batch` in chunks and writes each chunk back as it is done.
    @available(iOS 18.0, *)
    private func translate(
        _ batch: PageTextBatch,
        job: PageTranslationJob,
        session: TranslationSession,
        in webView: WKWebView
    ) async throws {
        let size = 60
        for start in stride(from: 0, to: batch.ids.count, by: size) {
            let range = start..<min(start + size, batch.ids.count)
            let requests = range.map {
                TranslationSession.Request(sourceText: batch.texts[$0], clientIdentifier: String(batch.ids[$0]))
            }
            let responses = try await session.translations(from: requests)
            guard translationJob?.id == job.id else { return }
            var doneIDs: [Int] = []
            var doneTexts: [String] = []
            for response in responses {
                guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
                doneIDs.append(id)
                doneTexts.append(response.targetText)
            }
            _ = try await webView.callAsyncJavaScript(
                PageTranslationScript.apply,
                arguments: ["ids": doneIDs, "texts": doneTexts],
                in: nil,
                contentWorld: PageTranslationScript.world
            )
        }
    }
}

/// Hands the page on screen a translation session whenever it asks for one.
/// Apple's framework shows its own prompt to download a language if needed.
struct PageTranslationTask: ViewModifier {
    var model: MiniBrowserModel

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(PageTranslationSessionHost(model: model))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct PageTranslationSessionHost: ViewModifier {
    var model: MiniBrowserModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await model.runTranslation(session)
            }
            .onChange(of: model.translationJob?.id) { _, _ in
                guard let job = model.translationJob else { return }
                let source = Locale.Language(identifier: job.source)
                if configuration?.source == source {
                    // Same languages: run the session again for this job.
                    configuration?.invalidate()
                } else {
                    // No target: the framework uses the reader's own language.
                    configuration = TranslationSession.Configuration(source: source, target: nil)
                }
            }
    }
}

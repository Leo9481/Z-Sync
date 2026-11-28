import WebKit

/// Small page scripts of our own, applied wherever Ads blocking is on, for ad
/// engines that arrive as code written into the page itself: no address to
/// block, so the lists can't reach them. Each one is the same trick uBlock
/// Origin's scriptlets use, aimed at a name only that ad engine uses.
enum BuiltInScriptlets {
    static func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            // Ad engines run in players' frames too.
            forMainFrameOnly: false,
            // In the page's own world: the trap has to be on the page's `window`.
            in: .page
        ))
    }

    /// Adcash's engine, often pasted straight into the page, keeps itself in
    /// `window.aclib` and shows its popunders and in-page "notifications"
    /// through it (`aclib.runPop`, `aclib.runAutoTag`). uBlock Origin stops it
    /// with "abort on property read" on some streaming sites; this does the
    /// same everywhere: storing it does nothing, reading it throws, so the
    /// engine's calls fail before they show anything.
    static let source = """
    (function () {
      try {
        var existing = Object.getOwnPropertyDescriptor(window, 'aclib');
        if (existing && !existing.configurable) { return; }
        Object.defineProperty(window, 'aclib', {
          configurable: false,
          get: function () { throw new ReferenceError('aclib is not defined'); },
          set: function () {}
        });
      } catch (e) {}
    })();
    """
}

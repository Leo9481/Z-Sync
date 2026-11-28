import Foundation
import QuartzCore

/// Popups and redirects a page makes on its own, without a tap: a page can
/// still open windows and send you elsewhere when you ask it to.
///
/// WebKit already refuses `window.open` without any touch. What gets through
/// is a script that rides on a tap to open another site, and a page that
/// sends you to another site later, with no tap at all. Both are stopped
/// here, each with a notice that can open the address anyway.
enum PopupBlocking {
    /// A touch this recent is what the page is answering. Generous: a
    /// sign-in button may wait on the network before it redirects.
    static let touchWindow: CFTimeInterval = 5
    /// A page just loaded may still be finishing its own redirect (a link
    /// shortener, a sign-in hand-off).
    static let settleTime: CFTimeInterval = 3

    /// A new window from a script, to another site, that isn't sized like a
    /// sign-in or payment window. A tapped `target=_blank` link, a window on
    /// the page's own site, a sized window and a blank window all open.
    static func blocksPopup(linkTapped: Bool, from page: URL?, to target: URL, sized: Bool) -> Bool {
        guard !linkTapped, !sized,
              let targetHost = target.host, !targetHost.isEmpty,
              let pageHost = page?.host, !pageHost.isEmpty
        else { return false }
        return !BlockList.isSameSite(pageHost, targetHost)
    }

    /// A page that, once loaded and with no touch, sends the tab to another
    /// site. Loading, the app's own loads, a recent touch and the same site
    /// all go through.
    static func blocksRedirect(
        from page: URL?,
        to target: URL,
        navigationInFlight: Bool,
        pageFinishedAt: CFTimeInterval,
        lastTouchAt: CFTimeInterval,
        appLoadAt: CFTimeInterval
    ) -> Bool {
        let now = CACurrentMediaTime()
        guard !navigationInFlight,
              pageFinishedAt > 0, now - pageFinishedAt > settleTime,
              now - lastTouchAt > touchWindow,
              now - appLoadAt > touchWindow,
              let targetHost = target.host, !targetHost.isEmpty,
              let pageHost = page?.host, !pageHost.isEmpty
        else { return false }
        return !BlockList.isSameSite(pageHost, targetHost)
    }
}

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let root = ShareChoiceView(
            itemProviders: extensionItemProviders,
            pageTitle: sharedPageTitle,
            openInApp: { [weak self] url in self?.openContainingApp(url) ?? false }
        ) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            let error = NSError(domain: "de.kjell.zencompanion", code: NSUserCancelledError)
            self?.extensionContext?.cancelRequest(withError: error)
        }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    /// The width is only final once the sheet is laid out.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = CGSize(width: view.bounds.width, height: 560)
        guard size.width > 0, preferredContentSize != size else { return }
        preferredContentSize = size
    }

    /// Opens Z-Browser with `url`. A share extension has no official way to
    /// open its app, so this finds the app object along the responder chain
    /// and calls its `open(_:options:completionHandler:)` through the
    /// Objective-C runtime (the method is marked unavailable to extensions).
    /// It may stop working in a later iOS; the caller then keeps the link for
    /// the app to open the next time it comes to the front.
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (
                    AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
                ) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private var extensionItems: [NSExtensionItem] {
        (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    }

    private var extensionItemProviders: [NSItemProvider] {
        extensionItems.flatMap { $0.attachments ?? [] }
    }

    /// `attributedContentText` is the URL or a text selection, not the tab title.
    private var sharedPageTitle: String {
        for item in extensionItems {
            if let title = item.attributedTitle?.string, !title.isEmpty { return title }
        }
        return ""
    }
}

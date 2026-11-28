import Foundation
import SwiftUI

/// The ☁ button's side of a page: whether it is saved in Raindrop, saving
/// it to a collection, and taking it out again.
extension MiniBrowserModel {
    /// Asks Raindrop once per page whether it is already saved, so ☁ shows it.
    func checkRaindrop() {
        guard RaindropSettings.shared.isConnected, !isPrivate,
              let url = effectiveURL, url.scheme == "http" || url.scheme == "https",
              url != raindropCheckedURL
        else { return }
        raindropCheckedURL = url
        Task {
            let ids = (try? await RaindropAPI.savedIDs(for: url)) ?? []
            guard effectiveURL == url else { return }
            raindropID = ids.first
        }
    }

    /// Tap on ☁: saves the page to the chosen collection, or takes it out
    /// again when it is already saved.
    func toggleRaindrop() {
        if let id = raindropID {
            removeFromRaindrop(id)
        } else {
            saveToRaindrop(collection: RaindropSettings.shared.defaultCollectionID)
        }
    }

    func saveToRaindrop(collection: Int) {
        guard RaindropSettings.shared.isConnected else {
            showNotice("Add your Raindrop token in Settings → Raindrop", symbol: "cloud")
            return
        }
        guard let url = effectiveURL, url.scheme == "http" || url.scheme == "https", !raindropSaving else { return }
        raindropSaving = true
        let title = pageTitle
        Task {
            defer { raindropSaving = false }
            do {
                let id = try await RaindropAPI.save(url, title: title, to: collection)
                if effectiveURL == url { raindropID = id }
                AppServices.haptics.pinSucceeded()
                showNotice("Saved to \(RaindropSettings.shared.name(of: collection))", symbol: "cloud.fill")
            } catch {
                showNotice(error.localizedDescription, symbol: "exclamationmark.icloud")
            }
        }
    }

    private func removeFromRaindrop(_ id: Int) {
        guard !raindropSaving else { return }
        raindropSaving = true
        Task {
            defer { raindropSaving = false }
            do {
                try await RaindropAPI.remove(id)
                raindropID = nil
                showNotice("Removed from Raindrop", symbol: "cloud")
            } catch {
                showNotice(error.localizedDescription, symbol: "exclamationmark.icloud")
            }
        }
    }
}

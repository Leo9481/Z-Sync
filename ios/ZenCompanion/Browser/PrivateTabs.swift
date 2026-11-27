import LocalAuthentication
import Observation
import SwiftUI

/// The private section's settings (Settings → Pages & tabs) and its lock.
///
/// - Lock private tabs: Face ID, Touch ID or the device passcode every time
///   the private section is opened, and again after the app has been in the
///   background. No grace period.
/// - Keep private tabs: off, private tabs close when the reader goes back to
///   normal tabs or the app ends. On, the list of private tabs (address and
///   title only) stays; every tab still starts with empty website data.
@MainActor
@Observable
final class PrivateTabsSettings {
    static let shared = PrivateTabsSettings()

    private enum Key {
        static let lock = "privateTabs.lock"
        static let keep = "privateTabs.keep"
    }

    var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: Key.lock) }
    }

    var keepTabs: Bool {
        didSet {
            UserDefaults.standard.set(keepTabs, forKey: Key.keep)
            // Written or taken off the disk at once, not at the next change.
            OpenPagesStore.shared.writeKeptPages()
        }
    }

    /// Unlocked for this visit to the private section.
    private(set) var isUnlocked = false
    /// The lock asked once since it last locked; it does not ask again by
    /// itself after the reader cancels.
    var askedSinceLocked = false

    private init() {
        lockEnabled = UserDefaults.standard.bool(forKey: Key.lock)
        keepTabs = UserDefaults.standard.bool(forKey: Key.keep)
    }

    /// Whether the private section may show now.
    var allowsPrivateSection: Bool { !lockEnabled || isUnlocked }

    /// Locks again: leaving the private section, or the app going away.
    func lock() {
        isUnlocked = false
        askedSinceLocked = false
    }

    /// Asks for Face ID / Touch ID or the passcode. A phone without a passcode
    /// cannot lock anything, so the section opens.
    func unlock() async -> Bool {
        guard lockEnabled else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your private tabs"
            )
            isUnlocked = ok
            return ok
        } catch {
            return false
        }
    }
}

/// Over the private section while it is locked, and in the app switcher: the
/// tabs never show without the lock.
struct PrivateTabsLockCover: View {
    var onUnlock: () -> Void
    var onLeave: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThickMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                Text(verbatim: "Private tabs are locked")
                    .zenFont(19, weight: .semibold, design: .rounded)
                Button(action: onUnlock) {
                    Text(verbatim: "Unlock")
                        .zenFont(16, weight: .semibold, design: .rounded)
                        .padding(.horizontal, 28)
                        .frame(height: 46)
                        .floatingGlassCapsule()
                }
                .buttonStyle(.plain)
                Button(action: onLeave) {
                    Text(verbatim: "Back to tabs")
                        .zenFont(15, weight: .medium, design: .rounded)
                        .opacity(0.75)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

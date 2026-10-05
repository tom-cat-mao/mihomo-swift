import AppKit
import Foundation
import KumoCoreKit

/// Single bridge that lets `NSApplicationDelegate` reach the SwiftUI-owned
/// `KumoAppStore`. The store is created in `KumoApp.init` and attached there
/// during launch, so any non-SwiftUI hook (`NSApp.servicesProvider`, dock
/// badge timer, Spotlight handlers, App Intents) can resolve the live store
/// via `KumoAppContext.shared.store` even when no view has appeared yet — for
/// example a Shortcuts cold launch with `openAppWhenRun = false`. The root
/// view re-attaches the same store from its `.task`; `attach` ignores repeat
/// attaches.
@MainActor
final class KumoAppContext {
    static let shared = KumoAppContext()

    private(set) var store: KumoAppStore?
    private var openMainWindowAction: (() -> Void)?
    private var openSettingsAction: (() -> Void)?
    private var openAboutWindowAction: (() -> Void)?

    /// Internal rather than private so tests can exercise attach semantics on
    /// an isolated instance; the app itself always uses `shared`.
    init() {}

    /// Attaches the app's one live store. The first attach wins: a repeat
    /// attach — including the view-side one — must never replace the store
    /// the app is already using.
    func attach(store: KumoAppStore) {
        guard self.store == nil else { return }
        self.store = store
    }

    func attachWindowActions(
        openMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openAboutWindow: @escaping () -> Void
    ) {
        openMainWindowAction = openMainWindow
        openSettingsAction = openSettings
        openAboutWindowAction = openAboutWindow
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: isMainWindow(_:)) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openMainWindowAction?()
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func openAboutWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "About Kumo" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openAboutWindowAction?()
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        guard window.canBecomeMain else {
            return false
        }
        if window.title == "Kumo" {
            return true
        }
        return SidebarDestination.allCases.contains { $0.rawValue == window.title }
    }

    /// Handle a continued `NSUserActivity` (Spotlight tap, Handoff). Returns
    /// `true` when the activity was recognised and dispatched to the store.
    func handleUserActivity(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == "io.kumo.KumoApp.openProfile" else {
            return false
        }
        guard let userInfo = activity.userInfo,
              let identifier = userInfo["profileID"] as? String,
              let store else {
            return false
        }
        Task {
            await store.refreshProfiles()
            if let target = store.profiles.first(where: { $0.id == identifier }) {
                await store.selectProfile(target)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

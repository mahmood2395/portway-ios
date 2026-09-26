// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.

import BackgroundTasks
import LocalAuthentication
import SwiftUI
import UserNotifications
import PortwayCore
import PortwayKit

@main
struct PortwayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.store)
                // The language applies immediately: re-identify the tree so every L.tr re-reads.
                .id(app.languageRevision)
                .environment(\.layoutDirection, L.isRTL ? .rightToLeft : .leftToRight)
                .environment(\.locale, L.locale)
                .preferredColorScheme(app.colorScheme)
                .onOpenURL { app.open($0) }
                .task { await app.launch() }
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }
}

// MARK: - App state

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Tab: Hashable { case home, configs, settings }

    let store = TunnelStore()
    var tab: Tab = .home
    /// Config detail screens pushed over the tabs, by name.
    var path: [String] = []
    var languageRevision = 0
    var themeRevision = 0
    var showOnboarding = !PortwaySettings.shared.onboardingDone
    /// Configs waiting on the confirmation screen (from a link, a file, a QR code or paste). A new
    /// batch is a new identity, so a second link opened while the sheet is up re-creates the sheet
    /// rather than showing the new config under the old one's name.
    var pendingImport: ImportBatch?
    /// Kept here, not in the view: switching language re-creates the view tree.
    var onboardingStep = 0
    var importError: String?
    /// A one-tap link is being exchanged for its config.
    var redeeming = false
    var locked = PortwaySettings.shared.appLock

    var colorScheme: ColorScheme? {
        _ = themeRevision
        switch PortwaySettings.shared.themeMode {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func launch() async {
        if locked { LockWindow.shared.show() }
        #if DEBUG
        // Screenshot helpers: -fa / -en pick the language, -onboarding shows the first run.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-fa") { setLanguage(.fa) } else if args.contains("-en") { setLanguage(.en) }
        if args.contains("-light") { setTheme(.light) } else if args.contains("-dark") { setTheme(.dark) }
        if Demo.isOn { showOnboarding = args.contains("-onboarding") }
        if let step = args.first(where: { $0.hasPrefix("-step=") }).flatMap({ Int($0.dropFirst(6)) }) { onboardingStep = step }
        if let tab = args.first(where: { $0.hasPrefix("-tab=") })?.dropFirst(5) {
            self.tab = tab == "configs" ? .configs : tab == "settings" ? .settings : .home
        }
        if let link = args.first(where: { $0.hasPrefix("-open=") })?.dropFirst(6), let url = URL(string: String(link)) {
            Task { try? await Task.sleep(nanoseconds: 500_000_000); open(url) }
        }
        if let detail = args.first(where: { $0.hasPrefix("-detail=") })?.dropFirst(8) {
            Task { try? await Task.sleep(nanoseconds: 300_000_000); path = [String(detail)] }
        }
        #endif
        Notices.registerCategories()
        await store.reload()
        Task { await store.registerAll() }
        await store.checkForUpdate()
        AppDelegate.scheduleRefresh()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            store.pausePolling()
            if PortwaySettings.shared.appLock {
                locked = true
                LockWindow.shared.show()
            }
        case .active:
            store.resumePolling()
            // Only now can Face ID show; asking while backgrounded left a bare Unlock button.
            if locked { Task { await unlock() } }
            Task { await store.reload() }
        default:
            break
        }
    }

    func setLanguage(_ language: AppLanguage) {
        PortwaySettings.shared.language = language
        Notices.registerCategories()
        languageRevision += 1
    }

    func setTheme(_ mode: ThemeMode) {
        PortwaySettings.shared.themeMode = mode
        themeRevision += 1
    }

    // MARK: Import entry points

    func open(_ url: URL) {
        if url.isFileURL {
            importFile(url)
            return
        }
        if let token = DeepLink.token(in: url) {
            redeem(token)
            return
        }
        switch ConfigImporter.candidate(fromLink: url) {
        case .success(let candidate): stage([candidate])
        case .failure: importError = L.tr("deep_link_import_error")
        }
    }

    /// One-tap link: exchange the token for the config, then the usual confirmation screen.
    private func redeem(_ token: DeepLink.Token) {
        guard !redeeming else { return }
        redeeming = true
        Task {
            defer { redeeming = false }
            switch await ImportRedeemer.redeem(token) {
            case .success(let payload):
                importText(payload.configText, name: payload.suggestedName)
            case .failure(.expired):
                importError = L.tr("import_link_expired")
            case .failure(.unknown):
                importError = L.tr("import_link_unknown")
            case .failure(.unavailable):
                importError = L.tr("import_link_unavailable")
            }
        }
    }

    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            // "Open in Portway" hands us a COPY in Documents/Inbox. It holds a private key in
            // plain text and would sit there, and in backups, forever.
            if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        // Size first: reading a huge file only to reject it would spike memory.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4 * 1024 * 1024 {
            importError = L.tr("import_too_large_error")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            importError = L.tr("not_a_config_error")
            return
        }
        switch ConfigImporter.candidates(fromFile: data, fileName: url.lastPathComponent) {
        case .success(let found): stage(found)
        case .failure(let error): importError = Self.describe(error)
        }
    }

    func importText(_ text: String, name: String? = nil) {
        switch ConfigImporter.candidate(text: text, name: name) {
        case .success(let c): stage([c])
        case .failure(let error): importError = Self.describe(error)
        }
    }

    private func stage(_ candidates: [ImportCandidate]) {
        showOnboarding = false
        PortwaySettings.shared.onboardingDone = true
        pendingImport = ImportBatch(candidates: candidates)
    }

    static func describe(_ error: ImportError) -> String {
        switch error {
        case .tooLarge: return L.tr("import_too_large_error")
        case .notAConfig: return L.tr("not_a_config_error")
        case .invalid(let reason): return reason
        case .link: return L.tr("deep_link_import_error")
        }
    }

    // MARK: Lock

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        // Device passcode as the fallback: a lock the owner cannot open is worse than none.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L.tr("app_lock_reason"))) == true {
            locked = false
        }
        if !locked { LockWindow.shared.hide() }
    }
}

struct ImportBatch: Identifiable {
    let id = UUID()
    let candidates: [ImportCandidate]
}

/// The app lock, in its own window above everything — sheets and full-screen covers included.
///
/// A view inside the root cannot cover them: an editor showing a private key, or an import sheet
/// opened by a link, would sit on top of the lock. A separate window at alert level covers all of
/// it, and as the key window it also keeps VoiceOver from reaching the app beneath.
@MainActor
final class LockWindow {
    static let shared = LockWindow()
    private var window: UIWindow?

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = UIHostingController(rootView: LockView().environment(AppState.shared))
        w.rootViewController?.view.backgroundColor = .clear
        w.makeKeyAndVisible()
        window = w
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

// MARK: - Delegate: notification actions and background refresh

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var refreshID: String { PortwayEnvironment.appBundleID + ".refresh" }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.handleRefresh(task)
        }
        return true
    }

    /// "Use here instead" from a conflict or superseded notice: take the session over.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Notices.takeoverAction,
              let tunnel = response.notification.request.content.userInfo[Notices.tunnelKey] as? String else { return }
        if let managers = try? await VPNControl.managers(),
           let up = managers.first(where: { $0.connection.status.isActiveOrPending }) {
            await VPNControl.disconnect()
            _ = await VPNControl.waitForStatus(up.connection, .disconnected, timeout: 10)
        }
        try? await VPNControl.connect(named: tunnel, gate: .takeover)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    // Twice a day, best effort: keep account figures and expiry warnings fresh for a user whose
    // tunnel is down (the extension covers the case where it is up).
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            let store = AppState.shared.store
            await store.reload()
            for item in store.items { await store.refreshAccount(item) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

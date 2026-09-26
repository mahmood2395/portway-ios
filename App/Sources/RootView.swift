// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Three destinations — Home · Configs · Settings — under a flat bar on the ground: no fill, no
// radius, a fading rule across the top, and an 18×2 accent mark over the active item. The mark is
// the static cue; the colour change is not the only signal.

import SwiftUI
import PortwayCore
import PortwayKit

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(TunnelStore.self) private var store

    var body: some View {
        @Bindable var app = app
        @Bindable var store = store
        ZStack {
            PW.ground.ignoresSafeArea()
            if app.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                NavigationStack(path: $app.path) {
                    VStack(spacing: 0) {
                        Group {
                            switch app.tab {
                            case .home: HomeView()
                            case .configs: ConfigsView()
                            case .settings: SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TabBar(selection: $app.tab)
                    }
                    .background(PW.ground)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: String.self) { name in ConfigDetailView(name: name) }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.showOnboarding)
        // Not while locked: a link opened on a locked app waits for the unlock.
        .sheet(item: Binding(get: { app.locked ? nil : app.pendingImport }, set: { app.pendingImport = $0 })) { batch in
            ImportConfirmView(candidates: batch.candidates)
        }
        .alert(L.tr("import_error_title"), isPresented: Binding(get: { app.importError != nil }, set: { if !$0 { app.importError = nil } })) {
            Button(L.tr("ok"), role: .cancel) {}
        } message: { Text(app.importError ?? "") }
        .alert(L.tr("error_title"), isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button(L.tr("ok"), role: .cancel) {}
        } message: { Text(store.alert ?? "") }
        .confirmationDialog(conflictTitle, isPresented: Binding(get: { store.conflict != nil }, set: { if !$0 { store.conflict = nil } }),
                            titleVisibility: .visible, presenting: store.conflict) { conflict in
            Button(L.tr("session_use_here")) { Task { await store.connect(conflict.item, takeover: true) } }
            Button(L.tr("cancel"), role: .cancel) {}
        } message: { conflict in
            Text(L.tr("session_dialog_message", conflict.item.name.isolated,
                      (conflict.otherDevice ?? L.tr("session_other_device_unknown")).isolated))
        }
        .tint(PW.accent)
    }

    private var conflictTitle: String { L.tr("session_dialog_title") }
}

private struct TabBar: View {
    @Binding var selection: AppState.Tab

    var body: some View {
        VStack(spacing: 0) {
            FadingRule()
            HStack(spacing: 0) {
                item(.home, "shield", L.tr("nav_home"))
                item(.configs, "mappin.and.ellipse", L.tr("nav_configs"))
                item(.settings, "gearshape", L.tr("settings"))
            }
            .padding(.horizontal, PW.gutter)
            .padding(.top, 9)
            .padding(.bottom, 4)
        }
        .background(PW.ground)
    }

    private func item(_ tab: AppState.Tab, _ icon: String, _ label: String) -> some View {
        let active = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 6) {
                Rectangle()
                    .fill(active ? PW.accent : .clear)
                    .frame(width: 18, height: 2)
                Image(systemName: active ? icon + ".fill" : icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(active ? PW.accent300 : PW.iconMuted)
                    .frame(height: 24)
                Text(label)
                    .font(PW.font(11, .medium))
                    .foregroundStyle(active ? PW.accent300 : PW.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct LockView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            PW.ground.ignoresSafeArea()
            VStack(spacing: 24) {
                ArchMark().frame(width: 56, height: 56)
                Button(L.tr("app_lock_unlock")) { Task { await app.unlock() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 220)
            }
        }
    }
}

/// The portway arch: an archway with a flush sill, one even-odd fill. The same path as the icon.
struct ArchMark: View {
    var color: Color = PW.accent300
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 108
            var p = Path()
            p.move(to: CGPoint(x: 36 * s, y: 80 * s))
            p.addLine(to: CGPoint(x: 36 * s, y: 48 * s))
            p.addArc(center: CGPoint(x: 54 * s, y: 48 * s), radius: 18 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 72 * s, y: 80 * s))
            p.closeSubpath()
            p.move(to: CGPoint(x: 44 * s, y: 72 * s))
            p.addLine(to: CGPoint(x: 44 * s, y: 48 * s))
            p.addArc(center: CGPoint(x: 54 * s, y: 48 * s), radius: 10 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 64 * s, y: 72 * s))
            p.closeSubpath()
            // The glyph's box is x 36…72, y 30…80 of the 108 canvas: scale its height to the frame
            // and centre it horizontally.
            let k: CGFloat = 108 / 50
            let fitted = p.applying(CGAffineTransform(translationX: -36 * s, y: -30 * s)
                .concatenating(.init(scaleX: k, y: k))
                .concatenating(.init(translationX: (108 - 36 * k) / 2 * s, y: 0)))
            context.fill(fitted, with: .color(color), style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}

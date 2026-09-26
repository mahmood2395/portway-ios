// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// First run: a consumer who was handed a config has no idea what WireGuard is. Four screens, each
// one sentence of honesty, no illustrations.
//
// The third screen is iOS-specific and required: App Store guideline 5.4 asks a VPN app to state
// what user data it collects and how it is used, on a screen, before the service is used. So it
// lists exactly what the provider's panel receives — nothing is summarised away.
//
// The language switch sits at the top end: the first run is where being unable to read the app
// costs the most.

import SwiftUI
import PortwayCore

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    private var step: Int {
        get { app.onboardingStep }
        nonmutating set { app.onboardingStep = newValue }
    }
    @State private var scanning = false
    @State private var picking = false

    private struct Step {
        let kicker, title, body, cta: String
    }

    private var steps: [Step] {
        [
            Step(kicker: L.tr("onboard_kicker_1"), title: L.tr("onboard_title_1"), body: L.tr("onboard_body_1"), cta: L.tr("onboard_cta_1")),
            Step(kicker: L.tr("onboard_kicker_ios_2"), title: L.tr("onboard_title_ios_2"), body: L.tr("onboard_body_ios_2"), cta: L.tr("onboard_cta_1")),
            Step(kicker: L.tr("onboard_kicker_ios_data"), title: L.tr("onboard_title_ios_data"), body: L.tr("onboard_body_ios_data"), cta: L.tr("onboard_cta_ios_data")),
            Step(kicker: L.tr("onboard_kicker_ios_4"), title: L.tr("onboard_title_2"), body: L.tr("onboard_body_2"), cta: L.tr("onboard_cta_2")),
        ]
    }

    var body: some View {
        let current = steps[step]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Rectangle().fill(i <= step ? PW.accent : PW.rule).frame(width: 26, height: 2)
                }
                Spacer()
                LanguageSwitch()
            }
            .padding(.top, 18)

            // The data step is long, and on a 4.7" phone it would push the buttons off screen: the
            // content scrolls when it has to and sits centred when it does not.
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(current.kicker).kicker(PW.accent)
                Text(current.title)
                    .font(PW.font(step == 2 ? 32 : 40, .medium, relativeTo: .largeTitle))
                    .tracking(PW.tracking(-0.035, size: 40))
                    .foregroundStyle(PW.text)
                    .lineSpacing(2)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(PW.accent).frame(width: 64, height: 1).padding(.vertical, 22)
                Text(current.body)
                    .font(PW.font(15))
                    .lineSpacing(15 * 0.5)
                    .foregroundStyle(PW.textSecondary)
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(step)
            .transition(.asymmetric(insertion: .offset(y: 16).combined(with: .opacity), removal: .opacity))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            .scrollIndicators(.hidden)

            Button(current.cta) { advance() }
                .buttonStyle(PrimaryButtonStyle())
            if step == steps.count - 1 {
                Button(L.tr("onboard_file")) { picking = true }
                    .buttonStyle(GhostButtonStyle(color: PW.accent300))
            }
            Button(L.tr("onboard_skip")) { finish() }
                .buttonStyle(GhostButtonStyle())
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 26)
        .background(PW.ground.ignoresSafeArea())
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45), value: step)
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { text in
                scanning = false
                app.importText(text)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { app.importFile(url) }
        }
    }

    private func advance() {
        if step < steps.count - 1 {
            step += 1
        } else {
            scanning = true
        }
    }

    private func finish() {
        PortwaySettings.shared.onboardingDone = true
        app.showOnboarding = false
    }
}

/// EN | فا — each language named in itself.
struct LanguageSwitch: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            segment("EN", .en)
            segment("فا", .fa)
        }
        .overlay(RoundedRectangle(cornerRadius: PW.smallRadius).strokeBorder(PW.stroke, lineWidth: 1))
        .environment(\.layoutDirection, .leftToRight)
    }

    private func segment(_ label: String, _ language: AppLanguage) -> some View {
        let active = L.language == language.rawValue
        return Button { app.setLanguage(language) } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? PW.accent300 : PW.muted)
                .frame(width: 40, height: 28)
                .background(active ? PW.accent900 : .clear)
        }
        .buttonStyle(PressStyle())
        .frame(minHeight: 44)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

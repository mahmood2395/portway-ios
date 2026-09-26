// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// The app's and the tunnel's logs, merged into one timeline, shareable. Hosts and reasons only:
// nothing here ever holds a key or a config.

import SwiftUI
import PortwayCore

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L.tr("done")) { dismiss() }.buttonStyle(GhostButtonStyle(color: PW.accent300)).fixedSize()
                Spacer()
                Text(L.tr("log_viewer_title")).font(PW.font(16, .medium)).foregroundStyle(PW.text)
                Spacer()
                Button(L.tr("a11y_share_log")) { share() }.buttonStyle(GhostButtonStyle(color: PW.accent300)).fixedSize()
            }
            .padding(.horizontal, PW.gutter)
            .frame(height: 56)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "—" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PW.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(PW.gutter)
                        .id("end")
                }
                .environment(\.layoutDirection, .leftToRight)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(PW.ground.ignoresSafeArea())
        .presentationBackground(PW.ground)
        .task { text = PortwayLog.merged() }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }

    private func share() {
        let header = "Portway \(PortwayEnvironment.marketingVersion) (\(PortwayEnvironment.buildNumber)) · iOS \(DeviceInfo.osVersion) · \(DeviceInfo.name)\n\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portway-log.txt")
        try? (header + text).write(to: url, atomically: true, encoding: .utf8)
        shareURL = url
    }
}

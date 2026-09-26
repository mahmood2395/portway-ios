// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Throughput tiles, the usage band and the account card.

import SwiftUI
import PortwayCore

struct StatTile: View {
    var label: String
    var value: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).sectionLabel()
            Text(value)
                .font(PW.font(18, .medium))
                .tabular()
                .foregroundStyle(PW.text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let footnote {
                Text(footnote).font(PW.font(11.5)).tabular().foregroundStyle(PW.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .card(fill: .clear)
        .accessibilityElement(children: .combine)
    }
}

/// Daily bars, oldest first, today in the accent. A time axis: mirrors in RTL.
struct UsageBand: View {
    var series: [UInt64]
    var height: CGFloat = 78
    var gap: CGFloat = 3
    var topRadius: CGFloat = 1

    var body: some View {
        let peak = max(series.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, value in
                UnevenRoundedRectangle(topLeadingRadius: topRadius, topTrailingRadius: topRadius)
                    .fill(index == series.count - 1 ? PW.accent : PW.accent800)
                    // An idle day is drawn as a sliver, not nothing: absence and zero look the same.
                    .frame(height: max(1, height * CGFloat(Double(value) / Double(peak))))
            }
        }
        .frame(height: height, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(PW.rule).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// A 4pt rail with an accent fill.
struct Rail: View {
    var fraction: Double
    var track: Color = PW.rule
    var fill: Color = PW.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct AccountCard: View {
    var account: AccountInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.name ?? "—").font(PW.font(15, .medium)).foregroundStyle(PW.text)
                Spacer()
                if account.disabled {
                    Text(L.tr("account_suspended")).kicker(PW.error)
                } else if account.isExpired {
                    Text(L.tr("account_expired")).kicker(PW.error)
                } else if let plan = account.plan {
                    Text(plan).font(PW.font(12.5)).foregroundStyle(PW.accent300)
                }
            }
            if let quota = account.quotaBytes, let used = account.totalBytes {
                Rail(fraction: Double(used) / Double(quota), track: PW.text.opacity(0.14), fill: PW.accent400)
            }
            HStack {
                if let used = account.totalBytes {
                    Text(L.tr("account_usage_value", L.bytes(used)))
                }
                Spacer()
                if let days = account.daysLeft, days >= 0 {
                    Text(L.tr("days_left_chip", days))
                }
            }
            .font(PW.font(12))
            .tabular()
            .foregroundStyle(PW.textSecondary)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .card(fill: PW.accent900, edge: PW.accent800)
        .accessibilityElement(children: .combine)
    }
}

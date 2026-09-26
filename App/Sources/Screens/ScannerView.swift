// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// "Scan provider code": the camera through a 250pt viewfinder with four accent corner marks and a
// breathing scan line. VisionKit does the reading; nothing is recorded, and nothing leaves the
// phone. A code saved as a screenshot can be read from Photos instead.

import CoreImage
import PhotosUI
import SwiftUI
import VisionKit
import PortwayCore

struct ScannerView: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var breathe = false
    @State private var failed: String?

    private var cameraAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    private static let shade = Color(red: 0x0F / 255, green: 0x10 / 255, blue: 0x18 / 255)

    var body: some View {
        ZStack {
            Self.shade.ignoresSafeArea()
            if cameraAvailable {
                QRScanner { payload in
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(payload)
                }
                .ignoresSafeArea()
                // The ground darkens everywhere but the viewfinder. Both are centred on the same
                // point, so the hole and the corner marks cannot drift apart.
                Self.shade.opacity(0.78)
                    .mask {
                        Rectangle()
                            .overlay { RoundedRectangle(cornerRadius: PW.radius).frame(width: 250, height: 250).blendMode(.destinationOut) }
                            .compositingGroup()
                    }
                    .ignoresSafeArea()
            }
            viewfinder
            VStack(spacing: 0) {
                ScreenHeader(title: L.tr("scan_title"), back: { dismiss() })
                Spacer()
            }
            VStack(spacing: 8) {
                Text(cameraAvailable ? L.tr("scan_hint") : L.tr("scan_unavailable"))
                    .font(PW.font(14.5))
                    .foregroundStyle(PW.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if let failed {
                    Text(failed).font(PW.font(12.5)).foregroundStyle(PW.error)
                }
            }
            .offset(y: 125 + 56)
            VStack {
                Spacer()
                PhotosPicker(selection: $photo, matching: .images) {
                    Text(L.tr("scan_from_photos"))
                }
                .buttonStyle(GhostButtonStyle(color: PW.accent300))
                .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: photo) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self),
                      let image = CIImage(data: data) else { return }
                if let text = Self.decode(image), text.range(of: "[Interface]", options: .caseInsensitive) != nil {
                    onCode(text)
                } else {
                    failed = L.tr("error_no_qr_found")
                }
            }
        }
    }

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            ForEach(0..<4) { corner in
                CornerMark()
                    .stroke(PW.accent, lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading][corner])
                    .padding(16)
            }
            Rectangle().fill(PW.accent).frame(height: 2).padding(.horizontal, 16).padding(.top, 16)
                .opacity(breathe ? 0.8 : 0.35)
                .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { breathe = true } }
        }
        .frame(width: 250, height: 250)
        .accessibilityHidden(true)
    }

    static func decode(_ image: CIImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

/// An L-shaped corner, drawn for the top-leading corner and rotated for the others.
private struct CornerMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: .zero)
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        return p
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .accurate, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        private var delivered = false
        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue, text.range(of: "[Interface]", options: .caseInsensitive) != nil {
                    delivered = true
                    scanner.stopScanning()
                    onPayload(text)
                    return
                }
            }
        }
    }
}

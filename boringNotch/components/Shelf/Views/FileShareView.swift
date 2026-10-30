//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var isProcessing = false
    
    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }

    var body: some View {
        Button {
            Task { await handleClick() }
        } label: {
            Self.dropArea(provider: selectedProvider, isTargeted: vm.dropZoneTargeting, isProcessing: isProcessing || quickShare.isPickerOpen)
        }
            .buttonStyle(.plain)
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Share files")
            .accessibilityHint("Drop files here or click to choose files for \(selectedProvider.id).")
            .help("Drop files here or click to choose files to share")
    }

    static func dropArea(provider: QuickShareProvider, isTargeted: Bool, isProcessing: Bool) -> some View {
        ShelfDropSurface(isTargeted: isTargeted) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    providerIcon(for: provider, isTargeted: isTargeted)
                    Text("Share")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isTargeted ? Color.accentColor : .primary)
                }

                Text("Drop files here\nor click to choose.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(provider.id)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if isProcessing {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.3))
                    .overlay {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
            }
        }
    }

    @ViewBuilder
    private static func providerIcon(for provider: QuickShareProvider, isTargeted: Bool) -> some View {
        if let imageData = provider.imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "square.and.arrow.up")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .frame(width: 20, height: 20)
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }
    
    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}

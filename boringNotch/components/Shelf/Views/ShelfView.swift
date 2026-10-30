//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .frame(width: 144)
                .frame(maxHeight: .infinity)
                .environmentObject(vm)
            panel
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        ShelfDropSurface(isTargeted: vm.dragDetectorTargeting) {
            content
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { selection.clear() }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            handleDrop(providers: providers)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shelf storage")
        .accessibilityHint("Drop files or links here to keep them in Shelf.")
        .help("Drop files or links to keep them in Shelf")
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                Self.emptyState(isTargeted: vm.dragDetectorTargeting)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }

    static func emptyState(isTargeted: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .imageScale(.large)
            Text(isTargeted ? "Drop to add to Shelf" : "Shelf")
                .foregroundStyle(.primary)
                .font(.system(size: 13, weight: .semibold))
            Text(isTargeted
                 ? "Release to keep the item here."
                 : "Drop files or links to keep them here.\nDrag out or select an item to share.")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShelfDropSurface<Content: View>: View {
    let isTargeted: Bool
    private let content: Content

    init(isTargeted: Bool, @ViewBuilder content: () -> Content) {
        self.isTargeted = isTargeted
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isTargeted ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

//
//  OmpUsageView.swift
//  boringNotch
//

import AppKit
import SwiftUI

@MainActor
struct OmpUsageView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store: OmpUsageStore
    @State private var showsConfiguration = false
    @State private var headerHeight: CGFloat = 0
    @State private var documentHeight: CGFloat = 0
    @FocusState private var isExecutablePathFocused: Bool
    private let indicatorGutterWidth: CGFloat = 12
    private let rowSpacing: CGFloat = 10
    private let verticalSpacing: CGFloat = 8
    private let bottomPadding: CGFloat = 12

    init(store: OmpUsageStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: verticalSpacing) {
                VStack(alignment: .leading, spacing: verticalSpacing) {
                    toolbar(now: timeline.date)
                    if showsConfiguration {
                        configuration
                    }
                    if let error = store.lastError, store.snapshot != nil {
                        refreshError(error)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    headerHeight = height
                }
                content(now: timeline.date)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomPadding)
        }
        .onChange(of: headerHeight + documentHeight) { _, _ in
            guard headerHeight > 0, documentHeight > 0 else { return }
            vm.updateUsageContentHeight(headerHeight + verticalSpacing + documentHeight + bottomPadding)
        }
        .onChange(of: isExecutablePathFocused) { _, isFocused in
            vm.isEditingUsageConfiguration = isFocused
        }
        .onChange(of: showsConfiguration) { _, isShown in
            if !isShown {
                isExecutablePathFocused = false
            }
        }
        .onDisappear {
            isExecutablePathFocused = false
            vm.isEditingUsageConfiguration = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let panel = notification.object as? BoringNotchSkyLightWindow,
                  panel.screen?.displayUUID == vm.screenUUID else { return }
            isExecutablePathFocused = false
        }
        .task {
            await store.refresh()
        }
    }


    private func toolbar(now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Oh My Pi Usage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(sourceSummary(now: now))
                    .font(.caption)
                    .foregroundStyle(sourceColor(now: now))
                    .accessibilityLabel("Usage source status: \(sourceSummary(now: now))")
                    .help("Freshness of the usage reports currently shown below.")
            }

            Spacer(minLength: 0)

            Button {
                Task { await store.refresh(force: true) }
            } label: {
                HStack(spacing: 4) {
                    Group {
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text("Refresh")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 28)
            .help("Refresh Oh My Pi usage (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Refresh usage")
            .accessibilityHint("Forces Oh My Pi to refresh account usage.")
            .disabled(store.isRefreshing)

            Button {
                showsConfiguration.toggle()
            } label: {
                Label("Path", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 28)
            .help("Configure the omp executable path")
            .accessibilityLabel("Executable path settings")
            .accessibilityValue(showsConfiguration ? "Shown" : "Hidden")
        }
        .accessibilityElement(children: .contain)
        .imageScale(.small)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        ScrollView {
            // ponytail: eager O(n) quota layout avoids changing height estimates;
            // use cached measured heights if real account counts need virtualization.
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = store.snapshot {
                    if snapshot.quotas.isEmpty && snapshot.notes.isEmpty {
                        emptyState(
                            title: "No usage reported",
                            detail: "Oh My Pi did not return any account limits."
                        )
                    } else {
                        let groups = Dictionary(
                            grouping: accountGroups(quotas: snapshot.quotas, notes: snapshot.notes),
                            by: \.provider
                        )
                        HStack(alignment: .top, spacing: 16) {
                            providerColumn(groups[.some(.codex)] ?? [], now: now)
                            providerColumn(groups[.some(.claude)] ?? [], now: now)
                        }
                        ForEach(groups[nil] ?? []) { group in
                            accountGroup(group, now: now)
                        }
                    }
                } else if let error = store.lastError {
                    emptyState(
                        title: "Usage unavailable",
                        detail: error
                    )
                } else if store.isRefreshing {
                    loadingState
                } else {
                    emptyState(
                        title: "Usage not loaded",
                        detail: "Refresh to check Oh My Pi account limits."
                    )
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { geometry in
                ceil(geometry.size.height)
            } action: { height in
                documentHeight = height
            }
        }
        .contentMargins(.trailing, indicatorGutterWidth, for: .scrollContent)
        .scrollIndicators(.automatic)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Leave the path empty to locate omp automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                TextField("Automatic discovery", text: $store.binaryPath)
                    .textFieldStyle(.roundedBorder)
                    .focused($isExecutablePathFocused)
                    .onSubmit {
                        isExecutablePathFocused = false
                        Task { await store.refresh(force: true) }
                    }
                    .accessibilityLabel("Path to OMP executable")
                    .help("Path to the omp executable. Leave empty for automatic discovery.")

                if !store.binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Use automatic path") {
                        store.binaryPath = ""
                        isExecutablePathFocused = false
                        Task { await store.refresh(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .help("Clear the custom path and find omp automatically")
                }
            }
        }
    }

    private func refreshError(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Last refresh failed. \(error)")
    }

    private func providerColumn(_ groups: [UsageGroup], now: Date) -> some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            ForEach(groups) { group in
                accountGroup(group, now: now)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private func accountGroup(_ group: UsageGroup, now: Date) -> some View {
        let groupID = group.id
        let resets = store.snapshot?.bankedResets[group.id]
        let expirationHelp = resets?.expirationHelp ?? ""
        let expiryWarning = resets?.needsExpiryWarning(at: now) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let provider = group.provider {
                        Image(provider.rawValue)
                            .renderingMode(provider == .claude ? .original : .template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }
                    Text(group.id)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)

                    if let resets, resets.count > 0 {
                        let expiry = resets.expirationSummary(at: now)
                        Text("\(resets.count) \(resets.count == 1 ? "reset" : "resets")\(expiry.isEmpty ? "" : " · \(expiry)")")
                            .font(.caption)
                            .foregroundStyle(expiryWarning ? Color(red: 0.90, green: 0.48, blue: 0.45) : Color.secondary)
                            .fixedSize()
                            .accessibilityLabel("Banked resets: \(resets.count)")
                            .help(expirationHelp)
                            .accessibilityHint(expiryWarning ? "A banked reset is expiring soon or has expired. \(expirationHelp)" : expirationHelp)
                    }
                    Spacer(minLength: 0)
                }

                if let sourceDetail = sourceDetail(for: group, now: now) {
                    Text(sourceDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(freshnessColor(for: group.fetchedAt, now: now))
                        .accessibilityLabel("\(group.id) \(sourceDetail)")
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black)
            .visualEffect { content, geometry in
                let headerY = geometry.frame(in: .scrollView(axis: .vertical)).minY
                let sectionHeight = geometry.bounds(of: .named(groupID))?.height ?? geometry.size.height
                return content.offset(y: min(max(0, -headerY), max(0, sectionHeight - geometry.size.height)))
            }
            .zIndex(1)

            ForEach(group.quotas) { quota in
                quotaRow(quota, now: now)
            }

            ForEach(group.notes) { note in
                noteRow(note)
            }
        }
        .coordinateSpace(name: groupID)
    }

    private func quotaRow(_ quota: OmpQuota, now: Date) -> some View {
        let reset = quota.resetCountdown(at: now)
        let accessibilityLabel = quotaAccessibilityLabel(quota, reset: reset)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: rowSpacing) {
                Text(quota.compactTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(percentage(quota.percentRemaining))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            ProgressView(value: boundedPercentage(quota.percentRemaining), total: 100)
                .progressViewStyle(.linear)
                .tint(progressColor(for: quota.percentRemaining))
                .frame(maxWidth: .infinity)
                .frame(height: 4)
                .accessibilityHidden(true)

            Text(reset)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)

            if let spend = spendDetail(for: quota) {
                Text(spend)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .help(quotaHelp(quota, accessibilityLabel: accessibilityLabel))
    }

    private func noteRow(_ note: OmpUsageNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: rowSpacing) {
            Text(note.label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(note.value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.label). \(note.value)")
        .help("\(note.label): \(note.value)")
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Loading usage", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text("Checking your Oh My Pi accounts…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
    }

    private func accountGroups(quotas: [OmpQuota], notes: [OmpUsageNote]) -> [UsageGroup] {
        let quotaGroups = Dictionary(grouping: quotas, by: \.group)
        let noteGroups = Dictionary(grouping: notes, by: \.group)
        let groupNames = Set(quotaGroups.keys).union(noteGroups.keys)

        return groupNames
            .map {
                UsageGroup(
                    id: $0,
                    quotas: (quotaGroups[$0] ?? []).sorted { $0.id < $1.id },
                    notes: (noteGroups[$0] ?? []).sorted { $0.id < $1.id }
                )
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private func sourceSummary(now: Date) -> String {
        guard let snapshot = store.snapshot else {
            if store.isRefreshing { return "Checking sources" }
            if store.lastError != nil { return "Refresh failed" }
            return "Sources not checked"
        }
        guard let fetchedAt = snapshot.fetchedAt else {
            return "Some source times unknown"
        }

        let age = minuteAgeText(for: fetchedAt, now: now)

        if now.timeIntervalSince(fetchedAt) > OmpUsageStore.staleInterval {
            let allQuotasAreOld = !snapshot.quotas.isEmpty && snapshot.quotas.allSatisfy { quota in
                guard let source = quota.fetchedAt else { return false }
                return now.timeIntervalSince(source) > OmpUsageStore.staleInterval
            }
            let status = allQuotasAreOld ? "Quota reports stale" : "Some reports stale"
            return "\(status) · oldest \(age)"
        }
        return "Reports current · oldest \(age)"
    }

    private func sourceColor(now: Date) -> Color {
        guard let snapshot = store.snapshot else {
            return store.lastError == nil ? .secondary : .orange
        }
        guard let fetchedAt = snapshot.fetchedAt else { return .orange }
        return now.timeIntervalSince(fetchedAt) > OmpUsageStore.staleInterval ? .orange : .secondary
    }

    private func sourceDetail(for group: UsageGroup, now: Date) -> String? {
        guard let fetchedAt = group.fetchedAt else {
            return group.quotas.isEmpty ? nil : "Source time unknown"
        }
        guard now.timeIntervalSince(fetchedAt) > OmpUsageStore.staleInterval else { return nil }
        return "Stale · \(minuteAgeText(for: fetchedAt, now: now))"
    }

    private func minuteAgeText(for fetchedAt: Date, now: Date) -> String {
        if now.timeIntervalSince(fetchedAt) < 60 { return "less than a minute ago" }
        return fetchedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    private func freshnessColor(for fetchedAt: Date?, now: Date) -> Color {
        guard let fetchedAt else { return .orange }
        return now.timeIntervalSince(fetchedAt) > OmpUsageStore.staleInterval ? .orange : .secondary
    }

    private func quotaAccessibilityLabel(_ quota: OmpQuota, reset: String) -> String {
        let spend = spendDetail(for: quota).map { ". \($0)" } ?? ""
        return "\(quota.label). \(percentage(quota.percentRemaining)) percent remaining. Reset \(reset).\(spend)"
    }

    private func quotaHelp(_ quota: OmpQuota, accessibilityLabel: String) -> String {
        guard let resetsAt = quota.resetsAt else { return accessibilityLabel }
        return "\(accessibilityLabel) Exact reset: \(resetsAt.formatted(date: .abbreviated, time: .shortened))."
    }



    private func spendDetail(for quota: OmpQuota) -> String? {
        guard let dollarUsed = quota.dollarUsed else { return nil }
        if let dollarCap = quota.dollarCap {
            let remaining = max(dollarCap - dollarUsed, 0)
            return "\(remaining.formatted(.currency(code: "USD"))) remaining of \(dollarCap.formatted(.currency(code: "USD")))"
        }
        return "Spent \(dollarUsed.formatted(.currency(code: "USD"))) · no cap"
    }

    private func percentage(_ value: Double) -> Int {
        Int(boundedPercentage(value).rounded())
    }

    private func boundedPercentage(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    private func progressColor(for remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .primary
    }
}

private enum UsageProvider: String, Hashable {
    case codex = "CodexProvider"
    case claude = "ClaudeProvider"
}

private struct UsageGroup: Identifiable {
    let id: String
    let quotas: [OmpQuota]
    let notes: [OmpUsageNote]
    var provider: UsageProvider? {
        if id == "Codex" || id.hasPrefix("Codex · ") { return .codex }
        if id == "Claude" || id.hasPrefix("Claude · ") { return .claude }
        return nil
    }


    var fetchedAt: Date? {
        guard !quotas.isEmpty, quotas.allSatisfy({ $0.fetchedAt != nil }) else { return nil }
        return quotas.compactMap(\.fetchedAt).min()
    }
}

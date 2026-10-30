import Foundation

struct OmpUsageSnapshot: Sendable {
    let quotas: [OmpQuota]
    let notes: [OmpUsageNote]
    let bankedResets: [String: OmpBankedResets]
    let completedAt: Date
    /// Oldest source-report fetch time. `nil` means at least one usable report
    /// did not carry a valid source timestamp.
    let fetchedAt: Date?
}

struct OmpBankedResets: Sendable, Equatable {
    struct Expiration: Sendable, Equatable {
        let date: Date
        let count: Int
    }

    let count: Int
    let expirations: [Expiration]

    var unknownExpirationCount: Int {
        max(0, count - expirations.reduce(0) { $0 + $1.count })
    }

    func needsExpiryWarning(at now: Date) -> Bool {
        count > 0 && expirations.contains { $0.date.timeIntervalSince(now) < 86_400 }
    }

    func expirationSummary(at now: Date) -> String {
        var parts = expirations.map { expiration in
            let remaining = expiration.date.timeIntervalSince(now)
            let time: String
            if remaining <= 0 {
                time = "Expired"
            } else if remaining >= 86_400 {
                time = "\(Int(remaining / 86_400))d"
            } else if remaining >= 3_600 {
                time = "\(Int(remaining / 3_600))h"
            } else {
                time = "<1h"
            }
            return expiration.count == 1 ? time : "\(expiration.count)×\(time)"
        }
        let unknown = unknownExpirationCount
        if unknown > 0 { parts.append(unknown == 1 ? "?" : "\(unknown)×?") }
        return parts.joined(separator: " · ")
    }

    var expirationHelp: String {
        guard count > 0 else { return "No banked resets available." }
        var lines = ["Expires (local time):"]
        for expiration in expirations {
            let units = expiration.count == 1 ? "reset" : "resets"
            lines.append("\(expiration.count) \(units) · \(expiration.date.formatted(date: .abbreviated, time: .shortened))")
        }
        let unknown = unknownExpirationCount
        if unknown > 0 {
            lines.append("\(unknown) \(unknown == 1 ? "reset" : "resets") · Expiration not reported by OMP")
        }
        return lines.joined(separator: "\n")
    }
}

struct OmpQuota: Identifiable, Sendable {
    let id: String
    let label: String
    let group: String
    let compactTitle: String
    let percentRemaining: Double
    let resetsAt: Date?
    let fetchedAt: Date?
    let dollarUsed: Decimal?
    let dollarCap: Decimal?

    private static let resetCountdownStyle: Duration.UnitsFormatStyle = .units(
        allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2,
        zeroValueUnits: .hide, fractionalPart: .hide(rounded: .down)
    ).locale(Locale(identifier: "en_US"))

    func resetCountdown(at now: Date) -> String {
        guard let resetsAt else { return "Unavailable" }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Due now" }
        guard remaining >= 60 else { return "<1m" }
        return Duration.seconds(remaining).formatted(Self.resetCountdownStyle)
    }
}

struct OmpUsageNote: Identifiable, Sendable {
    let id: String
    let group: String
    let label: String
    let value: String
}

enum OmpUsageError: LocalizedError, Sendable {
    case malformedOutput
    case noData

    var errorDescription: String? {
        switch self {
        case .malformedOutput:
            return "Oh My Pi returned unreadable usage data. Update omp and try again."
        case .noData:
            return "Oh My Pi reported no usage accounts. Sign in with `omp`, then try again."
        }
    }
}

/// Read-only adapter for `omp usage --json`.
///
/// Identity, grouping, window labels, percentage precedence, spend handling,
/// and unreported-account matching are adapted from tddworks/ClaudeBar's
/// `OmpUsageProbe` (MIT), without its app/domain dependencies.
struct OmpUsageProbe {

    /// Parses text containing one `omp usage --json` object. `generatedAt` is
    /// deliberately ignored: it describes CLI generation, not provider fetch.
    static func parse(_ text: String, completedAt: Date = Date()) throws -> OmpUsageSnapshot {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw OmpUsageError.malformedOutput
        }
        let data = Data(text[start...end].utf8)
        let payload: UsagePayload
        do {
            payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        } catch {
            throw OmpUsageError.malformedOutput
        }

        var reportCounts: [String: Int] = [:]
        for report in payload.reports {
            reportCounts[report.provider, default: 0] += 1
        }

        var quotas: [OmpQuota] = []
        var notes: [OmpUsageNote] = []
        var bankedResets: [String: OmpBankedResets] = [:]
        var seenLabels = Set<String>()
        var seenGroups = Set<String>()
        var seenIDs = Set<String>()
        var usableFetchDates: [Date] = []
        var hasUnknownFreshness = false

        for (reportIndex, report) in payload.reports.enumerated() {
            let providerName = upstreamDisplayName(report.provider)
            let isDuplicateProvider = reportCounts[report.provider, default: 0] > 1
            let discriminator: String?
            if isDuplicateProvider {
                discriminator = report.accountDiscriminator ?? "#\(reportIndex + 1)"
            } else if payload.disabledCredentials?.contains(where: { $0.provider == report.provider }) == true {
                discriminator = report.accountDiscriminator
            } else {
                discriminator = nil
            }
            let group = unique(
                discriminator.map { "\(providerName) · \($0)" } ?? providerName,
                seen: &seenGroups
            )
            if let resets = report.resetCredits?.bankedResets {
                bankedResets[group] = resets
            }
            let fetchedAt = date(fromEpochMilliseconds: report.fetchedAt)
            let groupCounts = Dictionary(grouping: report.limits, by: \.windowGroupKey).mapValues(\.count)
            let quotaCount = quotas.count
            let noteCount = notes.count

            for (limitIndex, limit) in report.limits.enumerated() {
                let meter = groupCounts[limit.windowGroupKey, default: 0] > 1 ? limit.meterName : nil
                if let dollarUsed = limit.uncappedMonetaryUsed {
                    let label = unique(
                        uncappedSpendLabel(providerName: providerName, limit: limit, discriminator: discriminator),
                        seen: &seenLabels
                    )
                    notes.append(OmpUsageNote(
                        id: uniqueID(
                            "report:\(report.stableIdentity ?? "#\(reportIndex + 1)"):uncapped:\(limit.stableID(index: limitIndex))",
                            seen: &seenIDs
                        ),
                        group: group,
                        label: label,
                        value: "\(limit.labelToken) usage \(formatMoney(dollarUsed)) spent · no cap"
                    ))
                    continue
                }

                let monetaryAmounts = limit.cappedMonetaryAmounts
                if limit.isMonetary, monetaryAmounts == nil {
                    continue
                }
                guard let percentRemaining = limit.percentRemaining else { continue }

                let label = unique(
                    quotaLabel(
                        providerName: providerName,
                        limit: limit,
                        meter: meter,
                        discriminator: discriminator
                    ),
                    seen: &seenLabels
                )
                quotas.append(OmpQuota(
                    id: uniqueID(
                        "report:\(report.stableIdentity ?? "#\(reportIndex + 1)"):quota:\(limit.stableID(index: limitIndex))",
                        seen: &seenIDs
                    ),
                    label: label,
                    group: group,
                    compactTitle: compactTitle(limit: limit, meter: meter, providerName: providerName),
                    percentRemaining: percentRemaining,
                    resetsAt: date(fromEpochMilliseconds: limit.window?.resetsAt),
                    fetchedAt: fetchedAt,
                    dollarUsed: monetaryAmounts?.used,
                    dollarCap: monetaryAmounts?.cap
                ))
            }

            if quotas.count > quotaCount || notes.count > noteCount {
                if let fetchedAt {
                    usableFetchDates.append(fetchedAt)
                } else {
                    hasUnknownFreshness = true
                }
            } else {
                let identity = report.identityLabel ?? discriminator ?? "account \(reportIndex + 1)"
                notes.append(OmpUsageNote(
                    id: uniqueID(
                        "report:\(report.stableIdentity ?? "#\(reportIndex + 1)"):unreported",
                        seen: &seenIDs
                    ),
                    group: group,
                    label: unique("\(providerName) · \(identity)", seen: &seenLabels),
                    value: "No usage reported"
                ))
                if let fetchedAt {
                    usableFetchDates.append(fetchedAt)
                } else {
                    hasUnknownFreshness = true
                }
            }
        }

        var emittedUnreportedAccounts: [UnreportedAccount] = []
        for (accountIndex, account) in (payload.accountsWithoutUsage ?? []).enumerated() {
            let matchesReport = payload.reports.contains { report in
                emailOrAccountIdMatch(
                    provider: account.provider,
                    email: account.email,
                    accountId: account.accountId,
                    orgId: account.orgId,
                    otherProvider: report.provider,
                    otherEmail: report.metadata?.email,
                    otherAccountId: report.matchableAccountId
                )
            }
            let duplicatesRow = emittedUnreportedAccounts.contains { emitted in
                guard !hasOrganization(emitted.orgId) else { return false }
                return emailOrAccountIdMatch(
                    provider: account.provider,
                    email: account.email,
                    accountId: account.accountId,
                    orgId: account.orgId,
                    otherProvider: emitted.provider,
                    otherEmail: emitted.email,
                    otherAccountId: emitted.accountId
                )
            }
            guard !matchesReport, !duplicatesRow else { continue }

            emittedUnreportedAccounts.append(account)
            let providerName = upstreamDisplayName(account.provider)
            let identity = account.identityLabel
            notes.append(OmpUsageNote(
                id: uniqueID("unreported:\(account.stableIdentity ?? "#\(accountIndex + 1)")", seen: &seenIDs),
                group: unique("\(providerName) · \(shortIdentity(identity))", seen: &seenGroups),
                label: unique("\(providerName) · \(identity)", seen: &seenLabels),
                value: "No usage reported"
            ))
        }

        guard !quotas.isEmpty || !notes.isEmpty else {
            throw OmpUsageError.noData
        }
        return OmpUsageSnapshot(
            quotas: quotas,
            notes: notes,
            bankedResets: bankedResets,
            completedAt: completedAt,
            fetchedAt: hasUnknownFreshness ? nil : usableFetchDates.min()
        )
    }


    private static func date(fromEpochMilliseconds milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite else { return nil }
        let seconds = milliseconds / 1_000
        guard seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func emailOrAccountIdMatch(
        provider: String,
        email: String?,
        accountId: String?,
        orgId: String?,
        otherProvider: String,
        otherEmail: String?,
        otherAccountId: String?
    ) -> Bool {
        guard provider == otherProvider, !hasOrganization(orgId) else { return false }
        if let email = normalizedEmail(email), let otherEmail = normalizedEmail(otherEmail) {
            return email == otherEmail
        }
        guard let accountId, !accountId.isEmpty,
              let otherAccountId, !otherAccountId.isEmpty else { return false }
        return accountId == otherAccountId
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func hasOrganization(_ orgId: String?) -> Bool {
        guard let orgId else { return false }
        return !orgId.isEmpty
    }

    private static func unique(_ base: String, seen: inout Set<String>) -> String {
        var value = base
        var suffix = 2
        while seen.contains(value) {
            value = "\(base) (\(suffix))"
            suffix += 1
        }
        seen.insert(value)
        return value
    }

    private static func uniqueID(_ base: String, seen: inout Set<String>) -> String {
        unique(base, seen: &seen)
    }

    private static func quotaLabel(
        providerName: String,
        limit: UsageLimit,
        meter: String?,
        discriminator: String?
    ) -> String {
        var parts = [providerName]
        if let tier = limit.scope?.tier, !tier.isEmpty { parts.append(tier.capitalized) }
        if let meter, !meter.isEmpty { parts.append(meter) }
        parts.append(limit.labelToken)
        if let discriminator, !discriminator.isEmpty { parts.append("· \(discriminator)") }
        return parts.joined(separator: " ")
    }

    private static func compactTitle(limit: UsageLimit, meter: String?, providerName: String) -> String {
        var parts: [String] = []
        if let tier = limit.scope?.tier, !tier.isEmpty { parts.append(tier.capitalized) }
        if limit.isMonetary {
            if let meter, !meter.isEmpty { parts.append(meter) }
            parts.append(limit.labelToken)
            return parts.joined(separator: " ")
        }
        let display = limit.displayWindowToken(providerName: providerName)
        if let meter, !meter.isEmpty, !display.selfDescribing { parts.append(meter) }
        parts.append(display.token)
        return parts.joined(separator: " ")
    }

    private static func uncappedSpendLabel(providerName: String, limit: UsageLimit, discriminator: String?) -> String {
        var parts = [providerName, limit.labelToken, "Usage"]
        if let discriminator, !discriminator.isEmpty { parts.append("· \(discriminator)") }
        return parts.joined(separator: " ")
    }

    private static func formatMoney(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "$\(formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)")"
    }

    static func upstreamDisplayName(_ id: String) -> String {
        switch id {
        case "anthropic": return "Claude"
        case "openai-codex": return "Codex"
        case "zai": return "Z.ai"
        case "google-gemini-cli": return "Gemini"
        case "google-antigravity": return "Antigravity"
        case "github-copilot": return "Copilot"
        case "kimi-code": return "Kimi"
        case "minimax-code": return "MiniMax"
        case "minimax-code-cn": return "MiniMax CN"
        case "opencode-go": return "OpenCode Go"
        default:
            return id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    private static func shortIdentity(_ identity: String) -> String {
        let localPart = identity.split(separator: "@").first ?? Substring(identity)
        return String((localPart.count < identity.count ? localPart : Substring(identity)).prefix(16))
    }

    private struct UsagePayload: Decodable {
        let reports: [UsageReport]
        let accountsWithoutUsage: [UnreportedAccount]?
        let disabledCredentials: [DisabledCredential]?
    }

    private struct UsageReport: Decodable {
        let provider: String
        let fetchedAt: Double?
        let limits: [UsageLimit]
        let metadata: ReportMetadata?
        let resetCredits: ResetCredits?

        var matchableAccountId: String? {
            if let accountId = metadata?.accountId, !accountId.isEmpty { return accountId }
            return limits.lazy.compactMap { limit in
                guard let accountId = limit.scope?.accountId, !accountId.isEmpty else { return nil }
                return accountId
            }.first
        }

        var identityLabel: String? {
            for value in [metadata?.email, metadata?.accountId, metadata?.projectId] {
                if let value, !value.isEmpty { return value }
            }
            return limits.lazy.compactMap { limit in
                let value = limit.scope?.accountId ?? limit.scope?.projectId
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first
        }

        var accountDiscriminator: String? {
            guard let identity = identityLabel else { return nil }
            let localPart = identity.split(separator: "@").first ?? Substring(identity)
            return localPart.count < identity.count ? String(localPart.prefix(16)) : String(identity.prefix(8))
        }

        var stableIdentity: String? {
            guard let identity = identityLabel else { return nil }
            return "\(provider):\(identity)"
        }
    }
    private struct ResetCredits: Decodable {
        let availableCount: Int?
        let credits: [Credit]?

        struct Credit: Decodable {
            let status: String?
            let remainingCount: Int?
            let expiresAt: String?
        }

        var bankedResets: OmpBankedResets? {
            guard let availableCount, availableCount >= 0 else { return nil }
            var dates: [Date: Int] = [:]
            var unattributedCount = availableCount
            for credit in credits ?? [] {
                guard unattributedCount > 0, credit.status == "available",
                      let value = credit.expiresAt,
                      let date = (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                        ?? (try? Date(value, strategy: .iso8601)) else { continue }
                let count = min(credit.remainingCount ?? 1, unattributedCount)
                guard count > 0 else { continue }
                dates[date, default: 0] += count
                unattributedCount -= count
            }
            var expirations = dates.map { OmpBankedResets.Expiration(date: $0.key, count: $0.value) }
            expirations.sort { $0.date < $1.date }
            return OmpBankedResets(count: availableCount, expirations: expirations)
        }
    }


    private struct ReportMetadata: Decodable {
        let email: String?
        let accountId: String?
        let projectId: String?
    }

    private struct UnreportedAccount: Decodable {
        let provider: String
        let type: String?
        let email: String?
        let accountId: String?
        let orgId: String?
        let projectId: String?
        let enterpriseUrl: String?

        var identityLabel: String {
            if type == "api_key" { return "API key" }
            for value in [email, accountId, projectId, enterpriseUrl] {
                if let value, !value.isEmpty { return value }
            }
            return "OAuth account"
        }

        var stableIdentity: String? {
            for value in [orgId, normalizedEmail(email), accountId, projectId, enterpriseUrl] {
                if let value, !value.isEmpty { return "\(provider):\(value)" }
            }
            return nil
        }

        private func normalizedEmail(_ value: String?) -> String? {
            guard let value else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        }
    }

    private struct DisabledCredential: Decodable {
        let provider: String
    }

    private struct UsageLimit: Decodable {
        let id: String?
        let label: String?
        let scope: LimitScope?
        let window: LimitWindow?
        let amount: LimitAmount?

        var isMonetary: Bool {
            amount?.unit?.caseInsensitiveCompare("usd") == .orderedSame
        }

        var cappedMonetaryAmounts: (used: Decimal, cap: Decimal)? {
            guard isMonetary,
                  let rawLimit = amount?.limit, rawLimit > 0,
                  let used = amount?.roundedUsed,
                  let cap = amount?.roundedLimit else { return nil }
            return (used, cap)
        }

        var uncappedMonetaryUsed: Decimal? {
            guard isMonetary, amount?.limit == nil else { return nil }
            return amount?.roundedUsed
        }

        var labelToken: String {
            guard isMonetary else { return windowToken }
            let token = scope?.windowId ?? window?.id ?? "spend"
            return token.prefix(1).uppercased() + token.dropFirst()
        }

        var percentRemaining: Double? {
            if let remaining = amount?.remainingFraction {
                return Self.percentage(fromRemainingFraction: remaining)
            }
            if let used = amount?.usedFraction {
                return Self.percentage(fromUsedFraction: used)
            }
            if let used = amount?.used, let limit = amount?.limit, limit > 0 {
                let fraction = (limit - used) / limit * 100
                return Self.validPercentage(NSDecimalNumber(decimal: fraction).doubleValue)
            }
            return nil
        }

        var windowToken: String {
            scope?.windowId ?? window?.id ?? window?.label ?? "limit"
        }

        var windowGroupKey: String {
            "\(scope?.tier ?? "")|\(windowToken)"
        }

        var meterName: String? {
            guard !isMonetary,
                  let unit = amount?.unit, !unit.isEmpty,
                  unit.caseInsensitiveCompare("percent") != .orderedSame else { return nil }
            return unit.capitalized
        }

        func stableID(index: Int) -> String {
            id ?? "\(scope?.tier ?? "")|\(windowToken)|\(meterName ?? "")|\(label ?? "")|\(index + 1)"
        }

        func displayWindowToken(providerName: String) -> DisplayWindowToken {
            let raw = scope?.windowId ?? window?.id
            if let raw, Self.isCompactWindowToken(raw) {
                return DisplayWindowToken(token: raw, selfDescribing: false)
            }
            if let milliseconds = window?.durationMs,
               let token = Self.compactDurationToken(milliseconds / 1_000) {
                return DisplayWindowToken(token: token, selfDescribing: false)
            }
            if let label, !label.isEmpty {
                return DisplayWindowToken(token: Self.strippingProviderPrefix(label, providerName: providerName), selfDescribing: true)
            }
            if let label = window?.label, !label.isEmpty {
                return DisplayWindowToken(token: Self.strippingProviderPrefix(label, providerName: providerName), selfDescribing: false)
            }
            return DisplayWindowToken(token: raw ?? "limit", selfDescribing: false)
        }

        private static func percentage(fromRemainingFraction fraction: Double) -> Double? {
            guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
            return validPercentage(fraction * 100)
        }

        private static func percentage(fromUsedFraction fraction: Double) -> Double? {
            guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
            return validPercentage((1 - fraction) * 100)
        }

        private static func validPercentage(_ value: Double) -> Double? {
            guard value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }

        private static func isCompactWindowToken(_ token: String) -> Bool {
            token.range(of: "^\\d{1,4}(s|m|h|d|w|mo|y)$", options: [.regularExpression, .caseInsensitive]) != nil
        }

        private static func compactDurationToken(_ seconds: TimeInterval) -> String? {
            guard seconds.isFinite, let total = Int(exactly: seconds.rounded()), total > 0 else { return nil }
            if total % 86_400 == 0 { return "\(total / 86_400)d" }
            if total % 3_600 == 0 { return "\(total / 3_600)h" }
            if total % 60 == 0 { return "\(total / 60)m" }
            return "\(total)s"
        }

        private static func strippingProviderPrefix(_ label: String, providerName: String) -> String {
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > providerName.count + 1,
                  trimmed.lowercased().hasPrefix(providerName.lowercased() + " ") else { return trimmed }
            return String(trimmed.dropFirst(providerName.count + 1)).trimmingCharacters(in: .whitespaces)
        }

        struct DisplayWindowToken {
            let token: String
            let selfDescribing: Bool
        }
    }

    private struct LimitScope: Decodable {
        let accountId: String?
        let projectId: String?
        let tier: String?
        let windowId: String?
    }

    private struct LimitWindow: Decodable {
        let id: String?
        let label: String?
        let durationMs: Double?
        let resetsAt: Double?
    }

    private struct LimitAmount: Decodable {
        let used: Decimal?
        let limit: Decimal?
        let usedFraction: Double?
        let remainingFraction: Double?
        let unit: String?

        var roundedUsed: Decimal? { rounded(used) }
        var roundedLimit: Decimal? { rounded(limit) }

        private func rounded(_ value: Decimal?) -> Decimal? {
            guard var value else { return nil }
            var result = Decimal()
            NSDecimalRound(&result, &value, 2, .plain)
            return result
        }
    }
}

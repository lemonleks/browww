import Foundation

#if OMP_STANDALONE_CHECKS

@main
struct OmpUsageCheck {
    @MainActor
    static func main() async throws {
        try parserChecks()
        try await processChecks()
        try await storeChecks()
    }

    @MainActor
    private static func parserChecks() throws {
        let snapshot = try OmpUsageProbe.parse("""
        ignored status line
        {
          "generatedAt": 9999999999999,
          "reports": [
            {
              "provider": "anthropic",
              "fetchedAt": 2000,
              "metadata": { "email": "active@example.com" },
              "limits": [{
                "id": "anthropic:5h",
                "scope": { "windowId": "5h" },
                "window": { "id": "5h", "resetsAt": 3000 },
                "amount": { "remainingFraction": 0.9, "usedFraction": 0.01, "unit": "percent" }
              }]
            },
            {
              "provider": "openai-codex",
              "fetchedAt": 1000,
              "limits": [{
                "id": "codex:extra",
                "scope": { "windowId": "extra" },
                "amount": { "used": 1.005, "limit": 12.5, "unit": "USD" }
              }]
            },
            {
              "provider": "zai",
              "fetchedAt": 3000,
              "limits": [{
                "id": "zai:spend",
                "scope": { "windowId": "spend" },
                "amount": { "used": 2.005, "unit": "usd" }
              }]
            }
          ],
          "disabledCredentials": [{ "id": 7, "provider": "anthropic", "email": "expired@example.com", "cause": "private upstream detail" }]
        }
        trailing status line
        """, completedAt: Date(timeIntervalSince1970: 9))

        precondition(snapshot.completedAt == Date(timeIntervalSince1970: 9))
        precondition(snapshot.fetchedAt == Date(timeIntervalSince1970: 1))
        precondition(snapshot.quotas.count == 2)
        precondition(snapshot.quotas[0].percentRemaining == 90)
        precondition(snapshot.quotas[0].fetchedAt == Date(timeIntervalSince1970: 2))
        precondition(snapshot.quotas[1].dollarUsed == Decimal(string: "1.01"))
        precondition(snapshot.quotas[1].dollarCap == Decimal(string: "12.5"))
        precondition(snapshot.notes.map(\.group) == [OmpUsageProbe.upstreamDisplayName("zai")])
        precondition(!snapshot.notes.contains { $0.label.contains("private upstream detail") || $0.value.contains("private upstream detail") })
        precondition(snapshot.quotas[0].group.contains("active"))
        let reset = snapshot.quotas[0].resetsAt!
        precondition(snapshot.quotas[0].resetCountdown(at: reset.addingTimeInterval(-549_420)) == "6d 8h")
        precondition(snapshot.quotas[0].resetCountdown(at: reset.addingTimeInterval(-3_599)) == "59m")
        precondition(snapshot.quotas[0].resetCountdown(at: reset.addingTimeInterval(-60)) == "1m")
        precondition(snapshot.quotas[0].resetCountdown(at: reset.addingTimeInterval(-59)) == "<1m")
        precondition(snapshot.quotas[0].resetCountdown(at: reset) == "Due now")

        do {
            _ = try OmpUsageProbe.parse("""
            { "reports": [], "disabledCredentials": [
              { "provider": "anthropic", "email": "expired@example.com" }
            ] }
            """)
            preconditionFailure("Disabled credentials must not create display accounts")
        } catch OmpUsageError.noData {}

        let invalidPercentage = try OmpUsageProbe.parse("""
        { "reports": [{
          "provider": "anthropic", "fetchedAt": 1000,
          "limits": [{ "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 1.1 } }]
        }] }
        """)
        precondition(invalidPercentage.quotas.isEmpty)
        precondition(invalidPercentage.notes.map(\.value) == ["No usage reported"])

        let unknownFreshness = try OmpUsageProbe.parse("""
        { "reports": [{
          "provider": "anthropic",
          "limits": [{ "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 0.5 } }]
        }] }
        """)
        precondition(unknownFreshness.fetchedAt == nil)
        precondition(unknownFreshness.quotas[0].fetchedAt == nil)

        let multipleAccountsAndMeters = try OmpUsageProbe.parse("""
        { "reports": [
          {
            "provider": "anthropic", "fetchedAt": 1000,
            "metadata": { "email": "work@example.com" },
            "resetCredits": { "availableCount": 2, "credits": [
              { "status": "used", "expiresAt": "2026-10-01T00:00:00Z" },
              { "status": "expired", "expiresAt": "2026-10-02T00:00:00Z" },
              { "status": "available", "expiresAt": "2026-10-29T18:50:50.909806Z" },
              { "status": "available", "expiresAt": "2026-10-29T20:50:50.909806+02:00" }
            ] },
            "limits": [
              { "id": "tokens", "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 0.5, "unit": "tokens" } },
              { "id": "requests", "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 0.4, "unit": "requests" } }
            ]
          },
          {
            "provider": "anthropic", "fetchedAt": 2000,
            "metadata": { "email": "home@example.com" },
            "resetCredits": { "availableCount": 0 },
            "limits": [{ "id": "primary", "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 0.3 } }]
          }
        ] }
        """)
        precondition(Set(multipleAccountsAndMeters.quotas.map(\.id)).count == 3)
        precondition(Set(multipleAccountsAndMeters.quotas.map(\.group)) == ["Claude · work", "Claude · home"])
        precondition(multipleAccountsAndMeters.quotas.map(\.label).contains("Claude Tokens 5h · work"))
        precondition(multipleAccountsAndMeters.quotas.map(\.label).contains("Claude Requests 5h · work"))
        let workResets = multipleAccountsAndMeters.bankedResets["Claude · work"]!
        precondition(workResets.count == 2 && workResets.unknownExpirationCount == 0)
        precondition(workResets.expirations == [
            OmpBankedResets.Expiration(date: Date(timeIntervalSince1970: 1_793_299_850.909806), count: 2)
        ])
        precondition(multipleAccountsAndMeters.bankedResets["Claude · home"]?.count == 0)

        let partialExpiry = try OmpUsageProbe.parse("""
        { "reports": [{
          "provider": "openai-codex",
          "limits": [{ "scope": { "windowId": "7d" }, "amount": { "remainingFraction": 0.5 } }],
          "resetCredits": { "availableCount": 4, "credits": [
            { "status": "available", "remainingCount": 2, "expiresAt": "2026-11-06T23:18:59Z" },
            { "status": "available", "expiresAt": "invalid-date" },
            { "status": "available" },
            { "status": "available", "remainingCount": -1, "expiresAt": "2026-11-07T00:00:00Z" }
          ] }
        }] }
        """)
        let partialResets = partialExpiry.bankedResets["Codex"]!
        precondition(partialResets.count == 4 && partialResets.unknownExpirationCount == 2)
        precondition(partialResets.expirations == [
            OmpBankedResets.Expiration(date: Date(timeIntervalSince1970: 1_794_007_139), count: 2)
        ])

        let expiryReference = Date(timeIntervalSince1970: 1_700_000_000)
        func expirySummary(after seconds: TimeInterval) -> String {
            OmpBankedResets(count: 1, expirations: [
                .init(date: expiryReference.addingTimeInterval(seconds), count: 1)
            ]).expirationSummary(at: expiryReference)
        }
        precondition(expirySummary(after: 8 * 86_400 + 86_399) == "8d")
        precondition(expirySummary(after: 86_400) == "1d")
        precondition(expirySummary(after: 86_399) == "23h")
        precondition(expirySummary(after: 3_600) == "1h")
        precondition(expirySummary(after: 3_599) == "<1h")
        precondition(expirySummary(after: 0) == "Expired")
        precondition(expirySummary(after: -3_600) == "Expired")
        let mixedExpiry = OmpBankedResets(count: 4, expirations: [
            .init(date: expiryReference.addingTimeInterval(2 * 86_400), count: 2),
            .init(date: expiryReference.addingTimeInterval(3 * 3_600), count: 1)
        ])
        precondition(mixedExpiry.expirationSummary(at: expiryReference) == "2×2d · 3h · ?")

        func expiryWarning(after seconds: TimeInterval) -> Bool {
            OmpBankedResets(count: 1, expirations: [
                .init(date: expiryReference.addingTimeInterval(seconds), count: 1)
            ]).needsExpiryWarning(at: expiryReference)
        }
        precondition(!expiryWarning(after: 86_400))
        precondition(expiryWarning(after: 86_399))
        precondition(expiryWarning(after: 0))
        precondition(expiryWarning(after: -3_600))
        precondition(!OmpBankedResets(count: 1, expirations: []).needsExpiryWarning(at: expiryReference))
        precondition(mixedExpiry.needsExpiryWarning(at: expiryReference))

        let organizationScopedAccount = try OmpUsageProbe.parse("""
        { "reports": [{
          "provider": "anthropic", "fetchedAt": 1000,
          "limits": [{ "scope": { "windowId": "5h" }, "amount": { "remainingFraction": 0.5 } }],
          "metadata": { "email": "same@example.com", "accountId": "live" }
        }], "accountsWithoutUsage": [
          { "provider": "anthropic", "email": "same@example.com", "accountId": "stale" },
          { "provider": "anthropic", "email": "same@example.com", "accountId": "organization", "orgId": "org-1" }
        ] }
        """)
        precondition(organizationScopedAccount.notes.count == 1)
        precondition(organizationScopedAccount.notes[0].value == "No usage reported")
    }

    @MainActor
    private static func processChecks() async throws {

        let started = Date()
        do {
            _ = try await OmpUsageProcess.run(
                executable: "/usr/bin/perl",
                arguments: ["-e", "$SIG{TERM} = 'IGNORE'; select undef, undef, undef, 2;"],
                timeout: 0.05
            )
            preconditionFailure("Expected timeout")
        } catch let error as OmpUsageProcessError {
            guard case .timedOut = error else { preconditionFailure("Expected timeout") }
        }
        precondition(Date().timeIntervalSince(started) < 1.5)

        let cancelled = Task {
            try await OmpUsageProcess.run(executable: "/bin/sleep", arguments: ["5"], timeout: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Expected cancellation")
        } catch let error as OmpUsageProcessError {
            guard case .cancelled = error else { preconditionFailure("Expected cancellation") }
        }
    }

    @MainActor
    private static func storeChecks() async throws {
        let defaults = try temporaryDefaults()
        let original = OmpUsageSnapshot(
            quotas: [OmpQuota(
                id: "original",
                label: "Claude 5h",
                group: "Claude",
                compactTitle: "5h",
                percentRemaining: 80,
                resetsAt: nil,
                fetchedAt: Date(timeIntervalSince1970: 100),
                dollarUsed: nil,
                dollarCap: nil
            )],
            notes: [],
            bankedResets: [:],
            completedAt: Date(timeIntervalSince1970: 101),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        let refreshedSource = Date(timeIntervalSince1970: 200)
        let refreshed = OmpUsageSnapshot(
            quotas: [OmpQuota(
                id: "refreshed",
                label: "Claude 5h",
                group: "Claude",
                compactTitle: "5h",
                percentRemaining: 75,
                resetsAt: nil,
                fetchedAt: refreshedSource,
                dollarUsed: nil,
                dollarCap: nil
            )],
            notes: [],
            bankedResets: [:],
            completedAt: Date(timeIntervalSince1970: 201),
            fetchedAt: refreshedSource
        )
        let failingProbe = StoreProbe(results: [.success(original), .failure(OmpUsageProcessError.commandFailed(1))])
        let store = OmpUsageStore(defaults: defaults) { force, _ in
            try await failingProbe.next(force: force)
        }
        await store.refresh()
        let savedSnapshot = store.snapshot
        await store.refresh() // Panel re-open stays inside the 60-second throttle.
        let failingCallCount = await failingProbe.callCount
        precondition(failingCallCount == 1)
        await store.refresh(force: true)
        precondition(store.snapshot?.completedAt == savedSnapshot?.completedAt)
        precondition(store.snapshot?.fetchedAt == savedSnapshot?.fetchedAt)
        precondition(store.snapshot?.quotas.map(\.id) == savedSnapshot?.quotas.map(\.id))
        precondition(store.lastError != nil)

        let repeatedRefreshResults: [Result<OmpUsageSnapshot, Error>] =
            [.success(original)] + Array(repeating: .success(refreshed), count: 32)
        let monitoringProbe = StoreProbe(results: repeatedRefreshResults)
        let monitored = OmpUsageStore(
            defaults: try temporaryDefaults(),
            probe: { force, _ in try await monitoringProbe.next(force: force) },
            refreshInterval: 0.01
        )
        monitored.startMonitoring()
        try await Task.sleep(nanoseconds: 200_000_000)
        monitored.stopMonitoring()
        precondition(monitored.snapshot?.fetchedAt == refreshed.fetchedAt)

        let slowProbe = SlowProbe(snapshot: original)
        let overlapping = OmpUsageStore(defaults: try temporaryDefaults()) { force, _ in
            await slowProbe.next(force: force)
        }
        let first = Task { @MainActor in await overlapping.refresh() }
        await Task.yield()
        let second = Task { @MainActor in await overlapping.refresh() }
        await first.value
        await second.value
        let slowCallCount = await slowProbe.callCount
        precondition(slowCallCount == 1)
    }

    @MainActor
    private static func temporaryDefaults() throws -> UserDefaults {
        let name = "OmpUsageCheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw CheckError.defaultsUnavailable }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private enum CheckError: Error {
    case defaultsUnavailable
}

private actor StoreProbe {
    private var results: [Result<OmpUsageSnapshot, Error>]
    private(set) var forces: [Bool] = []

    init(results: [Result<OmpUsageSnapshot, Error>]) {
        self.results = results
    }

    var callCount: Int { forces.count }

    func next(force: Bool) throws -> OmpUsageSnapshot {
        forces.append(force)
        return try results.removeFirst().get()
    }
}

private actor SlowProbe {
    private let snapshot: OmpUsageSnapshot
    private(set) var forces: [Bool] = []

    init(snapshot: OmpUsageSnapshot) {
        self.snapshot = snapshot
    }

    var callCount: Int { forces.count }

    func next(force: Bool) async -> OmpUsageSnapshot {
        forces.append(force)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return snapshot
    }
}
#endif

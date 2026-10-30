import Foundation
import Darwin

enum OmpUsageProcessError: LocalizedError, Sendable {
    case cliNotFound
    case couldNotStart
    case commandFailed(Int32)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Oh My Pi was not found. Install omp, or use Path above to set its location."
        case .couldNotStart:
            return "Oh My Pi could not be started. Use Path above to check its location."
        case .commandFailed(let status):
            return "Oh My Pi usage check failed (exit \(status)). Run `omp usage` in Terminal, then try again."
        case .timedOut:
            return "Oh My Pi usage check timed out. Try again after checking your network."
        case .cancelled:
            return nil
        }
    }
}

struct OmpUsageProcessResult: Sendable {
    let standardOutput: String
    let exitCode: Int32
}

/// Foundation-only process boundary shared with the unsandboxed XPC helper.
enum OmpUsageProcess {
    static let defaultTimeout: TimeInterval = 30

    static func fetch(binaryPath: String, force: Bool) async throws -> String {
        let binary = try locateBinary(override: binaryPath)
        if force {
            let invalidation = try await run(
                executable: binary,
                arguments: ["usage", "invalidate"],
                timeout: defaultTimeout
            )
            guard invalidation.exitCode == 0 else {
                throw OmpUsageProcessError.commandFailed(invalidation.exitCode)
            }
        }

        let result = try await run(
            executable: binary,
            arguments: ["usage", "--json"],
            timeout: defaultTimeout
        )
        guard result.exitCode == 0 else {
            throw OmpUsageProcessError.commandFailed(result.exitCode)
        }
        try Task.checkCancellation()
        return result.standardOutput
    }

    /// Internal so the standalone regression check can exercise timeout and
    /// cancellation with a temporary fake executable rather than real omp.
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> OmpUsageProcessResult {
        guard timeout.isFinite, timeout > 0 else { throw OmpUsageProcessError.timedOut }
        let runner = RunningProcess(executable: executable, arguments: arguments)
        do {
            let result = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withThrowingTaskGroup(of: OmpUsageProcessResult.self) { group in
                    group.addTask {
                        try await runner.result()
                    }
                    group.addTask {
                        let nanoseconds = UInt64(min(timeout, 3_600) * 1_000_000_000)
                        try await Task.sleep(nanoseconds: nanoseconds)
                        runner.terminate()
                        throw OmpUsageProcessError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw OmpUsageProcessError.couldNotStart
                    }
                    return result
                }
            }, onCancel: {
                runner.terminate()
            })
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw OmpUsageProcessError.cancelled
        }
    }

    private static func locateBinary(override: String) throws -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let customPath = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPath.isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if expanded.contains("/") {
                guard fileManager.isExecutableFile(atPath: expanded) else { throw OmpUsageProcessError.cliNotFound }
                return expanded
            }
            if let located = binary(named: expanded, home: home, fileManager: fileManager) {
                return located
            }
            throw OmpUsageProcessError.cliNotFound
        }
        guard let located = binary(named: "omp", home: home, fileManager: fileManager) else {
            throw OmpUsageProcessError.cliNotFound
        }
        return located
    }

    private static func binary(named name: String, home: String, fileManager: FileManager) -> String? {
        for directory in searchPath(home: home) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func searchPath(home: String) -> [String] {
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let known = [
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.npm/bin",
            "\(home)/npm/bin",
            "/usr/bin",
            "/bin"
        ]
        var paths: [String] = []
        var seen = Set<String>()
        for path in inherited + known where !path.isEmpty && seen.insert(path).inserted {
            paths.append(path)
        }
        return paths
    }

    private static func processEnvironment(home: String) -> [String: String] {
        ["HOME": home, "PATH": searchPath(home: home).joined(separator: ":")]
    }

    private final class RunningProcess: @unchecked Sendable {
        private static let executionQueue = DispatchQueue(
            label: "local.browww.omp-usage-process",
            qos: .utility,
            attributes: .concurrent
        )
        private static let drainQueue = DispatchQueue(
            label: "local.browww.omp-usage-drain",
            qos: .utility,
            attributes: .concurrent
        )

        private let executable: String
        private let arguments: [String]
        private let lock = NSLock()
        private var process: Process?
        private var shouldTerminate = false

        init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }

        func result() async throws -> OmpUsageProcessResult {
            try await withCheckedThrowingContinuation { continuation in
                Self.executionQueue.async {
                    continuation.resume(with: Result {
                        try self.runBlocking()
                    })
                }
            }
        }

        func terminate() {
            lock.lock()
            shouldTerminate = true
            let process = process
            lock.unlock()
            if let process { terminate(process) }
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            let ownsProcessGroup = getpgid(pid) == pid
            Self.executionQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                if process.isRunning {
                    kill(ownsProcessGroup ? -pid : pid, SIGKILL)
                }
            }
        }

        private func runBlocking() throws -> OmpUsageProcessResult {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = OmpUsageProcess.processEnvironment(
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch {
                throw OmpUsageProcessError.couldNotStart
            }

            lock.lock()
            self.process = process
            let shouldTerminate = self.shouldTerminate
            lock.unlock()
            if shouldTerminate { terminate(process) }
            defer {
                lock.lock()
                self.process = nil
                lock.unlock()
            }

            let output = OutputBox()
            let drains = DispatchGroup()
            drains.enter()
            Self.drainQueue.async {
                output.set(standardOutput.fileHandleForReading.readDataToEndOfFile())
                drains.leave()
            }
            drains.enter()
            Self.drainQueue.async {
                _ = standardError.fileHandleForReading.readDataToEndOfFile()
                drains.leave()
            }
            process.waitUntilExit()
            drains.wait()
            return OmpUsageProcessResult(
                standardOutput: String(decoding: output.value, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }
    }
}

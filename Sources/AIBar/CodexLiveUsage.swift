import Foundation

struct CodexLiveLimits {
    var primary: RateWindow?
    var secondary: RateWindow?
    var planType: String?
    var accountEmail: String?
}

/// Reads the signed-in account's current limits from the local Codex app-server.
/// This is the same read-only account method used by Codex's `/usage` UI; it does
/// not create a model turn or consume quota.
struct CodexLiveUsageClient {
    private let fileManager: FileManager
    private let now: Date
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.now = now
        self.environment = environment
    }

    func fetch(timeout: TimeInterval = 12) -> CodexLiveLimits? {
        guard let executable = executableURL() else { return nil }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let response = CodexAppServerResponse()
        let completed = DispatchSemaphore(value: 0)

        process.executableURL = executable
        process.environment = environment
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { completed.signal(); return }
            if response.append(data), response.hasCompleted {
                completed.signal()
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let messages = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"aibar","version":"1.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#,
            #"{"id":3,"method":"account/rateLimits/read","params":null}"#
        ].joined(separator: "\n") + "\n"

        do {
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return nil
        }

        let didComplete = completed.wait(timeout: .now() + max(timeout, 1)) == .success
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard didComplete, let result = response.result else { return nil }
        var limits = parse(result)
        limits?.accountEmail = response.accountEmail
        return limits
    }

    private func parse(_ result: [String: Any]) -> CodexLiveLimits? {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let snapshot = (buckets?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let snapshot else { return nil }

        let primary = rateWindow(from: snapshot["primary"] as? [String: Any])
        let secondary = rateWindow(from: snapshot["secondary"] as? [String: Any])
        guard primary != nil || secondary != nil else { return nil }

        return CodexLiveLimits(
            primary: primary,
            secondary: secondary,
            planType: snapshot["planType"] as? String
        )
    }

    private func rateWindow(from dictionary: [String: Any]?) -> RateWindow? {
        guard let dictionary else { return nil }
        let used = number(dictionary["usedPercent"])
        let duration = integer(dictionary["windowDurationMins"])
        let reset = number(dictionary["resetsAt"])
        let resetsAt = reset.map { Date(timeIntervalSince1970: $0) }
        guard used != nil || resetsAt != nil else { return nil }

        return RateWindow(
            usedPercent: used,
            windowMinutes: duration,
            resetsAt: resetsAt,
            isExpired: resetsAt.map { $0 <= now } ?? false
        )
    }

    private func executableURL() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [String] = []
        if let installDir = environment["CODEX_INSTALL_DIR"], !installDir.isEmpty {
            let expandedDir = (installDir as NSString).expandingTildeInPath
            candidates.append(URL(fileURLWithPath: expandedDir).appendingPathComponent("codex").path)
        }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path,
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }
}

private final class CodexAppServerResponse {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var result: [String: Any]?
    private(set) var accountEmail: String?
    private var receivedAccount = false
    private var receivedLimits = false
    private var didSignal = false

    var hasCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard receivedLimits, receivedAccount, !didSignal else { return false }
        didSignal = true
        return true
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            if id == 2 {
                receivedAccount = true
                let account = (object["result"] as? [String: Any])?["account"] as? [String: Any]
                accountEmail = account?["email"] as? String
            } else if id == 3 {
                receivedLimits = true
                result = object["result"] as? [String: Any]
            }
        }
        return receivedLimits && receivedAccount
    }
}

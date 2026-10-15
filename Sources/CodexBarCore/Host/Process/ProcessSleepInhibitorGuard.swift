import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Releases the Claude CLI's built-in macOS inhibitor only inside an explicitly opted-in passive probe.
/// This is a fallback until the CLI exposes a supported per-invocation sleep-prevention opt-out.
final class ProcessSleepInhibitorGuard: @unchecked Sendable {
    private let root: TTYProcessTreeTerminator.ProcessIdentity
    private let timer: any DispatchSourceTimer
    private let lock = NSLock()
    private var stopped = false

    private init(root: TTYProcessTreeTerminator.ProcessIdentity) {
        self.root = root
        self.timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.steipete.codexbar.passive-probe-sleep", qos: .utility))
        self.timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        self.timer.setEventHandler { [weak self] in self?.releaseInhibitors() }
        self.timer.resume()
    }

    static func start(processID: Int32) -> ProcessSleepInhibitorGuard? {
        #if canImport(Darwin)
        guard let root = TTYProcessTreeTerminator.processIdentity(for: processID) else { return nil }
        return ProcessSleepInhibitorGuard(root: root)
        #else
        return nil
        #endif
    }

    func stop() {
        self.lock.withLock {
            self.stopped = true
            self.timer.cancel()
        }
    }

    deinit {
        self.stop()
    }

    static func isClaudeSleepInhibitor(executablePath: String, arguments: [String]) -> Bool {
        // Match the known built-in invocation, not arbitrary caffeinate utilities or user commands.
        executablePath == "/usr/bin/caffeinate" &&
            arguments.count == 4 &&
            Array(arguments.dropFirst()) == ["-i", "-t", "300"]
    }

    private func releaseInhibitors() {
        #if canImport(Darwin)
        guard TTYProcessTreeTerminator.isCurrent(self.root) else {
            self.stop()
            return
        }
        for pid in TTYProcessTreeTerminator.descendantPIDs(of: self.root.pid) {
            guard let identity = TTYProcessTreeTerminator.processIdentity(for: pid),
                  let executable = DarwinProcessEnumerator.executablePath(pid: pid),
                  let arguments = DarwinProcessEnumerator.arguments(pid: pid),
                  Self.isClaudeSleepInhibitor(executablePath: executable, arguments: arguments)
            else { continue }

            self.lock.withLock {
                // Revalidate ancestry and both start tokens immediately before signaling. A cached PID or a
                // matching command line alone must never authorize stopping a user's unrelated inhibitor.
                guard !self.stopped,
                      TTYProcessTreeTerminator.isCurrent(self.root),
                      TTYProcessTreeTerminator.isCurrent(identity),
                      self.isDescendant(pid),
                      DarwinProcessEnumerator.executablePath(pid: pid) == executable,
                      DarwinProcessEnumerator.arguments(pid: pid) == arguments
                else { return }
                kill(pid, SIGTERM)
            }
        }
        #endif
    }

    #if canImport(Darwin)
    private func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, seen.insert(current).inserted {
            guard let info = DarwinProcessEnumerator.bsdInfo(pid: current) else { return false }
            if info.ppid == self.root.pid { return true }
            current = info.ppid
        }
        return false
    }
    #endif
}

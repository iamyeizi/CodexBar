import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin

struct ProcessSleepInhibitorGuardTests {
    @Test
    func `only the known CLI inhibitor invocation is eligible`() {
        let expected = ["caffeinate", "-i", "-t", "300"]
        #expect(ProcessSleepInhibitorGuard.isClaudeSleepInhibitor(
            executablePath: "/usr/bin/caffeinate", arguments: expected))
        for arguments in [
            ["caffeinate", "-u", "-dmi", "-t", "300"],
            ["caffeinate", "-i"],
            ["caffeinate", "-i", "-t", "300", "/usr/bin/true"],
            ["caffeinate", "-i", "-t", "60"],
            ["caffeinate", "-w", "123"],
        ] {
            #expect(!ProcessSleepInhibitorGuard.isClaudeSleepInhibitor(
                executablePath: "/usr/bin/caffeinate", arguments: arguments))
        }
        #expect(!ProcessSleepInhibitorGuard.isClaudeSleepInhibitor(
            executablePath: "/tmp/caffeinate", arguments: expected))
    }

    @Test
    func `passive probe releases renewed inhibitors but preserves identical unrelated inhibitors`() async throws {
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        external.arguments = ["-i", "-t", "300"]
        try external.run()
        defer {
            if external.isRunning { external.terminate() }
            external.waitUntilExit()
        }

        let result = try await SubprocessRunner.run(
            binary: "/bin/sh",
            arguments: ["-c", """
            for attempt in 1 2; do
                /usr/bin/caffeinate -i -t 300 &
                wait $!
                printf 'inhibitor-exit:%s\\n' "$?"
            done
            printf 'probe-completed\\n'
            """],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10,
            suppressSleepInhibitors: true,
            label: "synthetic-passive-sleep-probe")

        #expect(result.stdout.contains("probe-completed"))
        #expect(result.stdout.components(separatedBy: "inhibitor-exit:143").count == 3)
        #expect(external.isRunning)
    }

    @Test
    func `ordinary subprocesses do not opt into suppression`() async throws {
        do {
            _ = try await SubprocessRunner.run(
                binary: "/bin/sh",
                arguments: ["-c", "/usr/bin/caffeinate -i -t 300 & wait $!; printf 'unexpected-release'"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2,
                label: "synthetic-ordinary-sleep-probe")
            Issue.record("An ordinary subprocess should retain its inhibitor until the test timeout")
        } catch SubprocessRunnerError.timedOut {
            // The default runner does not release sleep assertions. Timeout teardown reaps the test child.
        }
    }

    @Test
    func `stopping the guard prevents later inhibitors from being signaled`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarSleepGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.environment = ["PATH": "/usr/bin:/bin", "READY": ready.path, "CHILD_PID": childPIDFile.path]
        parent.arguments = ["-c", """
        while [ ! -f "$READY" ]; do /bin/sleep 0.05; done
        /usr/bin/caffeinate -i -t 300 &
        printf '%s' "$!" > "$CHILD_PID"
        wait $!
        """]
        try parent.run()
        var inhibitor: TTYProcessTreeTerminator.ProcessIdentity?
        defer {
            if let inhibitor, TTYProcessTreeTerminator.isCurrent(inhibitor) { kill(inhibitor.pid, SIGTERM) }
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }
        let guardObject = try #require(ProcessSleepInhibitorGuard.start(processID: parent.processIdentifier))
        guardObject.stop()
        try Data().write(to: ready)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: childPIDFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = try String(contentsOf: childPIDFile, encoding: .utf8)
        let pid = try #require(Int32(text))
        inhibitor = try #require(TTYProcessTreeTerminator.processIdentity(for: pid))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(try TTYProcessTreeTerminator.isCurrent(#require(inhibitor)))
    }
}
#endif

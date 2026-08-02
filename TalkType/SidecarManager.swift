import Foundation

/// Owns the local ASR sidecar process (`~/.talktype/asr/server.py`).
///
/// The sidecar holds Qwen3-ASR in memory, so it is started once at launch rather than
/// per dictation — a cold weight load costs about a second, a warm inference about 0.3 s.
/// It binds its socket before loading weights, so the app can connect immediately and
/// poll `/health` instead of racing startup.
final class SidecarManager {

    enum InstallState: Equatable {
        case ready
        case missing(String)

        var problem: String? {
            if case .missing(let what) = self { return what }
            return nil
        }
    }

    private var process: Process?
    /// Held open for the sidecar's lifetime. The child reads its stdin and exits on EOF,
    /// so it dies with us even when we are SIGKILLed or crash — `stop()` alone would leak
    /// a multi-gigabyte process on any exit that isn't clean.
    private var lifelinePipe: Pipe?
    private let lock = NSLock()

    // MARK: - Paths

    static var asrDir: URL { AppIdentity.stateDir.appendingPathComponent("asr") }
    static var pythonPath: URL { asrDir.appendingPathComponent("venv/bin/python") }
    static var serverPath: URL { asrDir.appendingPathComponent("server.py") }
    static var huggingFaceHome: URL { asrDir.appendingPathComponent("hf") }
    static var logPath: URL { asrDir.appendingPathComponent("server.log") }

    // MARK: - Install check

    static func installState() -> InstallState {
        let fm = FileManager.default
        for (path, label) in [
            (Self.pythonPath, "Python environment (venv)"),
            (Self.serverPath, "server.py"),
            (Self.huggingFaceHome, "model weights (hf)"),
        ] where !fm.fileExists(atPath: path.path) {
            return .missing("\(label) at \(path.path)")
        }
        return .ready
    }

    // MARK: - Lifecycle

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Launch the sidecar. No-op when one is already running — including one started
    /// outside the app, which `alreadyServing` detects so we never bind-conflict with it.
    @discardableResult
    func start(port: Int, alreadyServing: Bool) -> InstallState {
        if alreadyServing {
            print("[sidecar] an ASR server is already serving on \(port) — using it")
            return .ready
        }
        if isRunning { return .ready }

        let state = Self.installState()
        guard state == .ready else {
            print("[sidecar] not installed: \(state.problem ?? "unknown")")
            return state
        }

        let proc = Process()
        proc.executableURL = Self.pythonPath
        proc.arguments = [Self.serverPath.path, "--port", String(port), "--watch-parent"]
        proc.currentDirectoryURL = Self.asrDir

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = Self.huggingFaceHome.path
        env["HF_HUB_OFFLINE"] = "1"          // never reach for the network at inference time
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        // The sidecar's own log is the record; the app only notes lifecycle events.
        FileManager.default.createFile(atPath: Self.logPath.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: Self.logPath) {
            handle.seekToEndOfFile()
            proc.standardOutput = handle
            proc.standardError = handle
        }

        let lifeline = Pipe()
        proc.standardInput = lifeline

        proc.terminationHandler = { [weak self] finished in
            print("[sidecar] exited with status \(finished.terminationStatus)")
            self?.lock.lock()
            self?.process = nil
            self?.lifelinePipe = nil
            self?.lock.unlock()
        }

        do {
            try proc.run()
            lock.lock()
            process = proc
            lifelinePipe = lifeline
            lock.unlock()
            print("[sidecar] started pid \(proc.processIdentifier) on port \(port)")
            return .ready
        } catch {
            print("[sidecar] failed to start: \(error)")
            return .missing("could not launch: \(error.localizedDescription)")
        }
    }

    /// Terminate the sidecar. SIGTERM first; the model holds no unflushed state, so a
    /// SIGKILL after a short grace period is safe and keeps app quit from hanging.
    func stop() {
        lock.lock()
        let proc = process
        let lifeline = lifelinePipe
        process = nil
        lifelinePipe = nil
        lock.unlock()

        // Closing the lifeline is what the sidecar actually watches for; terminate() is
        // just the faster path when we do get to exit cleanly.
        try? lifeline?.fileHandleForWriting.close()

        guard let proc = proc, proc.isRunning else { return }
        proc.terminate()

        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        print("[sidecar] stopped")
    }
}

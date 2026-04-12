import Foundation

/// Global in-memory log buffer plus an on-disk session sink. Every
/// `slog(...)` call prints to the Xcode console (so tethered debugging
/// via `print` still works), appends to a capped ring buffer (so the
/// "Copy logs" button in the tuning panel stays working), AND — while
/// a session is open — appends to a `.log` file in the app's Documents
/// directory so the logs can be retrieved untethered via the Share
/// button or the Files app.
///
/// Untethered workflow:
///   1. Tap Start → `startSession()` creates
///      `Documents/sessions/<yyyy-MM-dd_HHmmss>.log` and opens it.
///   2. Run your physical test. Every detector/camera `slog(...)` call
///      lands in the file as a line.
///   3. Tap Stop → `endSession()` closes the file.
///   4. Tap "Share session file" in the tuning panel → AirDrop the
///      latest `.log` to your Mac, or browse Files → On My iPhone →
///      claudephotofinish → sessions to grab any historical run.
final class SessionLogger {
    static let shared = SessionLogger()

    /// Hard cap on buffered lines. Dense detector runs can emit ~40 lines
    /// per frame burst (COMP, DETECT_DIAG, HRUN_PROFILE, DETECT, REJECT);
    /// 20k lines covers many minutes of continuous testing. When full,
    /// oldest entries are dropped (ring semantics).
    private let capacity = 20_000

    private let queue = DispatchQueue(label: "SessionLogger.buffer",
                                      attributes: .concurrent)
    private var buffer: [String] = []

    /// Open file handle for the current session, if any. Guarded by the
    /// same barrier queue as `buffer` so file writes and buffer mutations
    /// are serialized against each other.
    private var sessionHandle: FileHandle?

    /// URL of the most recently opened session file. Retained after
    /// `endSession()` so the Share button can still find it.
    private var latestURL: URL?

    private init() {}

    // MARK: - Logging

    /// Append a line and mirror it to the Xcode console and (if a session
    /// is open) the current session file.
    func log(_ message: String) {
        print(message)
        queue.async(flags: .barrier) {
            // Ring buffer
            self.buffer.append(message)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            // File sink. Best-effort: a failed write must never tear down
            // the ring buffer path or affect the capture pipeline timing.
            if let handle = self.sessionHandle,
               let data = (message + "\n").data(using: .utf8) {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    print("[SessionLogger] file write failed: \(error)")
                }
            }
        }
    }

    // MARK: - Session file lifecycle

    /// Open a new session file in `Documents/sessions/` and start mirroring
    /// every subsequent `log(...)` call to it. Safe to call even if a
    /// previous session is still open — the old handle will be closed
    /// first. Returns the URL of the new file, or `nil` on failure.
    @discardableResult
    func startSession() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[SessionLogger] no Documents directory")
            return nil
        }
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[SessionLogger] createDirectory failed: \(error)")
            return nil
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = df.string(from: Date())
        let url = dir.appendingPathComponent("session_\(stamp).log", isDirectory: false)

        // Create empty file (overwrites if a duplicate stamp somehow collided).
        fm.createFile(atPath: url.path, contents: nil, attributes: nil)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            print("[SessionLogger] FileHandle open failed for \(url.path)")
            return nil
        }

        queue.sync(flags: .barrier) {
            // Close any previous session handle before swapping.
            if let old = self.sessionHandle {
                try? old.close()
            }
            self.sessionHandle = handle
            self.latestURL = url
        }

        // Header line — written through the normal log() path so it also
        // lands in the ring buffer and the console.
        let header = "# session started \(ISO8601DateFormatter().string(from: Date())) file=\(url.lastPathComponent)"
        log(header)
        return url
    }

    /// Close the current session file (if any). Safe to call when no
    /// session is active. The `latestURL` is preserved so the Share
    /// button can still find the file after the session ends.
    func endSession() {
        // Write a footer before closing so the file has a clear end.
        log("# session ended \(ISO8601DateFormatter().string(from: Date()))")
        queue.sync(flags: .barrier) {
            if let handle = self.sessionHandle {
                try? handle.synchronize()
                try? handle.close()
            }
            self.sessionHandle = nil
        }
    }

    // MARK: - Accessors

    /// Snapshot the current ring buffer as a single newline-joined string.
    func snapshot() -> String {
        queue.sync { buffer.joined(separator: "\n") }
    }

    /// Current line count (for UI readout).
    var lineCount: Int {
        queue.sync { buffer.count }
    }

    /// Drop all buffered lines. Does NOT touch session files on disk.
    func clear() {
        queue.async(flags: .barrier) {
            self.buffer.removeAll(keepingCapacity: true)
        }
    }

    /// URL of the most recently opened session file, whether or not it's
    /// still being written. `nil` if no session has been started since
    /// the app launched (in which case the Share button should fall back
    /// to the newest file it can find on disk — see `mostRecentSessionFileURL`).
    func latestSessionFileURL() -> URL? {
        queue.sync { latestURL }
    }

    /// List every `.log` file currently in `Documents/sessions/`, newest
    /// first. Used by the tuning panel to show how many persisted sessions
    /// exist and to power "Share all sessions" if we ever want that.
    func allSessionFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        let urls = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// Convenience: the latest session URL if one is known for this app
    /// launch, otherwise the newest `.log` file on disk. This is what the
    /// Share button should call so it works on the very first post-launch
    /// session AND when re-sharing a previous run.
    func mostRecentSessionFileURL() -> URL? {
        if let u = latestSessionFileURL() { return u }
        return allSessionFileURLs().first
    }
}

/// Shorthand for `SessionLogger.shared.log(_:)`. Use instead of `print`
/// in detection/camera code so untethered test runs can be copied out
/// of the app via the tuning panel.
func slog(_ message: String) {
    SessionLogger.shared.log(message)
}

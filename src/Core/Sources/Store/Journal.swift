import Foundation
import os

/// The app's own diary of what it did, kept on the phone.
///
/// Everything here is also written to the system log, and the system log is the
/// better tool — when a Mac is at hand. Sending is the part of this app nobody
/// watches: it happens in launches that last two seconds, hours apart, days
/// after anybody last opened the app. By the time the phone is plugged into
/// anything the interesting launch is long over, and `OSLogStore` hands back
/// only the running process. So the app writes its own account down and keeps
/// it, and the everyday screen can hand it over.
///
/// What goes in it: days by date, counts, HTTP codes, error text. What never
/// does: a reading, a key, or anything that opens the archive. The diary is
/// made to be shared, so it holds nothing that would matter if it were.
public final class Journal: @unchecked Sendable {
    public static let shared = Journal(url: Journal.defaultURL())

    private let url: URL
    /// The diary is trimmed rather than rotated: one file, oldest half dropped
    /// when it grows past this. Half a megabyte is a few weeks of ordinary
    /// sending and a bad afternoon of retries.
    private let cap: Int
    private let lock = NSLock()
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public init(url: URL, cap: Int = 512 * 1024) {
        self.url = url
        self.cap = cap
    }

    /// Write one line down. Never throws and never blocks anything important:
    /// a diary that can stop the sending it is there to explain is worse than
    /// no diary.
    public func note(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(category) \(oneLine(message))\n"
        guard let bytes = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            if try handle.offset() > UInt64(cap) {
                try? handle.close()
                trim()
            }
        } catch {
            // Deliberately silent. There is nowhere left to report a diary that
            // cannot be written, and the app has real work to get on with.
        }
    }

    /// Everything written down, oldest first.
    public func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop the oldest half, at a line boundary so nothing is left in pieces.
    private func trim() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = text.suffix(text.count / 2)
        let whole = keep.firstIndex(of: "\n").map { keep[keep.index(after: $0)...] } ?? keep
        try? String(whole).write(to: url, atomically: true, encoding: .utf8)
    }

    /// One entry is one line: a message that wrapped would read as several
    /// entries with no time on them.
    private func oneLine(_ message: String) -> String {
        message.replacingOccurrences(of: "\n", with: " ")
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("efferent", isDirectory: true)
            .appendingPathComponent("journal.log")
    }
}

/// What the app writes with: the system log for a Mac at hand, and the diary
/// for every launch nobody was watching.
///
/// It takes a plain string rather than an `os` interpolation because the same
/// text has to reach both, and because everything this app logs is already
/// public by intent — day dates, counts and answers from the archive, never a
/// reading and never a key.
public struct Log: Sendable {
    private let logger: Logger
    private let category: String
    private let journal: Journal

    public init(category: String, journal: Journal = .shared) {
        logger = Logger(subsystem: "dev.korchasa.efferent", category: category)
        self.category = category
        self.journal = journal
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        journal.note(category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        journal.note(category, "ERROR \(message)")
    }
}

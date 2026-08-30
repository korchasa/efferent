import Foundation
import os

/// The app's own log, kept on the phone.
///
/// Everything here is also written to the system log, and the system log is the
/// better tool — when a Mac is at hand. Sending is the part of this app nobody
/// watches: it happens in launches that last two seconds, hours apart, days
/// after anybody last opened the app. By the time the phone is plugged into
/// anything the interesting launch is long over, and `OSLogStore` hands back
/// only the running process. So the app writes its own account down and keeps
/// it, and the everyday screen can hand it over.
///
/// What goes in it: days by date, counts, sizes, HTTP codes, error text. What
/// never does: a reading, a key, or anything that opens the archive. The log is
/// made to be shared, so it holds nothing that would matter if it were.
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore(url: LogStore.defaultURL())

    private let url: URL
    /// One file, oldest half dropped when it grows past this. Half a megabyte
    /// is a few days of the detail this log now keeps.
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
    /// a log that can stop the sending it is there to explain is worse than no
    /// log at all.
    public func note(_ level: String, _ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(category) \(oneLine(message))\n"
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
            // Deliberately silent. There is nowhere left to report a log that
            // cannot be written, and the app has real work to get on with.
        }
    }

    /// Everything written down, oldest first.
    public func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The end of the log, and how much was left behind.
    ///
    /// The whole file is what gets shared; the screen only ever draws this. A
    /// log at its cap is half a megabyte of monospaced text, and a view that
    /// lays all of it out at once takes long enough to look broken. What
    /// somebody opening the log came for is at the end of it anyway.
    public func tail(_ limit: Int = 64 * 1024) -> Excerpt {
        let whole = read()
        guard whole.utf8.count > limit else {
            return Excerpt(text: whole, hidden: 0)
        }
        // Cutting by bytes can land inside a character, so the first line is
        // always dropped — it is a partial line in any case.
        var text = String(decoding: Array(whole.utf8).suffix(limit), as: UTF8.self)
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return Excerpt(text: text, hidden: Self.lines(whole) - Self.lines(text))
    }

    /// A slice of the log with a count of the lines it does not include.
    public struct Excerpt: Equatable, Sendable {
        public let text: String
        public let hidden: Int

        public init(text: String, hidden: Int) {
            self.text = text
            self.hidden = hidden
        }
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

    private static func lines(_ text: String) -> Int {
        text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("efferent", isDirectory: true)
            .appendingPathComponent("efferent.log")
    }
}

/// What the app writes with: the system log for a Mac at hand, and the log file
/// for every launch nobody was watching.
///
/// It takes a plain string rather than an `os` interpolation because the same
/// text has to reach both, and because everything this app logs is already
/// public by intent — day dates, counts, sizes and answers from the archive,
/// never a reading and never a key.
///
/// Three levels, and the difference is who the line is for. `info` is the
/// account of what happened: a person reading it should be able to follow the
/// sending. `debug` is the step-by-step underneath — every day built, every
/// request signed, every page of a listing — which is what a strange sending
/// problem is actually diagnosed from. `error` is what went wrong.
public struct Log: Sendable {
    private let logger: Logger
    private let category: String
    private let store: LogStore

    public init(category: String, store: LogStore = .shared) {
        logger = Logger(subsystem: "dev.korchasa.efferent", category: category)
        self.category = category
        self.store = store
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        store.note("DEBUG", category, message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        store.note("INFO ", category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        store.note("ERROR", category, message)
    }
}

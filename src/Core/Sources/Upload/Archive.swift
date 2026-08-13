import Foundation
import os

/// What the archive says it holds.
///
/// The device keeps a fingerprint per day, and that fingerprint is a claim
/// about the *archive*: "it already holds exactly this". Nothing ever tested
/// the claim, so an archive that lost a day — a bucket recreated, objects
/// deleted, a move that dropped some — left the device certain of something
/// untrue, and certain of it forever: the day rebuilds identically, matches the
/// fingerprint, and is never sent again.
///
/// This is the test. It reads the one thing the service will say for free — the
/// names of the days it has — and hands them back so the two can be compared.
/// Nothing here decrypts, and nothing here writes.
///
/// **A partial answer is never returned.** Every failure throws. A walk that
/// stopped halfway and reported what it had would say the rest of the archive
/// does not exist, and the caller would dutifully re-upload a decade — or, if
/// the comparison ever ran the other way, delete one.
public struct Archive {
    /// Days asked for at a time. The service caps the page anyway; this only
    /// decides how few round trips a walk takes.
    public static let pageSize = 1000

    /// Enough pages for a lifetime of days several times over. It exists so a
    /// service answering nonsense ends the walk loudly rather than spinning.
    public static let maxPages = 200

    public enum ArchiveError: Error, Equatable {
        case refused(status: Int)
        case malformed(String)
        case tooManyPages
    }

    private let destination: Destination
    private let fetch: (URL) async throws -> Data
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "archive")

    public init(destination: Destination, fetch: @escaping (URL) async throws -> Data) {
        self.destination = destination
        self.fetch = fetch
    }

    /// The default reader: an ordinary session, not the background one.
    ///
    /// This runs at the head of a pass and its answer is needed before anything
    /// can be decided, so handing it to a daemon to finish later would be no
    /// use. It is also small — a few hundred kilobytes for a decade — and a
    /// timeout is what keeps a dead network from holding up the send.
    public init(destination: Destination, timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)

        self.init(destination: destination) { url in
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw ArchiveError.malformed("no HTTP response")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw ArchiveError.refused(status: http.statusCode)
            }
            return data
        }
    }

    private struct Page: Decodable {
        struct Entry: Decodable { let day: String }
        let days: [Entry]
        /// Where to continue, or absent at the end. Following it until it comes
        /// back null is the only way to see an archive of any size; a reader
        /// that took the first page would call the rest of a decade missing.
        let next: String?
    }

    /// Every day the archive holds, as names.
    public func days() async throws -> Set<String> {
        var held: Set<String> = []
        var after: String?

        for page in 0 ..< Self.maxPages {
            var components = URLComponents(url: destination.daysURL, resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            if let after {
                query.append(URLQueryItem(name: "after", value: after))
            }
            components?.queryItems = query
            guard let url = components?.url else {
                throw ArchiveError.malformed("could not build the listing address")
            }

            let body = try await fetch(url)
            let answer: Page
            do {
                answer = try JSONDecoder().decode(Page.self, from: body)
            } catch {
                throw ArchiveError.malformed(String(describing: error))
            }

            for entry in answer.days {
                held.insert(entry.day)
            }
            guard let next = answer.next else {
                log.info("archive holds \(held.count) days, read in \(page + 1) pages")
                return held
            }
            after = next
        }

        throw ArchiveError.tooManyPages
    }
}

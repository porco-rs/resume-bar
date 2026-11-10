// Protocol between the CLI `rb` and RBServer inside the app.
// One JSON object per line, one request per connection. Who is calling and from where comes from the socket and the
// process table, never from the request: a request cannot claim to be someone else.

import Foundation

public enum RBRequest: Codable, Sendable, Equatable {
    /// `rb ls [-a] [-p name]`
    case list(allProjects: Bool, project: String?)
    /// `rb add "text" [--bis word] [-p name]`; `deadline` is the raw word, parsed by the app.
    case add(text: String, deadline: String?, project: String?)
    /// `rb start <id|text> [--cc]`
    case start(query: String, tool: Tool?, project: String?)
    /// `rb done [id|text]`; nil means the strand of the calling session.
    case done(query: String?, project: String?)
    /// `rb bis <id|text> <word|->`; nil removes the deadline.
    case setDeadline(query: String, deadline: String?, project: String?)
    /// `rb export`
    case export
}

/// Derived from the process chain of the connecting peer; the nearest known tool wins (a Codex started by Claude is Codex).
public enum RBCaller: String, Codable, Sendable, CaseIterable {
    case person, claude, codex
}

public struct RBCallerInfo: Sendable, Equatable {
    public var caller: RBCaller
    /// Working directory of the connecting process; nil when it cannot be read.
    public var cwd: String?
    /// The connecting process and its ancestors, nearest first; `rb done` without a target finds the calling session here.
    public var processChain: [Int32]

    public init(caller: RBCaller, cwd: String?, processChain: [Int32] = []) {
        self.caller = caller
        self.cwd = cwd
        self.processChain = processChain
    }
}

public struct RBEntryLine: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: EntryStatus
    public var projectName: String?
    /// YYYY-MM-DD
    public var deadline: String?
    public var sessionCount: Int
    /// An AI created or finished this and the user has not confirmed it yet (an open `Change`).
    public var awaitsConfirmation: Bool

    public init(id: String, title: String, status: EntryStatus, projectName: String?, deadline: String?, sessionCount: Int,
                awaitsConfirmation: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.projectName = projectName
        self.deadline = deadline
        self.sessionCount = sessionCount
        self.awaitsConfirmation = awaitsConfirmation
    }
}

public enum RBErrorCode: String, Codable, Sendable, CaseIterable {
    case notFound = "nicht_gefunden"
    case foreignProject = "fremdes_projekt"
    case invalidDeadline = "ungueltige_deadline"
    case ambiguous = "mehrdeutig"
    case notAllowed = "nicht_erlaubt"
    case badRequest = "ungueltige_anfrage"
    /// Access is switched off in the settings.
    case accessOff = "zugriff_aus"
    /// The calling process could not be identified, so the request is refused unchanged.
    case callerUnknown = "aufrufer_unbekannt"
    /// The store could not be read or written.
    case storeFailed = "speicher_fehler"
    /// The session could not be started.
    case startFailed = "start_fehlgeschlagen"
}

public enum RBResponse: Codable, Sendable, Equatable {
    case entries([RBEntryLine])
    case entry(RBEntryLine)
    case exported(json: String)
    /// `matches` lists the candidates when the code is `ambiguous`.
    case failed(RBErrorCode, matches: [RBEntryLine])
}

/// Implemented by the engine; RBServer calls it for each accepted request after resolving the caller.
public protocol RBServing: Sendable {
    func handle(_ request: RBRequest, from caller: RBCallerInfo) async -> RBResponse
}

public enum RBSocket {
    public static let fileName = "rb.sock"
    /// Larger requests are refused unread.
    public static let maxMessageBytes = 64 * 1024
    /// Limit for what the CLI reads back; a long list is a normal answer.
    public static let maxResponseBytes = 16 * 1024 * 1024
}

import Foundation

/// What a transport can report about *why* a connection ended — the HTTP
/// status of a rejected handshake, or the close code/reason the server sent.
/// Empty for transports that can't tell (fakes, or a clean local close).
struct ChannelDiagnostics: Sendable, Equatable {
    var httpStatus: Int?
    var closeCode: Int?
    var closeReason: String?
}

/// A coarse, user-meaningful reason a Live connection died. Deliberately
/// small: the app only needs to know whether retrying can help and what to
/// tell the learner. Nothing here carries the raw server text or URL, so
/// it's safe to show and to log.
enum LiveFailure: Sendable, Equatable {
    /// The key was rejected (bad, revoked, or its project lacks access).
    case invalidKey
    /// Rate limit or quota exhausted.
    case quotaExceeded
    /// The device couldn't reach Google at all.
    case network
    /// Anything else — unknown or a clean server-side close.
    case other

    /// Retrying the same connection can't fix these, so reconnecting just
    /// burns the retry budget (and the learner's wait) for nothing.
    var isTerminal: Bool {
        self == .invalidKey || self == .quotaExceeded
    }

    var message: String {
        switch self {
        case .invalidKey:
            return "Google rejected your API key. Check or replace it, then try again."
        case .quotaExceeded:
            return "You've reached your Gemini usage limit. Wait a little and try again, or check your plan in Google AI Studio."
        case .network:
            return "Couldn't reach Google. Check your internet connection and try again."
        case .other:
            return "The connection to the tutor ended. Try again."
        }
    }

    static func classify(error: Error?, diagnostics: ChannelDiagnostics) -> LiveFailure {
        switch diagnostics.httpStatus {
        case 429?:
            return .quotaExceeded
        case 400?, 401?, 403?:
            // A well-formed handshake rejected outright is, in practice, the
            // key (or its project) — Google answers a bad key with 400.
            return .invalidKey
        default:
            break
        }

        if let reason = diagnostics.closeReason?.lowercased() {
            let quotaHints = ["quota", "resource_exhausted", "resource exhausted", "rate limit"]
            if quotaHints.contains(where: reason.contains) { return .quotaExceeded }
            let keyHints = ["api key", "api_key", "unauthenticated", "permission", "not valid"]
            if keyHints.contains(where: reason.contains) { return .invalidKey }
        }
        // 1008 = policy violation, which is how auth/permission failures
        // arrive once a socket is already open.
        if diagnostics.closeCode == 1008 { return .invalidKey }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                return .network
            default:
                break
            }
        }
        return .other
    }
}

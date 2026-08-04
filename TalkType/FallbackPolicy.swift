import Foundation

/// Why the cloud engine did not produce text. Derived from the HTTP status, a timeout,
/// or reachability; drives both the fallback decision and the user-facing message.
enum CloudFailure: Equatable {
    case offline
    case invalidKey
    case limitOrRate
    case timeout
    case serviceError
    case unknown
}

/// What a dictation should do next, decided from facts the app already has — no I/O.
enum EnginePlan: Equatable {
    case cloud(timeout: TimeInterval)
    case local(reason: String)
    case blocked(message: String)
}

/// Cloud-first with automatic local fallback.
///
/// Pure decision logic so every branch is unit-testable: the caller supplies
/// reachability and the classified cloud failure; this returns the plan.
struct FallbackPolicy {

    /// The cloud request gets a short deadline only when the local engine can catch the
    /// fallback. Without local, keep the generous timeout and report the failure instead.
    static let cloudTimeoutWithLocal: TimeInterval = 10
    static let cloudTimeoutWithoutLocal: TimeInterval = 60

    let localInstalled: Bool

    /// Decide before trying the cloud: when offline there is no point attempting it.
    func plan(offline: Bool) -> EnginePlan {
        guard offline else {
            return .cloud(timeout: localInstalled
                ? Self.cloudTimeoutWithLocal
                : Self.cloudTimeoutWithoutLocal)
        }
        if localInstalled {
            return .local(reason: "没网，已用本地引擎。")
        }
        return .blocked(message: "没有网络，也没装本地引擎。联网，或在设置里安装本地引擎。")
    }

    /// Decide after a classified cloud failure. The rule: as long as the local engine
    /// is installed, any cloud failure keeps the dictation working.
    func fallbackPlan(failure: CloudFailure) -> EnginePlan {
        if localInstalled {
            switch failure {
            case .invalidKey:
                return .local(reason: "云端 key 无效或额度用完，已用本地。去设置换 key。")
            case .limitOrRate:
                return .local(reason: "云端额度用完或请求太频繁，已用本地。")
            case .offline, .timeout, .serviceError, .unknown:
                return .local(reason: "云端暂时不可用，已用本地。")
            }
        }
        switch failure {
        case .invalidKey:
            return .blocked(message: "云端 key 无效或额度用完。去设置里更换 OpenRouter key。")
        case .limitOrRate:
            return .blocked(message: "云端额度用完或请求太频繁。去 OpenRouter 查看额度。")
        case .offline, .timeout, .serviceError, .unknown:
            return .blocked(message: "云端暂时不可用。检查网络后重试，或到设置里安装本地引擎。")
        }
    }
}

/// An error whose message is already user-ready; the dictation flow shows it verbatim
/// instead of wrapping it in a generic "Transcription failed" line.
struct UserFacingError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

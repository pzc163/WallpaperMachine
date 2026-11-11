import Foundation

/// Latches cancellation even if it arrives before the task's handler is installed.
final class LLMCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: LLMFailure?
    private var handler: (@Sendable () -> Void)?
    func install(_ handler: @escaping @Sendable () -> Void) {
        let cancelled = lock.withLock { self.handler = handler; return reason != nil }
        if cancelled { handler() }
    }
    func clear() { lock.withLock { handler = nil } }
    func cancel(_ failure: LLMFailure = .cancelled) {
        let callback = lock.withLock { if reason == nil { reason = failure }; return handler }
        callback?()
    }
    var failure: LLMFailure? { lock.withLock { reason } }
    func check() throws {
        if let failure { throw failure }
        if Task.isCancelled { throw LLMFailure.cancelled }
    }
}

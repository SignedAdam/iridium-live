import Foundation

/// The AudioGuard target's `@try/@catch` shim. Declared by symbol instead of imported so that
/// nothing outside MeetingKit needs the shim's module map to link against the static library.
@_silgen_name("IridiumRunCatchingNSException")
private func runCatchingNSException(_ block: @convention(block) () -> Void,
                                    _ reason: UnsafeMutablePointer<CChar>,
                                    _ capacity: Int) -> Bool

/// Runs `body`, turning an Objective-C exception into a retriable `AudioError`.
///
/// AVAudioEngine raises for a stale tap format, a device that vanished mid-call or an input
/// with no channels. Those exceptions are uncatchable in Swift and abort the process, which is
/// how a meeting recording once took the app down.
func guardingAudioExceptions(_ what: String, _ body: () throws -> Void) throws {
    let capacity = 512
    let reason = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    defer { reason.deallocate() }
    reason[0] = 0

    var thrown: Error?
    let finished = runCatchingNSException({
        do { try body() } catch { thrown = error }
    }, reason, capacity)

    if let thrown { throw thrown }
    guard finished else {
        let detail = String(cString: reason)
        throw AudioError(detail.isEmpty ? "\(what) failed." : "\(what) failed: \(detail)", retriable: true)
    }
}

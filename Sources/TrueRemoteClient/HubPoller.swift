import Foundation

public struct HubUpdate: Sendable, Equatable {
    public var snapshot: HubSnapshot
    /// True when a row newly needs you since the previous snapshot (never on the first snapshot).
    public var needsYouRose: Bool
}

/// Polls GET /api/hub. Failures back off 2s -> 30s (doubling) and the stream keeps trying; a 401 ends it,
/// because the token store has already been cleared and polling on would only spam the Mac.
public final class HubPoller: Sendable {
    public static let minBackoff: Duration = .seconds(2)
    public static let maxBackoff: Duration = .seconds(30)

    private let session: RemoteSession
    private let interval: Duration

    public init(session: RemoteSession, interval: Duration = .seconds(5)) {
        self.session = session; self.interval = interval
    }

    /// Rose = some row is "needs you" now that was not "needs you" in the previous snapshot. Ids, not counts:
    /// one seat resolving while another starts asking is still a new ask.
    public static func needsYouRose(from old: HubSnapshot?, to new: HubSnapshot) -> Bool {
        guard let old else { return false }
        return !new.needsYouIDs.subtracting(old.needsYouIDs).isEmpty
    }

    public static func nextBackoff(after current: Duration?) -> Duration {
        guard let current else { return minBackoff }
        return min(current * 2, maxBackoff)
    }

    public func updates() -> AsyncStream<HubUpdate> {
        let (stream, cont) = AsyncStream.makeStream(of: HubUpdate.self)
        let session = session, interval = interval
        let task = Task {
            var last: HubSnapshot?
            var backoff: Duration?
            while !Task.isCancelled {
                do {
                    let snap = try await session.hub()
                    cont.yield(HubUpdate(snapshot: snap, needsYouRose: Self.needsYouRose(from: last, to: snap)))
                    last = snap; backoff = nil
                    try await Task.sleep(for: interval)
                } catch RemoteError.unauthorized {
                    break
                } catch is CancellationError {
                    break
                } catch {
                    backoff = Self.nextBackoff(after: backoff)
                    try? await Task.sleep(for: backoff ?? Self.minBackoff)
                }
            }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }
}

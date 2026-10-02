import Foundation

/// App-owned tasks outlive their editor. Completion runs before an idle waiter
/// is resumed, so a completion that starts follow-up work cannot create a false
/// idle interval during application termination.
@MainActor
final class MediaExportCoordinator {
    static let shared = MediaExportCoordinator()

    private var jobs: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var hasActiveJobs: Bool { !jobs.isEmpty }
    var activeCount: Int { jobs.count }

    func start(operation: @escaping @MainActor () async throws -> Void,
               completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let id = UUID()
        jobs.insert(id)
        Task {
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            completion(result)
            jobs.remove(id)
            if jobs.isEmpty {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    func waitUntilIdle() async {
        guard !jobs.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}

/// Runs blocking file I/O on a worker queue and awaits its completion, so the
/// directory lease outlives the write.
enum MediaExportIO {
    nonisolated static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

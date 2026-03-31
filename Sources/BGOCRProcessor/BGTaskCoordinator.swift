import Foundation
import os
import BackgroundTasks

public final class BGTaskCoordinator: Sendable {

    public static let taskIdentifier = "com.bgocrprocessor.processing"

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "BGTaskCoordinator")

    public init() {}

    public func register(processor: OCRProcessor, queue: PersistentQueue) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Self.logger.debug("BGProcessingTask handler invoked")

            Task {
                // Schedule next BGTask eagerly before processing starts.
                // If the app gets killed mid-processing, the next task is already queued.
                try? self.scheduleIfNeeded()

                let shouldReschedule = await Self.handleBackgroundLaunch(
                    processor: processor,
                    queue: queue
                )

                if !shouldReschedule {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
                    Self.logger.debug("No pending items, cancelled next BGTask")
                }

                processingTask.expirationHandler = {
                    Task {
                        await processor.pauseProcessing()
                    }
                }

                processingTask.setTaskCompleted(success: true)
                Self.logger.debug("BGProcessingTask completed")
            }
        }
    }

    /// Core background launch logic, extracted for testability.
    /// Returns true if there are still pending items (caller should reschedule).
    public static func handleBackgroundLaunch(
        processor: OCRProcessor,
        queue: PersistentQueue
    ) async -> Bool {
        let resetCount = try? await queue.resetStaleProcessing()
        if let resetCount, resetCount > 0 {
            logger.debug("Reset \(resetCount) stale items on BGTask start")
        }

        await processor.appStateObserver.overrideState(.backgroundTask)
        await processor.resumeProcessing()

        for await state in await processor.stateStream {
            if case .idle = state { break }
            if case .paused = state { break }
        }

        let pending = (try? await processor.pendingItemCount()) ?? 0
        return pending > 0
    }

    public func scheduleIfNeeded() throws {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false

        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.debug("BGProcessingTask scheduled")
        } catch let error as BGTaskScheduler.Error where error.code == .unavailable {
            Self.logger.debug("BGTask scheduling unavailable (simulator)")
        } catch {
            throw error
        }
    }
}

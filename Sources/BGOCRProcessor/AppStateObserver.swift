import Foundation
import os
import UIKit

public enum AppState: Sendable {
    case foreground
    case background
    case backgroundTask
}

public actor AppStateObserver {

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "AppStateObserver")

    public private(set) var currentState: AppState = .foreground

    private var continuation: AsyncStream<AppState>.Continuation?
    private var observingTask: Task<Void, Never>?

    public lazy var stateChanges: AsyncStream<AppState> = {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearContinuation()
                }
            }
        }
    }()

    public init() {}

    public func startObserving() {
        guard observingTask == nil else { return }

        observingTask = Task { [weak self] in
            await self?.observeNotifications()
        }
    }

    public func stopObserving() {
        observingTask?.cancel()
        observingTask = nil
        continuation?.finish()
        continuation = nil
    }

    public func overrideState(_ state: AppState) {
        currentState = state
        continuation?.yield(state)
        Self.logger.debug("State overridden to \(String(describing: state))")
    }

    private func clearContinuation() {
        continuation = nil
    }

    private func observeNotifications() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                let center = NotificationCenter.default
                for await _ in center.notifications(named: UIApplication.didBecomeActiveNotification) {
                    await self?.setState(.foreground)
                }
            }

            group.addTask { [weak self] in
                let center = NotificationCenter.default
                for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                    await self?.setState(.background)
                }
            }
        }
    }

    private func setState(_ state: AppState) {
        currentState = state
        continuation?.yield(state)
        Self.logger.debug("State changed to \(String(describing: state))")
    }
}

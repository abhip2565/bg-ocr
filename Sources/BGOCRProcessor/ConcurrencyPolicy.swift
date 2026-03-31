import Foundation

public struct ConcurrencyPolicy: Sendable {

    public static func limit(for state: AppState) -> Int {
        switch state {
        case .foreground:
            return min(ProcessInfo.processInfo.activeProcessorCount, 4)
        case .background, .backgroundTask:
            return 1
        }
    }

    public static func maxImageDimension(for state: AppState) -> Int {
        switch state {
        case .foreground:
            return 4096
        case .background, .backgroundTask:
            return 2048
        }
    }
}

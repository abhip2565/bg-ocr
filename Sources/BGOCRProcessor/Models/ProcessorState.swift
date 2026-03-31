public enum ProcessorState: Sendable {
    case idle
    case processing(completed: Int, total: Int)
    case paused(completed: Int, total: Int)
}

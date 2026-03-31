public enum OCRError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptImage(String)
    case ocrFailed(String)
    case diskSpaceLow
    case memoryPressure
    case maxRetriesExceeded(String)
}

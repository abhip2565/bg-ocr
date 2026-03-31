import XCTest
import CoreGraphics
import ImageIO
@testable import BGOCRProcessor

final class ImagePipelineTests: XCTestCase {

    private let pipeline = ImagePipeline()
    private var tempDir: String!

    override func setUp() {
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ImagePipelineTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testMissingFileThrowsFileNotFound() {
        XCTAssertThrowsError(try pipeline.prepare(at: "/nonexistent/file.jpg")) { error in
            guard case OCRError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    func testCorruptFileDataThrowsError() throws {
        let path = (tempDir as NSString).appendingPathComponent("corrupt.jpg")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try pipeline.prepare(at: path)) { error in
            let isExpected = error is OCRError
            XCTAssertTrue(isExpected, "Expected OCRError, got \(error)")
        }
    }

    func testValidPNGImageReturnsValidCGImage() throws {
        let path = try createTestImage(width: 100, height: 100, format: "public.png" as CFString)
        let result = try pipeline.prepare(at: path)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }

    func testValidJPEGImageReturnsValidCGImage() throws {
        let path = try createTestImage(width: 100, height: 100, format: "public.jpeg" as CFString)
        let result = try pipeline.prepare(at: path)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
    }

    func testOversizedImageIsDownscaled() throws {
        let path = try createTestImage(width: 5000, height: 3000, format: "public.png" as CFString)
        let result = try pipeline.prepare(at: path, maxDimension: 2048)

        let longestEdge = max(result.width, result.height)
        XCTAssertLessThanOrEqual(longestEdge, 2048)
        XCTAssertGreaterThan(longestEdge, 0)
    }

    func testImageWithinMaxDimensionNotResized() throws {
        let path = try createTestImage(width: 1000, height: 800, format: "public.png" as CFString)
        let result = try pipeline.prepare(at: path, maxDimension: 4096)
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 800)
    }

    func testOutputIsValidCGImage() throws {
        let path = try createTestImage(width: 200, height: 300, format: "public.png" as CFString)
        let result = try pipeline.prepare(at: path)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
    }

    private func createTestImage(width: Int, height: Int, format: CFString) throws -> String {
        let ext = format == "public.png" as CFString ? "png" : "jpg"
        let path = (tempDir as NSString).appendingPathComponent("\(UUID().uuidString).\(ext)")
        let url = URL(fileURLWithPath: path)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create context"])
        }

        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to make image"])
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format, 1, nil) else {
            throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Test", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize"])
        }

        return path
    }
}

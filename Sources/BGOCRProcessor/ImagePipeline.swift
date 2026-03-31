import Foundation
import CoreGraphics
import ImageIO

public struct ImagePipeline: Sendable {

    public init() {}

    public func prepare(at path: String, maxDimension: Int = 4096) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: path) else {
            throw OCRError.fileNotFound(path)
        }

        let url = URL(fileURLWithPath: path)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OCRError.unsupportedFormat(path)
        }

        guard let originalImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw OCRError.corruptImage(path)
        }

        let orientation = readEXIFOrientation(from: imageSource)
        let oriented = applyOrientation(to: originalImage, orientation: orientation)
        let resized = resize(image: oriented, maxDimension: maxDimension)

        return resized
    }

    private func readEXIFOrientation(from source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int else {
            return 1
        }
        return orientation
    }

    private func applyOrientation(to image: CGImage, orientation: Int) -> CGImage {
        guard orientation != 1 else { return image }

        let width = image.width
        let height = image.height

        var transform = CGAffineTransform.identity
        var outputWidth = width
        var outputHeight = height

        switch orientation {
        case 2:
            transform = CGAffineTransform(translationX: CGFloat(width), y: 0)
                .scaledBy(x: -1, y: 1)
        case 3:
            transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height))
                .rotated(by: .pi)
        case 4:
            transform = CGAffineTransform(translationX: 0, y: CGFloat(height))
                .scaledBy(x: 1, y: -1)
        case 5:
            outputWidth = height
            outputHeight = width
            transform = CGAffineTransform(translationX: 0, y: 0)
                .scaledBy(x: -1, y: 1)
                .rotated(by: .pi / 2)
        case 6:
            outputWidth = height
            outputHeight = width
            transform = CGAffineTransform(translationX: CGFloat(height), y: 0)
                .rotated(by: .pi / 2)
        case 7:
            outputWidth = height
            outputHeight = width
            transform = CGAffineTransform(translationX: CGFloat(height), y: CGFloat(width))
                .scaledBy(x: -1, y: 1)
                .rotated(by: -.pi / 2)
        case 8:
            outputWidth = height
            outputHeight = width
            transform = CGAffineTransform(translationX: 0, y: CGFloat(width))
                .rotated(by: -.pi / 2)
        default:
            return image
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage() ?? image
    }

    private func resize(image: CGImage, maxDimension: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longestEdge = max(width, height)

        guard longestEdge > maxDimension else { return image }

        let scale = CGFloat(maxDimension) / CGFloat(longestEdge)
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        return context.makeImage() ?? image
    }
}

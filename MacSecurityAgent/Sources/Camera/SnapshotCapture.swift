#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Encodes a camera frame as JPEG for the Telegram snapshot.
///
/// `CIContext` is thread-safe; the instance is shared by the camera queue.
public final class SnapshotCapture: @unchecked Sendable {
    private let context: CIContext
    private let colorSpace: CGColorSpace
    public let quality: Double

    public init(quality: Double = 0.8) {
        self.context = CIContext(options: [.cacheIntermediates: false])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.quality = quality
    }

    public func jpegData(from pixelBuffer: CVPixelBuffer, maxWidth: Int? = nil) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if let maxWidth, image.extent.width > CGFloat(maxWidth), image.extent.width > 0 {
            let scale = CGFloat(maxWidth) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [qualityKey: quality])
    }
}
#endif

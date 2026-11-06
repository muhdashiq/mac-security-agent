#if canImport(CoreVideo) && canImport(Accelerate)
import Accelerate
import CoreVideo
import Foundation

/// Converts camera pixel buffers into downscaled grayscale frames for motion
/// analysis.
public enum PixelBufferConverter {
    public static func grayscaleFrame(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> GrayscaleFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return scaleLumaPlane(of: pixelBuffer, width: width, height: height)
        case kCVPixelFormatType_32BGRA:
            return sampleBGRA(pixelBuffer, width: width, height: height)
        default:
            return nil
        }
    }

    /// The Y plane of a bi-planar YUV buffer *is* the grayscale image; vImage
    /// scales it with SIMD on the CPU.
    private static func scaleLumaPlane(of pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> GrayscaleFrame? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        )
        var pixels = [UInt8](repeating: 0, count: width * height)
        let status = pixels.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(
                data: raw.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            return vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { return nil }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }

    private static func sampleBGRA(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> GrayscaleFrame? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = y * sourceHeight / height
            for x in 0..<width {
                let sourceX = x * sourceWidth / width
                let pixel = bytes + sourceY * rowBytes + sourceX * 4
                // BT.601 luma: 0.299 R + 0.587 G + 0.114 B (fixed point).
                let luma = (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
                pixels[y * width + x] = UInt8(min(luma, 255))
            }
        }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }
}
#endif

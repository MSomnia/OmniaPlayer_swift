import CoreImage
import Foundation

public struct DominantColor {
    public init() {}

    public static func extract(from imageData: Data) async -> (Int, Int, Int)? {
        await Task.detached(priority: .utility) {
            guard let ciImage = CIImage(data: imageData) else {
                return nil
            }

            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
            ]) else {
                return nil
            }

            guard let outputImage = filter.outputImage else {
                return nil
            }

            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            context.render(
                outputImage,
                toBitmap: &bitmap,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )

            return (Int(bitmap[0]), Int(bitmap[1]), Int(bitmap[2]))
        }.value
    }
}

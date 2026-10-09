import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeGenerator {
    static func image(from string: String, dimension: CGFloat, correctionLevel: String = "M") -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        let scale = max(1, dimension / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
    }
}

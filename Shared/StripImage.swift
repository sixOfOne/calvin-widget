import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

enum StripImage {
    /// WidgetKit archives timeline entries, so the strip is resized and saved as JPEG.
    /// Daily strips are about 900×285; Sunday strips are closer to 900×630. A cap of
    /// 1400px on the long side covers a large macOS widget without keeping multi-megabyte files.
    static func jpegData(from data: Data) -> Data? {
        let attempts: [(Int, Double)] = [(1400, 0.82), (1100, 0.74), (800, 0.66)]
        var last: Data?
        for (maxPixel, quality) in attempts {
            guard let jpeg = encode(data, maxPixel: maxPixel, quality: quality) else { continue }
            last = jpeg
            if jpeg.count <= 550_000 {
                return jpeg
            }
        }
        return last
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encode(_ data: Data, maxPixel: Int, quality: Double) -> Data? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

struct StripImageView: View {
    let data: Data

    var body: some View {
        if let image = StripImage.cgImage(from: data) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityLabel("Calvin and Hobbes comic strip")
        }
    }
}

enum StripStyle {
    static let desk = Color(red: 0.945, green: 0.910, blue: 0.855)
    static let paper = Color(red: 0.980, green: 0.965, blue: 0.935)
    static let ink = Color(red: 0.110, green: 0.098, blue: 0.082)
    static let caption = Color(red: 0.769, green: 0.333, blue: 0.165)
}

import CoreGraphics
import Foundation
import ImageIO

/// Local image measurements used to predict the relay's descriptor.
enum ImagePrediction {
    struct ColorFactor {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// `widthxheight`, read from the same scrubbed bytes that will be uploaded.
    static func dimensions(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0
        else { return nil }
        return "\(width.intValue)x\(height.intValue)"
    }

    /// A compact 4x3 BlurHash made from a small decode of the scrubbed bytes.
    ///
    /// The relay makes its own hash from its own resized JPEG, so the two values
    /// are intentionally not byte-identical. Both describe the same picture.
    static func blurHash(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return encode(pixels: pixels, width: width, height: height)
    }

    private static func encode(pixels: [UInt8], width: Int, height: Int) -> String {
        let componentCountX = 4
        let componentCountY = 3
        var factors: [ColorFactor] = []

        for componentY in 0 ..< componentCountY {
            for componentX in 0 ..< componentCountX {
                let normalization = componentX == 0 && componentY == 0 ? 1.0 : 2.0
                var red = 0.0
                var green = 0.0
                var blue = 0.0
                for pixelY in 0 ..< height {
                    for pixelX in 0 ..< width {
                        let basis = normalization
                            * cos(.pi * Double(componentX * pixelX) / Double(width))
                            * cos(.pi * Double(componentY * pixelY) / Double(height))
                        let offset = 4 * (pixelX + pixelY * width)
                        red += basis * linear(Double(pixels[offset]) / 255)
                        green += basis * linear(Double(pixels[offset + 1]) / 255)
                        blue += basis * linear(Double(pixels[offset + 2]) / 255)
                    }
                }
                let scale = 1 / Double(width * height)
                factors.append(ColorFactor(red: red * scale, green: green * scale, blue: blue * scale))
            }
        }

        let maximum = factors.dropFirst().reduce(0.0) { current, factor in
            max(current, max(abs(factor.red), max(abs(factor.green), abs(factor.blue))))
        }
        let quantizedMaximum = Int(max(0, min(82, floor(maximum * 166 - 0.5))))
        let actualMaximum = Double(quantizedMaximum + 1) / 166
        let sizeFlag = componentCountX - 1 + (componentCountY - 1) * 9

        var result = encode83(sizeFlag, length: 1)
        result += encode83(quantizedMaximum, length: 1)
        result += encode83(encodeDC(factors[0]), length: 4)
        for factor in factors.dropFirst() {
            result += encode83(encodeAC(factor, maximum: actualMaximum), length: 2)
        }
        return result
    }

    private static func encodeDC(_ value: ColorFactor) -> Int {
        let red = sRGB(value.red)
        let green = sRGB(value.green)
        let blue = sRGB(value.blue)
        return (red << 16) + (green << 8) + blue
    }

    private static func encodeAC(_ value: ColorFactor, maximum: Double) -> Int {
        func quantize(_ component: Double) -> Int {
            Int(max(0, min(18, floor(signPow(component / maximum, 0.5) * 9 + 9.5))))
        }
        return quantize(value.red) * 19 * 19 + quantize(value.green) * 19 + quantize(value.blue)
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func sRGB(_ value: Double) -> Int {
        let converted = value <= 0.003_130_8
            ? value * 12.92
            : 1.055 * pow(value, 1 / 2.4) - 0.055
        return Int(max(0, min(255, converted * 255 + 0.5)))
    }

    private static func signPow(_ value: Double, _ exponent: Double) -> Double {
        copysign(pow(abs(value), exponent), value)
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var result = ""
        for index in 1 ... length {
            let divisor = Int(pow(83.0, Double(length - index)))
            result.append(alphabet[value / divisor % 83])
        }
        return result
    }
}

public extension BlobDescriptor {
    /// The descriptor the relay is expected to return for these exact image bytes.
    ///
    /// The four format-to-extension cases mirror `buzz-media`'s `mime_to_ext`.
    /// The URL is rooted at the relay origin because the server publishes media
    /// at `{scheme}://{tenant_host}/media`, independent of its upload fallback.
    static func predicted(
        data: Data,
        baseURL: URL,
        filename: String? = nil
    ) -> BlobDescriptor? {
        guard let format = ImageByteFormat.detect(data),
              let mapping = predictedTypeAndExtension(for: format),
              let dimensions = ImagePrediction.dimensions(of: data),
              let blurhash = ImagePrediction.blurHash(of: data),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else { return nil }

        let digest = MediaUploadClient.sha256Hex(data)
        components.user = nil
        components.password = nil
        components.path = "/media/\(digest).\(mapping.extension)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url?.absoluteString else { return nil }
        components.path = "/media/\(digest).thumb.jpg"
        guard let thumb = components.url?.absoluteString else { return nil }

        return BlobDescriptor(
            url: url,
            sha256: digest,
            size: data.count,
            type: mapping.mimeType,
            uploaded: 0,
            dim: dimensions,
            blurhash: blurhash,
            thumb: thumb,
            filename: filename
        )
    }

    internal static func predictedTypeAndExtension(
        for format: ImageByteFormat
    ) -> (mimeType: String, extension: String)? {
        switch format {
        case .jpeg: ("image/jpeg", "jpg")
        case .png: ("image/png", "png")
        case .gif: ("image/gif", "gif")
        case .webp: ("image/webp", "webp")
        case .heic: nil
        }
    }
}

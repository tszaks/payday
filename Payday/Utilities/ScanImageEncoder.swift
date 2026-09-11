import UIKit

/// Produces bounded scan uploads. Pixel limits protect model accuracy and
/// memory; the byte ceiling protects radio time, base64 allocation, and API
/// cost for visually noisy photos that compress poorly.
enum ScanImageEncoder {
    static func jpegData(
        for image: UIImage,
        maxDimension: CGFloat,
        maxBytes: Int,
        initialQuality: CGFloat
    ) -> Data? {
        guard maxDimension > 0, maxBytes > 0 else { return nil }

        var targetDimension = maxDimension
        var quality = min(max(initialQuality, 0.45), 0.95)

        for _ in 0..<24 {
            let longestSide = max(image.size.width, image.size.height)
            let scale = min(1, targetDimension / max(longestSide, 1))
            let size = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let data = renderer.jpegData(withCompressionQuality: quality) { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if data.count <= maxBytes { return data }

            if quality > 0.55 {
                quality -= 0.10
            } else {
                targetDimension *= 0.82
                quality = min(initialQuality, 0.80)
            }
        }

        return nil
    }
}

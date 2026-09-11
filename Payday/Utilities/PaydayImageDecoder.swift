import Foundation
import ImageIO
import UIKit

/// Keeps photo-library and camera image inflation away from SwiftUI's main
/// actor. Large HEIC/JPEG imports can otherwise steal several display frames
/// before the scan task even begins.
enum PaydayImageDecoder {
    static func decode(_ data: Data, maxPixelSize: Int = 3_200) async -> UIImage? {
        let worker = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled else { return nil }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      0,
                      [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceShouldCacheImmediately: true,
                          kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
                      ] as CFDictionary
                  )
            else { return nil }
            guard !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

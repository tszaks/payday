import UIKit
import XCTest
@testable import Payday

final class ScanImageEncoderTests: XCTestCase {
    func testEncodedImageNeverExceedsByteCeiling() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 1_800))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_800))
            UIColor.black.setFill()
            for y in stride(from: 0, to: 1_800, by: 16) {
                context.fill(CGRect(x: 0, y: y, width: 1_200, height: 8))
            }
        }

        let data = try XCTUnwrap(ScanImageEncoder.jpegData(
            for: image,
            maxDimension: 1_800,
            maxBytes: 150_000,
            initialQuality: 0.90
        ))

        XCTAssertLessThanOrEqual(data.count, 150_000)
    }

    func testImpossibleCeilingFailsClosed() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        XCTAssertNil(ScanImageEncoder.jpegData(
            for: image,
            maxDimension: 32,
            maxBytes: 1,
            initialQuality: 0.80
        ))
    }

    func testImportDecoderDownsamplesBeforeUIImageInflation() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2_048, height: 1_024)).image {
            UIColor.systemGreen.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_024))
        }
        let sourceData = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let decodedImage = await PaydayImageDecoder.decode(sourceData, maxPixelSize: 512)
        let decoded = try XCTUnwrap(decodedImage)

        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 512)
    }
}

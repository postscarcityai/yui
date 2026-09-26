import UIKit
import XCTest
@testable import Yui

/// YUI-100: pictures decode at the size they are drawn, never bigger than sent.
final class PicturesTests: XCTestCase {
    private func jpeg(_ w: Int, _ h: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.jpegData(compressionQuality: 0.8)!
    }

    private func pixels(_ image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    func testABigPictureDecodesAtTheTileSize() throws {
        // 4000 x 3000 sent, drawn in a 200 pt square at 3x: 600 px tall is enough to fill it.
        let made = try XCTUnwrap(Pictures.downsampled(jpeg(4000, 3000), points: CGSize(width: 200, height: 200), scale: 3))
        let px = pixels(made.image)
        XCTAssertEqual(px.height, 600, accuracy: 2)
        XCTAssertEqual(px.width, 800, accuracy: 2)
        XCTAssertFalse(made.whole)
        XCTAssertTrue(Pictures.sharp(made.image, CGSize(width: 200, height: 200), scale: 3, fill: true))
        XCTAssertFalse(Pictures.sharp(made.image, CGSize(width: 400, height: 400), scale: 3, fill: true))
        // A tenth of the bytes the whole picture would take.
        XCTAssertLessThan(Pictures.cost(made.image), 4000 * 3000 * 4 / 10)
    }

    func testASmallPictureIsNeverMadeBigger() throws {
        let made = try XCTUnwrap(Pictures.downsampled(jpeg(300, 200), points: CGSize(width: 400, height: 400), scale: 3))
        XCTAssertEqual(pixels(made.image).width, 300, accuracy: 1)
        XCTAssertTrue(made.whole, "the whole picture: a bigger frame has nothing more to decode")
    }

    func testFitNeedsOneSideFillNeedsBoth() {
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300),
                                           format: { let f = UIGraphicsImageRendererFormat.default(); f.scale = 1; return f }())
            .image { _ in }
        let frame = CGSize(width: 200, height: 200)
        XCTAssertTrue(Pictures.sharp(wide, frame, scale: 3, fill: false))
        XCTAssertFalse(Pictures.sharp(wide, frame, scale: 3, fill: true))
    }

    func testSimilarSizesShareACacheEntry() {
        XCTAssertEqual(Pictures.key("a", 590), Pictures.key("a", 600))
        XCTAssertNotEqual(Pictures.key("a", 600), Pictures.key("a", 900))
        XCTAssertNotEqual(Pictures.key("a", 600), Pictures.key("b", 600))
    }
}

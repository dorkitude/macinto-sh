import CoreGraphics
import XCTest
@testable import MacintoGeometry

final class CaptureGeometryTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testSingleWindowGetsMargin() {
        let r = CaptureGeometry.cropRect(windows: [CGRect(x: 100, y: 200, width: 400, height: 300)], display: main)
        XCTAssertEqual(r, CGRect(x: 92, y: 192, width: 416, height: 316))
    }

    func testUnionOfWindows() {
        let r = CaptureGeometry.cropRect(windows: [CGRect(x: 100, y: 100, width: 100, height: 100),
                                                   CGRect(x: 500, y: 400, width: 200, height: 50)],
                                         display: main, margin: 0)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 600, height: 350))
    }

    func testClampedToDisplay() {
        // Window hangs off the top-left and the right edge; margin can't leave the display.
        let r = CaptureGeometry.cropRect(windows: [CGRect(x: -50, y: 2, width: 1700, height: 300)], display: main)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1512, height: 310))
    }

    func testWindowsOffTheDisplayAreIgnored() {
        let other = CGRect(x: 1600, y: 0, width: 300, height: 300)  // on a display to the right
        let here = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(CaptureGeometry.cropRect(windows: [other, here], display: main, margin: 0), here)
        XCTAssertNil(CaptureGeometry.cropRect(windows: [other], display: main))
        XCTAssertNil(CaptureGeometry.cropRect(windows: [], display: main))
        XCTAssertNil(CaptureGeometry.cropRect(windows: [CGRect(x: 10, y: 10, width: 0, height: 50)], display: main))
    }

    func testSecondaryDisplayWithNegativeOrigin() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let r = CaptureGeometry.cropRect(windows: [CGRect(x: -1915, y: -100, width: 500, height: 400)], display: left)
        XCTAssertEqual(r, CGRect(x: -1920, y: -108, width: 513, height: 416))
    }

    func testRoundsOutwardToWholePoints() {
        let r = CaptureGeometry.cropRect(windows: [CGRect(x: 10.4, y: 20.6, width: 100.2, height: 50.1)], display: main, margin: 0)
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 101, height: 51))
    }

    func testScale() {
        XCTAssertEqual(CaptureGeometry.scale(width: 1512, native: false, displayScale: 2, maxWidth: 0), 1)
        XCTAssertEqual(CaptureGeometry.scale(width: 1512, native: true, displayScale: 2, maxWidth: 0), 2)
        // max_width applies to the crop width, not the display width.
        XCTAssertEqual(CaptureGeometry.scale(width: 416, native: false, displayScale: 2, maxWidth: 800), 1)
        XCTAssertEqual(CaptureGeometry.scale(width: 416, native: true, displayScale: 2, maxWidth: 800), 800.0 / 416.0, accuracy: 1e-9)
        XCTAssertEqual(CaptureGeometry.scale(width: 1600, native: false, displayScale: 2, maxWidth: 800), 0.5)
        XCTAssertEqual(CaptureGeometry.pixelSize(CGRect(x: 0, y: 0, width: 1600, height: 1001), scale: 0.5).width, 800)
        XCTAssertEqual(CaptureGeometry.pixelSize(CGRect(x: 0, y: 0, width: 1600, height: 1001), scale: 0.5).height, 501)
    }

    func testClickPointMapping() {
        let p = CaptureGeometry.clickPoint(px: 100, py: 50, origin: CGPoint(x: 92, y: 192), scale: 2)
        XCTAssertEqual(p, CGPoint(x: 142, y: 217))
    }
}

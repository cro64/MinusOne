import AppKit
import XCTest
@testable import MinusOne

final class MinusOneIconTests: XCTestCase {
    /// Samples the image at a point given in points (x from the left, y from the top), as a fraction
    /// of its pixel size so it holds at any backing scale.
    private func color(of image: NSImage, x: CGFloat, yFromTop: CGFloat) throws -> NSColor {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let px = Int(x / image.size.width * CGFloat(rep.pixelsWide))
        let py = Int(yFromTop / image.size.height * CGFloat(rep.pixelsHigh))
        return try XCTUnwrap(rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
    }

    func testTheBadgeIsADotInTheTopRightCorner() throws {
        let icon = MinusOneIcon.waveform(size: 18, color: .black, isActive: false, showsBadge: true)
        XCTAssertGreaterThan(try color(of: icon, x: 15.5, yFromTop: 1.5).alphaComponent, 0.9)
    }

    /// Guards the test above: without the badge nothing is drawn there, so a pass above is the dot.
    func testWithoutTheBadgeTheCornerIsEmpty() throws {
        let icon = MinusOneIcon.waveform(size: 18, color: .black, isActive: false)
        XCTAssertLessThan(try color(of: icon, x: 15.5, yFromTop: 1.5).alphaComponent, 0.05)
    }

    /// The badge follows the icon's state colour (red for an error, coral while Live is on).
    func testTheBadgeTakesTheIconsColour() throws {
        let icon = MinusOneIcon.waveform(size: 18, color: .systemRed, isActive: false, showsBadge: true)
        let pixel = try color(of: icon, x: 15.5, yFromTop: 1.5)
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.45)
    }
}

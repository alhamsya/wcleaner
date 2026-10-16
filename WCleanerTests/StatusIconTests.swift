import AppKit
import XCTest
@testable import WCleaner

@MainActor
final class StatusIconTests: XCTestCase {
    func testStatusIconIsATemplateImageSizedForTheMenuBar() {
        let image = StatusIcon.image()
        XCTAssertTrue(image.isTemplate, "Menu bar icons must be template images to adapt to light/dark menu bars")
        XCTAssertLessThanOrEqual(image.size.height, 22)
        XCTAssertEqual(image.accessibilityDescription, "WCleaner")
    }

    func testAttentionVariantHasDistinctAccessibilityDescription() {
        XCTAssertEqual(StatusIcon.image(.attention).accessibilityDescription, "WCleaner, needs attention")
    }

    func testHostedTestRunDoesNotStartTheApp() {
        XCTAssertTrue(AppEnvironment.isRunningUnitTests)
    }
}

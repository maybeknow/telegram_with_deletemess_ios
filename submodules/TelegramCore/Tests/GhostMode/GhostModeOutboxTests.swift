import XCTest

final class GhostModeOutboxTests: XCTestCase {
    func testTextDelay() {
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: nil), 12)
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 0), 12)
    }

    func testNegativeSizeFallsBackToTextDelay() {
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: -1), 12)
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: Int64.min), 12)
    }

    func testSmallMediaMinimumSixSeconds() {
        // 1 МБ → ceil(4.5) = 5, но минимум 6
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 1 * 1024 * 1024), 6)
    }

    func testMediaScalesWithSize() {
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 10 * 1024 * 1024), 45)
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 100 * 1024 * 1024), 450)
    }

    func testHugeMediaClampsToInt32Max() {
        // Без clamp Int32(Double) трапает на переполнении.
        XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: Int64.max), Int32.max)
    }

    func testScheduleAttributeUsesNowPlusDelay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attribute = GhostModeOutbox.scheduleAttribute(delay: 12, now: now)
        XCTAssertEqual(attribute.scheduleTime, 1_700_000_012)
        XCTAssertNil(attribute.repeatPeriod)
    }
}

import Foundation
@testable import vcompress

/// Mock Clock that returns a fixed, configurable date.
final class MockClock: Clock {

    /// The fixed date to return from now().
    var currentDate: Date

    init(date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentDate = date
    }

    func now() -> Date {
        currentDate
    }

    /// Advance the clock by the given interval.
    func advance(by interval: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(interval)
    }
}

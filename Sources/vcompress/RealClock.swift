import Foundation

/// Production Clock implementation that returns the current system time.
struct RealClock: Clock {
    func now() -> Date {
        Date()
    }
}

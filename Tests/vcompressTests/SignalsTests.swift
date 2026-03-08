import XCTest
@testable import vcompress

final class SignalsTests: XCTestCase {

    // MARK: - test_shutdownCoordinator_initiallyFalse

    func test_shutdownCoordinator_initiallyFalse() {
        let coord = ShutdownCoordinator()
        XCTAssertFalse(coord.isShutdownRequested)
    }

    // MARK: - test_shutdownCoordinator_requestShutdown_setsFlag

    func test_shutdownCoordinator_requestShutdown_setsFlag() {
        let coord = ShutdownCoordinator()
        coord.requestShutdown()
        XCTAssertTrue(coord.isShutdownRequested)
    }

    // MARK: - test_shutdownCoordinator_threadSafe

    func test_shutdownCoordinator_threadSafe() {
        let coord = ShutdownCoordinator()
        let group = DispatchGroup()

        // Dispatch requestShutdown from 100 concurrent tasks.
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                coord.requestShutdown()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Timed out waiting for concurrent tasks")

        // After all concurrent calls, the flag must be true and no crashes occurred.
        XCTAssertTrue(coord.isShutdownRequested)
    }

    // MARK: - test_shutdownCoordinator_multipleRequestsIdempotent

    func test_shutdownCoordinator_multipleRequestsIdempotent() {
        let coord = ShutdownCoordinator()
        coord.requestShutdown()
        coord.requestShutdown()
        coord.requestShutdown()
        XCTAssertTrue(coord.isShutdownRequested)
    }

    // MARK: - test_separateInstances_independent

    func test_separateInstances_independent() {
        let coordA = ShutdownCoordinator()
        let coordB = ShutdownCoordinator()

        coordA.requestShutdown()

        XCTAssertTrue(coordA.isShutdownRequested)
        XCTAssertFalse(coordB.isShutdownRequested, "Separate instances must be independent")
    }
}

import Foundation
import Dispatch

// MARK: - ShutdownCoordinator

/// Thread-safe coordinator for graceful shutdown on SIGINT.
/// Uses os_unfair_lock for low-overhead synchronization.
public final class ShutdownCoordinator: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _isShutdownRequested: Bool = false

    /// Thread-safe read of the shutdown flag.
    public var isShutdownRequested: Bool {
        os_unfair_lock_lock(&_lock)
        let value = _isShutdownRequested
        os_unfair_lock_unlock(&_lock)
        return value
    }

    /// Thread-safe request to initiate shutdown.
    public func requestShutdown() {
        os_unfair_lock_lock(&_lock)
        _isShutdownRequested = true
        os_unfair_lock_unlock(&_lock)
    }

    /// Shared singleton used by the signal handler and orchestrator.
    public static let shared = ShutdownCoordinator()

    public init() {}
}

// MARK: - Signal Handler Installation

/// Retained reference to prevent the dispatch source from being deallocated.
private var _signalSource: DispatchSourceSignal?

/// Installs a SIGINT handler that sets the shutdown flag on the shared coordinator.
///
/// Must be called once at application startup (before the encode loop begins).
/// The default SIGINT handler is ignored first, then a DispatchSource is registered
/// to catch the signal and set `ShutdownCoordinator.shared.isShutdownRequested`.
public func installSignalHandler() {
    // Ignore the default SIGINT handler so the process does not terminate immediately.
    signal(SIGINT, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        ShutdownCoordinator.shared.requestShutdown()
    }
    source.resume()

    // Store the source to prevent deallocation.
    _signalSource = source
}

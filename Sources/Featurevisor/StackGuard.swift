import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Native stack measurement for dependency handoffs.
///
/// Apple platforms give secondary threads, including Dispatch and Swift concurrency
/// workers, 512 KB of stack. A deep dependency chain must fail as an error
/// evaluation before it can overflow that stack and terminate the process.
enum StackGuard {
    /// Room kept free for one more handoff, leaf comparisons and module callbacks.
    /// A release build uses about 14 KB per dependency handoff.
    static let reserve = 64 * 1024

    /// Bytes left below the current frame, or nil where the platform cannot tell.
    static func remaining() -> Int? {
        #if canImport(Darwin)
            let thread = pthread_self()
            let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
            let size = UInt(pthread_get_stacksize_np(thread))
            guard top > size else { return nil }
            var marker: UInt8 = 0
            let current = withUnsafePointer(to: &marker) { UInt(bitPattern: $0) }
            let bottom = top - size
            return current > bottom ? Int(current - bottom) : 0
        #else
            return nil
        #endif
    }

    static var exhausted: Bool {
        guard let remaining = remaining() else { return false }
        return remaining < reserve
    }
}

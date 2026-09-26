// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// A deadline that is actually a deadline.
//
// `withTaskGroup` waits for every child before it returns, and cancelling a task does not stop a
// blocking call inside it (getaddrinfo, a synchronous socket). So "race it against a sleep in a
// task group" returns only when the slow side finishes — a timeout in name only. Here the result
// is delivered through a continuation that the first finisher claims; a late answer is dropped on
// the floor, and the caller moves on at the deadline whatever the operation is doing.

import Foundation

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs `operation` and returns its result, or nil once `seconds` have passed — whichever is first.
public func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    guard seconds > 0 else { return nil }
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once()
        let work = Task {
            let value = await operation()
            if once.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Runs a blocking call on its own thread, so it can be abandoned by `withDeadline` without
/// pinning a cooperative-pool thread. The thread finishes whenever the call does.
public func offThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}

/// A single point in time several steps share, so a pipeline has ONE budget rather than one per
/// step added end to end.
public struct Deadline: Sendable {
    public let at: Date
    public init(_ seconds: TimeInterval) { at = Date().addingTimeInterval(seconds) }
    public var remaining: TimeInterval { max(0, at.timeIntervalSinceNow) }
}

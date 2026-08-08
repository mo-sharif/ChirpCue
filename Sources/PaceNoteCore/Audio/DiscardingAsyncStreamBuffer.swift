import Foundation

/// A single-consumer, bounded stream buffer for sensitive in-memory values.
///
/// Unlike `AsyncStream`'s built-in buffering policies, this buffer can discard
/// and scrub every queued value synchronously when capture stops or its
/// consumer is cancelled.
final class DiscardingAsyncStreamBuffer<Element: Sendable>: @unchecked Sendable {
    typealias Prepare = @Sendable (Element) -> Element
    typealias Discard = @Sendable (inout Element) -> Void

    enum YieldResult: Equatable, Sendable {
        case delivered
        case enqueued
        case droppedOldest
        case terminated
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Never>
    }

    private struct State {
        var values: [Element] = []
        var waiters: [Waiter] = []
        var cancelledWaiterIDs: Set<UUID> = []
        var isFinished = false
        var discardedCount = 0
    }

    private let maximumCount: Int
    private let prepare: Prepare
    private let discard: Discard
    private let lock = NSLock()
    private var state = State()

    init(
        maximumCount: Int,
        prepare: @escaping Prepare = { $0 },
        discard: @escaping Discard
    ) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
        self.prepare = prepare
        self.discard = discard
    }

    deinit {
        finish()
    }

    func stream() -> AsyncStream<Element> {
        AsyncStream(
            unfolding: { [self] in
                return await self.next()
            },
            onCancel: { [weak self] in
                self?.finish()
            }
        )
    }

    @discardableResult
    func yield(_ value: Element) -> YieldResult {
        var prepared = prepare(value)
        var waiter: Waiter?
        var dropped: Element?
        let result: YieldResult

        lock.lock()
        if state.isFinished {
            result = .terminated
        } else if !state.waiters.isEmpty {
            waiter = state.waiters.removeFirst()
            result = .delivered
        } else if state.values.count == maximumCount {
            dropped = state.values.removeFirst()
            state.values.append(prepared)
            state.discardedCount += 1
            result = .droppedOldest
        } else {
            state.values.append(prepared)
            result = .enqueued
        }
        lock.unlock()

        if result == .terminated {
            discard(&prepared)
        }
        if var dropped {
            discard(&dropped)
        }
        waiter?.continuation.resume(returning: prepared)
        return result
    }

    /// Discards queued values, optionally delivers one non-sensitive terminal
    /// value to an active or future consumer, and then ends the stream.
    func finish(delivering terminalValue: Element? = nil) {
        var discarded: [Element] = []
        var waiters: [Waiter] = []
        var terminalWaiter: Waiter?
        var terminal = terminalValue.map(prepare)

        lock.lock()
        guard !state.isFinished else {
            lock.unlock()
            if var terminal { discard(&terminal) }
            return
        }

        state.isFinished = true
        discarded = state.values
        state.values.removeAll(keepingCapacity: false)
        state.discardedCount += discarded.count

        if terminal != nil, !state.waiters.isEmpty {
            terminalWaiter = state.waiters.removeFirst()
        } else if let queuedTerminal = terminal {
            state.values.append(queuedTerminal)
            terminal = nil
        }
        waiters = state.waiters
        state.waiters.removeAll(keepingCapacity: false)
        state.cancelledWaiterIDs.removeAll(keepingCapacity: false)
        lock.unlock()

        for index in discarded.indices { discard(&discarded[index]) }
        terminalWaiter?.continuation.resume(returning: terminal)
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
    }

    func queuedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.values.count
    }

    func discardedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return state.discardedCount
    }

    private func next() async -> Element? {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                var value: Element?
                var shouldResume = false

                lock.lock()
                if state.cancelledWaiterIDs.remove(id) != nil {
                    shouldResume = true
                } else if !state.values.isEmpty {
                    value = state.values.removeFirst()
                    shouldResume = true
                } else if state.isFinished {
                    shouldResume = true
                } else {
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                }
                lock.unlock()

                if shouldResume { continuation.resume(returning: value) }
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        var waiter: Waiter?
        lock.lock()
        if let index = state.waiters.firstIndex(where: { $0.id == id }) {
            waiter = state.waiters.remove(at: index)
        } else if !state.isFinished {
            state.cancelledWaiterIDs.insert(id)
        }
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }
}

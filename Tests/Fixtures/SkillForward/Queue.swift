struct RequestHandler {
    let queue: RetryQueue

    func accept(_ job: Job) async throws -> Accepted {
        try await queue.enqueue(job)
        return Accepted(jobID: job.id)
    }
}

actor RetryWorker {
    func process(_ job: Job) async {
        for attempt in 1...3 {
            if await deliver(job) { return }
            await backoff(attempt)
        }
    }
}

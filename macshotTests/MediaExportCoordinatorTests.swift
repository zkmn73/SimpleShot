import XCTest

@MainActor
final class MediaExportCoordinatorTests: XCTestCase {
    private final class Gate {
        private var open = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    func testIdleIncludesWorkStartedByACompletion() async {
        let coordinator = MediaExportCoordinator()
        let first = Gate(), second = Gate(), third = Gate()
        let firstFinished = expectation(description: "First completion registered follow-up")
        let secondFinished = expectation(description: "Second completion")
        coordinator.start(operation: {
            await first.wait()
        }, completion: { _ in
            coordinator.start(operation: { await third.wait() }, completion: { _ in })
            firstFinished.fulfill()
        })
        coordinator.start(operation: { await second.wait() }, completion: { _ in secondFinished.fulfill() })
        var idle = false
        let waiter = Task { await coordinator.waitUntilIdle(); idle = true }
        XCTAssertEqual(coordinator.activeCount, 2)
        first.release()
        await fulfillment(of: [firstFinished], timeout: 5)
        XCTAssertEqual(coordinator.activeCount, 2)
        XCTAssertFalse(idle)
        second.release()
        await fulfillment(of: [secondFinished], timeout: 5)
        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertFalse(idle)
        third.release()
        await waiter.value
        XCTAssertTrue(idle)
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testQuitKeepsNormalRunLoopAndRetriesOnceAfterJobsAndTheirFollowupDrain() async {
        let exports = MediaExportCoordinator(), termination = ApplicationTerminationCoordinator()
        let first = Gate(), second = Gate()
        let followedUp = expectation(description: "First save starts follow-up")
        let quitRetried = expectation(description: "Quit retried after all work")
        var drainCount = 0, retryCount = 0
        exports.start(operation: { await first.wait() }, completion: { _ in
            exports.start(operation: { await second.wait() }, completion: { _ in })
            followedUp.fulfill()
        })
        for _ in 0..<3 {
            let reply = termination.request(hasActiveWork: exports.hasActiveJobs, drain: {
                drainCount += 1
                await exports.waitUntilIdle()
            }, terminate: {
                XCTAssertFalse(exports.hasActiveJobs)
                XCTAssertFalse(termination.isWaiting)
                retryCount += 1
                quitRetried.fulfill()
            })
            XCTAssertEqual(reply, .terminateCancel, "A modal termination loop stalls MainActor completion")
        }
        first.release()
        await fulfillment(of: [followedUp], timeout: 5)
        XCTAssertTrue(termination.isWaiting)
        XCTAssertEqual(retryCount, 0)
        second.release()
        await fulfillment(of: [quitRetried], timeout: 5)
        XCTAssertEqual(drainCount, 1)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(termination.request(hasActiveWork: false, drain: { XCTFail("Already idle") },
            terminate: { XCTFail("No asynchronous retry needed") }), .terminateNow)
    }
}

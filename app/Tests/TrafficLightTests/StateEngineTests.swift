import XCTest
@testable import TrafficLight
import TrafficLightCore

final class StateEngineTests: XCTestCase {
    func testNewTaskOverridesPendingCompletion() {
        let engine = StateEngine()

        _ = engine.handle(TLRequest(cmd: "start", id: "first", name: "First"))
        _ = engine.handle(TLRequest(cmd: "done", id: "first", result: "success"))
        XCTAssertEqual(engine.displayState, .green)

        _ = engine.handle(TLRequest(cmd: "start", id: "second", name: "Second"))
        XCTAssertEqual(engine.displayState, .orange)
        XCTAssertNil(engine.pendingCompletion)
    }

    func testStateRemainsOrangeUntilLastRunningTaskCompletes() {
        let engine = StateEngine()
        _ = engine.handle(TLRequest(cmd: "start", id: "first", name: "First"))
        _ = engine.handle(TLRequest(cmd: "start", id: "second", name: "Second"))
        _ = engine.handle(TLRequest(cmd: "done", id: "first", result: "success"))
        XCTAssertEqual(engine.displayState, .orange)

        _ = engine.handle(TLRequest(cmd: "done", id: "second", result: "success"))
        XCTAssertEqual(engine.displayState, .green)
    }
}

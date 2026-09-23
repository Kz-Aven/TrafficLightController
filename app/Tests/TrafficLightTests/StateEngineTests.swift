import XCTest
@testable import TrafficLight
import TrafficLightCore

final class StateEngineTests: XCTestCase {
    func testScalePresetsIncludeLargeMultiples() {
        XCTAssertEqual(WidgetController.scalePresets, [0.65, 1.0, 1.6, 3.2, 4.8])
        XCTAssertEqual(WidgetController.maxScale, 4.8)
    }

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

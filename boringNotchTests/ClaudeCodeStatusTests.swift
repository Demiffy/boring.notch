//
//  ClaudeCodeStatusTests.swift
//  boringNotch
//

import XCTest
@testable import boringNotch

final class ClaudeCodeStatusTests: XCTestCase {

    func testBodyWaitsForContentLength() {
        let head = "POST /claude HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\n"
        XCTAssertNil(ClaudeCodeStatusManager.completeBody(in: Data("POST /claude HTTP/1.1\r\n".utf8)))
        XCTAssertNil(ClaudeCodeStatusManager.completeBody(in: Data((head + "{\"a\":").utf8)))
        XCTAssertEqual(ClaudeCodeStatusManager.completeBody(in: Data((head + "{\"a\":\"bc\"}").utf8)), Data("{\"a\":\"bc\"}".utf8))
    }

    func testEventMapping() {
        let state = ClaudeCodeStatusManager.state
        XCTAssertEqual(state("UserPromptSubmit", nil, nil), .working)
        XCTAssertEqual(state("PostToolUse", nil, nil), .working)
        XCTAssertEqual(state("Stop", nil, nil), .done)
        XCTAssertEqual(state("StopFailure", nil, nil), .failed)
        XCTAssertEqual(state("Notification", "permission_prompt", "Claude needs your permission to use Bash"), .waiting)
        XCTAssertNil(state("Notification", "idle_prompt", nil))
        XCTAssertNil(state("Notification", nil, "Claude is waiting for your input"))
        XCTAssertNil(state("SessionEnd", nil, nil))
    }
}

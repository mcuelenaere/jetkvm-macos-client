import XCTest
@testable import JetKVMProtocol

final class JetKVMProtocolTests: XCTestCase {
    func testVersionPresent() {
        XCTAssertFalse(JetKVMProtocol.version.isEmpty)
    }
}

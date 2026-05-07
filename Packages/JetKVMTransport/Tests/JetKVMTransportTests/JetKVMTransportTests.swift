import XCTest
@testable import JetKVMTransport

final class JetKVMTransportTests: XCTestCase {
    func testVersionPresent() {
        XCTAssertFalse(JetKVMTransport.version.isEmpty)
    }
}

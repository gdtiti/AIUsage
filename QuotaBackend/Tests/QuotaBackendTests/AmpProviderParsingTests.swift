import XCTest
@testable import QuotaBackend

final class AmpProviderParsingTests: XCTestCase {

    // Covers the real payload captured from a user whose Amp Free was paused:
    // `freeTierUsage:null` but `credits:{free:{used:0,available:0},paid:{used:0,available:0}}`
    // was present. The provider must now fall through to the credits path instead of
    // throwing "Could not parse Amp usage from settings page."
    func testCreditsFallbackWhenFreeTierIsNull() throws {
        let html = try loadFixture("amp_credits_paused_free_tier.html")
        let provider = AmpProvider()
        let usage = try provider._parseSettingsHTMLForTesting(html)

        XCTAssertEqual(usage.provider, "amp")
        XCTAssertEqual(usage.accountPlan, "Credits")
        XCTAssertEqual(usage.accountEmail?.lowercased(), "redacted@example.com")
        XCTAssertEqual(usage.extra["used"]?.value as? Int, 0)
        XCTAssertEqual(usage.extra["quota"]?.value as? Int, 0)
    }

    // Synthetic payload: simulates a credits account that actually has balance.
    // Verifies used/quota aggregation across free+paid buckets.
    func testCreditsFallbackAggregatesFreeAndPaid() throws {
        let html = """
        <html><body><script>
        var x = {freeTierUsage:null,credits:{free:{used:100,available:50},paid:{used:200,available:300}}};
        </script></body></html>
        """
        let provider = AmpProvider()
        let usage = try provider._parseSettingsHTMLForTesting(html)

        XCTAssertEqual(usage.accountPlan, "Credits")
        XCTAssertEqual(usage.extra["used"]?.value as? Int, 300)
        XCTAssertEqual(usage.extra["quota"]?.value as? Int, 650)
    }

    // The classic free-tier payload shape must still parse and keep accountPlan "Free".
    func testFreeTierPayloadStillParses() throws {
        let html = """
        <html><body><script>
        var data = {freeTierUsage:{quota:1000,used:250,hourlyReplenishment:10.0}};
        </script></body></html>
        """
        let provider = AmpProvider()
        let usage = try provider._parseSettingsHTMLForTesting(html)

        XCTAssertEqual(usage.accountPlan, "Free")
        XCTAssertEqual(usage.extra["quota"]?.value as? Int, 1000)
        XCTAssertEqual(usage.extra["used"]?.value as? Int, 250)
    }

    // MARK: - Helpers

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw XCTSkip("Fixture \(name) not found in Fixtures bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

import XCTest
@testable import simplebanking

// MARK: - CLIRefreshOutcomeMarshaller round-trip + schema tests
//
// Diese Tests sichern die Wire-Stabilität zwischen App-Writer und CLI-Reader
// ab. Wenn das JSON-Schema driftet (Key umbenannt, status enum geändert,
// fehlendes Feld), würde `sb refresh` falsche Status anzeigen, weil der
// CLI-Reader (Sources/simplebanking-cli/DataReader.swift::lastRefreshOutcome)
// das gleiche Schema spiegelt — ohne den App-Code importieren zu können.

final class CLIRefreshOutcomeMarshallerTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundTrip_success_noDetail() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .success, detail: nil, now: now) else {
            return XCTFail("encode returned nil")
        }
        let decoded = CLIRefreshOutcomeMarshaller.decode(json: encoded.json)
        XCTAssertEqual(decoded?.status, .success)
        XCTAssertEqual(decoded?.timestamp, encoded.timestamp)
        XCTAssertNil(decoded?.detail, "ohne detail darf decode kein detail erfinden")
    }

    func test_roundTrip_failed_withDetail() {
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .failed, detail: "Bank weg") else {
            return XCTFail("encode returned nil")
        }
        let decoded = CLIRefreshOutcomeMarshaller.decode(json: encoded.json)
        XCTAssertEqual(decoded?.status, .failed)
        XCTAssertEqual(decoded?.detail, "Bank weg")
    }

    func test_roundTrip_locked() {
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .locked) else {
            return XCTFail("encode returned nil")
        }
        let decoded = CLIRefreshOutcomeMarshaller.decode(json: encoded.json)
        XCTAssertEqual(decoded?.status, .locked)
    }

    func test_roundTrip_detailWithSpecialChars() {
        // Quotes, Umlaute, Newlines — alles was JSON escapen muss.
        let messy = "Fehler bei \"YAXI\" — Verbindung\nverloren (ä,ö,ü)"
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .failed, detail: messy) else {
            return XCTFail("encode returned nil")
        }
        let decoded = CLIRefreshOutcomeMarshaller.decode(json: encoded.json)
        XCTAssertEqual(decoded?.detail, messy)
    }

    // MARK: - Schema stability (CLI reader contract)
    //
    // Der CLI-Reader (DataReader.lastRefreshOutcome) liest exakt diese drei
    // Keys: "status", "timestamp", "detail". Wenn dieser Test bricht, brechen
    // alle ausgelieferten `sb`-Binaries — das Schema ist Wire-Format und
    // braucht eine bewusste Migration.

    func test_schema_encodedJSONUsesContractKeys() throws {
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .failed, detail: "x") else {
            return XCTFail("encode returned nil")
        }
        let data = try XCTUnwrap(encoded.json.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "failed",
            "CLI erwartet Key 'status' mit raw enum value")
        XCTAssertEqual(obj["timestamp"] as? String, encoded.timestamp,
            "CLI erwartet Key 'timestamp' (ISO-8601 string)")
        XCTAssertEqual(obj["detail"] as? String, "x",
            "CLI erwartet optionalen Key 'detail'")
    }

    func test_schema_statusRawValuesMatchCLIContract() {
        // Die rohen String-Werte stehen in `RefreshCommand.swift` im switch.
        // Falls ein Maintainer den enum case umbenennt (z.B. .errored statt
        // .failed), würde der CLI-Switch in ein "Status unbekannt" fallen.
        XCTAssertEqual(CLIRefreshOutcomeStatus.success.rawValue, "success")
        XCTAssertEqual(CLIRefreshOutcomeStatus.locked.rawValue,  "locked")
        XCTAssertEqual(CLIRefreshOutcomeStatus.failed.rawValue,  "failed")
    }

    func test_schema_timestampIsISO8601Parseable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: .success, now: now) else {
            return XCTFail("encode returned nil")
        }
        let parsed = ISO8601DateFormatter().date(from: encoded.timestamp)
        XCTAssertEqual(parsed?.timeIntervalSince1970, now.timeIntervalSince1970,
            "Timestamp muss als ISO-8601 round-trippen")
    }

    // MARK: - Decode robustness

    func test_decode_garbageJSON_returnsNil() {
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: "not json at all"))
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: ""))
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: "{"))
    }

    func test_decode_emptyObject_returnsNil() {
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: "{}"))
    }

    func test_decode_missingTimestamp_returnsNil() {
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: #"{"status":"success"}"#))
    }

    func test_decode_missingStatus_returnsNil() {
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: #"{"timestamp":"2026-01-01T00:00:00Z"}"#))
    }

    func test_decode_unknownStatus_returnsNil() {
        let json = #"{"status":"errored","timestamp":"2026-01-01T00:00:00Z"}"#
        XCTAssertNil(CLIRefreshOutcomeMarshaller.decode(json: json),
            "Unbekannter status muss nil ergeben — sonst rendert die CLI 'Status unbekannt' nicht.")
    }

    // MARK: - Persistence keys (rückwärtskompat)

    func test_keys_areStableContract() {
        // Diese Keys sind Wire-Format gegen ausgelieferte CLI-Binaries.
        // Änderung erfordert eine bewusste Migration mit Dual-Write-Phase.
        XCTAssertEqual(CLIRefreshOutcomeKeys.outcome,
                       "simplebanking.cli.lastRefreshOutcome")
        XCTAssertEqual(CLIRefreshOutcomeKeys.legacy,
                       "simplebanking.cli.lastRefreshCompletedAt")
    }
}

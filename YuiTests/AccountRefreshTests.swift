import XCTest
@testable import Yui

/// YUI-239: a refresh whose reply never lands must not sign the person out.
/// A transport error keeps the account and retries with the same token;
/// only invalid_grant clears it.
@MainActor
final class AccountRefreshTests: XCTestCase {
    private func seeded(_ transport: @escaping (URLRequest) async throws -> (Data, URLResponse)) -> Account {
        let account = Account()
        account.transport = transport
        account.refreshRetryDelays = [.zero, .zero]
        account.seedSessionForTests(YuiSession(userID: "u", appleUserID: "a", email: nil, accessToken: "old",
                                               accessExpiry: .distantPast, refreshToken: "rt-1"))
        return account
    }

    private func reply(_ req: URLRequest, status: Int, _ json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func sentToken(_ req: URLRequest) -> String? {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])?["refresh_token"]
    }

    private let ok = #"{"access_token":"new","expires_in":3600,"refresh_token":"rt-2","user":{"id":"u","email":null}}"#

    func testADroppedReplyRetriesWithTheSameTokenAndStaysSignedIn() async throws {
        var sent: [String?] = []
        let account = seeded { [self] req in
            sent.append(sentToken(req))
            if sent.count == 1 { throw URLError(.networkConnectionLost) }
            return reply(req, status: 200, ok)
        }
        let token = try await account.validAccessToken()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(sent, ["rt-1", "rt-1"], "the retry must spend the same refresh token")
        XCTAssertEqual(account.session?.refreshToken, "rt-2")
    }

    func testAnOfflineRefreshKeepsTheAccount() async {
        let account = seeded { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await account.validAccessToken(); XCTFail("expected an error") } catch {
            XCTAssertTrue(error is URLError)
        }
        XCTAssertEqual(account.session?.refreshToken, "rt-1", "a transport error signed the person out")
    }

    func testAServerHiccupKeepsTheAccount() async {
        let account = seeded { [self] req in reply(req, status: 503, "{}") }
        _ = try? await account.validAccessToken()
        XCTAssertNotNil(account.session, "a 503 signed the person out")
    }

    func testInvalidGrantSignsOut() async {
        let account = seeded { [self] req in reply(req, status: 401, #"{"error":"invalid_grant"}"#) }
        do { _ = try await account.validAccessToken(); XCTFail("expected signedOut") } catch AccountError.signedOut {} catch {
            XCTFail("\(error)")
        }
        XCTAssertNil(account.session)
    }
}

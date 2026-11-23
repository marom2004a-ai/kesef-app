import XCTest
import SwiftData
@testable import Kesef

/// שרת morning מדומה: בודק את הבקשות שהאפליקציה שולחת ומחזיר תשובות לפי התיעוד הרשמי.
final class StubMorning: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var requests: [(URLRequest, Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            stream.close(); body = d
        }
        Self.requests.append((request, body))
        let (status, json) = Self.handler?(request, body) ?? (500, [:])
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MorningServiceTests: XCTestCase {
    var container: ModelContainer!

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubMorning.self]
        MorningService.session = URLSession(configuration: config)
        MorningService.resetForTests()
        StubMorning.requests = []
        MorningService.environment = .sandbox
        MorningService.credentialOverride = { env in env == .sandbox ? ("test-client-id", "test-secret") : ("prod-id", "prod-secret") }
        container = Persistence.makeContainer(inMemory: true)
    }

    override func tearDown() async throws {
        MorningService.credentialOverride = nil
        MorningService.environment = .demo
        MorningService.session = .shared
    }

    private func draft() -> MorningDocumentDraft {
        MorningDocumentDraft(type: .taxInvoiceReceipt, clientName: "לקוח בדיקה", clientEmail: "c@example.com",
                             itemDescription: "אילוף ביתי", amountIncludingVAT: Money(shekels: 1180), payment: .bit, date: .now)
    }

    private func okServer() {
        StubMorning.handler = { req, _ in
            if req.url!.path.hasSuffix("/oauth/token") {
                return (200, ["accessToken": "tok-123", "tokenType": "Bearer", "expiresAt": Int(Date().timeIntervalSince1970) + 3600])
            }
            return (201, ["id": "doc-1", "number": 40034, "type": 320, "signed": true, "lang": "he",
                          "client": ["id": "c1"], "url": ["origin": "https://example.com/o", "he": "https://example.com/he", "en": "https://example.com/en"],
                          "taxAuthorityConfirmationLastError": 0, "vatRate": 0.18])
        }
    }

    func testTokenThenCreateDocumentSendsCorrectRequests() async throws {
        okServer()
        let doc = try await MorningService.createDocument(draft())
        XCTAssertEqual(doc.number, 40034)
        XCTAssertEqual(doc.url?.absoluteString, "https://example.com/he")
        XCTAssertEqual(StubMorning.requests.count, 2)

        let (tokenReq, tokenBody) = StubMorning.requests[0]
        XCTAssertEqual(tokenReq.url?.absoluteString, "https://api.sandbox.morning.dev/idp/v1/oauth/token")
        let tb = try JSONSerialization.jsonObject(with: tokenBody!) as! [String: Any]
        XCTAssertEqual(tb["grant_type"] as? String, "client_credentials")
        XCTAssertEqual(tb["client_id"] as? String, "test-client-id")

        let (docReq, docBody) = StubMorning.requests[1]
        XCTAssertEqual(docReq.url?.absoluteString, "https://sandbox.d.greeninvoice.co.il/api/v1/documents")
        XCTAssertEqual(docReq.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        let db = try JSONSerialization.jsonObject(with: docBody!) as! [String: Any]
        XCTAssertEqual(db["type"] as? Int, 320)
        XCTAssertEqual(((db["payment"] as? [[String: Any]])?.first?["appType"]) as? Int, 1)
    }

    func testTokenIsReusedForSecondDocument() async throws {
        okServer()
        _ = try await MorningService.createDocument(draft())
        _ = try await MorningService.createDocument(draft())
        XCTAssertEqual(StubMorning.requests.filter { $0.0.url!.path.hasSuffix("/oauth/token") }.count, 1)
    }

    func testNoAPIAccessGivesClearError() async {
        StubMorning.handler = { _, _ in (400, ["error": "unauthorized_client", "error_description": "No active subscription"]) }
        do { _ = try await MorningService.createDocument(draft()); XCTFail("should throw") }
        catch { XCTAssertEqual((error as? MorningService.MorningError).map { "\($0)" }, "\(MorningService.MorningError.noAPIAccess)") }
    }

    func testWrongKeysGiveAuthError() async {
        StubMorning.handler = { _, _ in (401, ["error": "invalid_client", "error_description": "bad credentials"]) }
        do { try await MorningService.testConnection(.sandbox); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("bad credentials")) }
    }

    func testAPIErrorIsSurfacedInHebrew() async {
        StubMorning.handler = { req, _ in
            if req.url!.path.hasSuffix("/oauth/token") { return (200, ["accessToken": "t", "tokenType": "Bearer", "expiresAt": Int(Date().timeIntervalSince1970) + 3600]) }
            return (400, ["errorCode": 1102, "errorMessage": "כתובת מייל לא תקינה."])
        }
        do { _ = try await MorningService.createDocument(draft()); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("1102")); XCTAssertTrue(error.localizedDescription.contains("כתובת מייל")) }
    }

    func testSandboxDocumentIsNotRecordedAsIncome() async throws {
        okServer()
        let d = draft()
        let doc = try await MorningService.createDocument(d)
        let e = try MorningService.recordIncome(context: container.mainContext, draft: d, doc: doc, categoryID: nil, accountID: nil)
        XCTAssertNil(e)
        XCTAssertTrue(Ledger(context: container.mainContext).entries().isEmpty)
    }

    func testProductionReceiptRecordsIncomeWithVAT() async throws {
        okServer()
        MorningService.environment = .production
        AppSettings.registerDefaults()
        let d = draft()
        let doc = try await MorningService.createDocument(d)
        XCTAssertEqual(StubMorning.requests[1].0.url?.host, "api.greeninvoice.co.il")
        let e = try XCTUnwrap(try MorningService.recordIncome(context: container.mainContext, draft: d, doc: doc, categoryID: nil, accountID: nil))
        XCTAssertEqual(e.kind, .income)
        XCTAssertEqual(e.scope, .business)
        XCTAssertEqual(e.amount, Money(shekels: 1180))
        XCTAssertEqual(e.vatMinor, 18_000)
        XCTAssertEqual(e.externalRef, "morning:doc-1")
        XCTAssertTrue(e.note.contains("40034"))
    }

    func testDemoModeNeedsNoNetwork() async throws {
        MorningService.environment = .demo
        StubMorning.handler = nil
        let doc = try await MorningService.createDocument(draft())
        XCTAssertTrue(doc.id.hasPrefix("demo-"))
        XCTAssertTrue(StubMorning.requests.isEmpty)
        XCTAssertNil(try MorningService.recordIncome(context: container.mainContext, draft: draft(), doc: doc, categoryID: nil, accountID: nil))
    }
}

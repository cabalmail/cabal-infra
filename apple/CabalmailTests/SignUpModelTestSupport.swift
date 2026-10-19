import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What `SignUpModelRulesTests` and `SignUpModelFlowTests` share: a
/// deployment's configuration, Cognito's replies, and a loaded model whose
/// `CognitoAuthService` answers from a recording transport.
@MainActor
enum SignUpFixtures {
    static func configuration(
        sms: Bool = true,
        invitation: Bool = true,
        operatorName: String? = nil
    ) -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c"),
            invitationRequired: invitation,
            smsEnabled: sms,
            operatorName: operatorName
        )
    }

    static func reply(_ object: [String: Any], status: Int = 200) -> (Data, Int) {
        // swiftlint:disable:next force_try
        (try! JSONSerialization.data(withJSONObject: object), status)
    }

    static func refusal(_ type: String, _ message: String) -> (Data, Int) {
        reply(["__type": type, "message": message], status: 400)
    }

    static let smsDelivery: [String: Any] = [
        "CodeDeliveryDetails": [
            "AttributeName": "phone_number", "DeliveryMedium": "SMS", "Destination": "+*******4567",
        ],
    ]

    /// A model loaded against `configuration`, its Cognito calls answered
    /// from `responses` in order.
    static func loadedModel(
        _ configuration: Configuration = SignUpFixtures.configuration(),
        responses: [(Data, Int)] = []
    ) async -> (SignUpModel, RecordingHTTPTransport) {
        let http = RecordingHTTPTransport(responses: responses)
        let model = SignUpModel(
            controlDomain: " cabalmail.example ",
            loadConfiguration: { _ in configuration },
            makeAuthService: {
                CognitoAuthService(configuration: $0, transport: http, secureStore: InMemorySecureStore())
            }
        )
        await model.load()
        return (model, http)
    }

    /// Every field the SMS deployment asks for, filled validly.
    static func fill(_ model: SignUpModel) {
        model.username = "  Alice "
        model.phone = "+1 (555) 123-4567"
        model.invitationCode = " OPEN-SESAME "
        model.password = "Correct-Horse-9"
        model.confirmPassword = "Correct-Horse-9"
        model.smsConsent = true
    }

    static func sentBody(_ http: RecordingHTTPTransport, at index: Int = 0) async throws -> [String: Any] {
        let request = await http.requests[index]
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

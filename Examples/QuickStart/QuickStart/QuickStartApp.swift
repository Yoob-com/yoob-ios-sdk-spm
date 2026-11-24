import SwiftUI
import Yoob

@main
struct QuickStartApp: App {
    init() {
        #if DEBUG || YOOB_CHECKS
        // Development only: an encrypted character's release content key while the Yoob API does not issue it yet, from
        // the run scheme's environment (YOOB_DEVELOPMENT_CONTENT_KEYS = {"<keyId>": "<base64>"}). Never ship a key in an app.
        if let json = ProcessInfo.processInfo.environment["YOOB_DEVELOPMENT_CONTENT_KEYS"],
           let keys = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            Yoob.developmentContentKeys = keys
        }
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Asks your backend for a Yoob session. The backend calls the Yoob API with your secret key; the app never sees it.
enum Backend {
    static let tokenURL: URL = {
        #if DEBUG || YOOB_CHECKS
        // Development: `--token-url=http://<your Mac's address>:3102/yoob-session` reaches a token server on your Mac. It
        // is remembered, so opening the app from the home screen later uses it too (the phone's localhost is the phone).
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--token-url=") }),
           let url = URL(string: String(arg.dropFirst("--token-url=".count))) {
            UserDefaults.standard.set(url.absoluteString, forKey: "devTokenURL")
            return url
        }
        if let saved = UserDefaults.standard.string(forKey: "devTokenURL"), let url = URL(string: saved) { return url }
        #endif
        return URL(string: Bundle.main.object(forInfoDictionaryKey: "YoobTokenURL") as? String ?? "")!
    }()

    static func credentials(for character: String) async throws -> YoobCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["character": character])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            // The example token server explains refusals, for example that it needs YOOB_EXAMPLE_ALLOW_ANONYMOUS=1.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            print("Yoob token server refused the session: \(body?["error"] as? String ?? "no details")")
            throw YoobError.unauthorized
        }
        return try JSONDecoder().decode(YoobCredentials.self, from: data)
    }

    static let secretURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "OpenAISecretURL") as? String ?? "")!

    /// A short-lived OpenAI Realtime client secret, minted by your backend (to talk through your own OpenAI account).
    static func openAIClientSecret() async throws -> String {
        var request = URLRequest(url: secretURL)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = body["value"] as? String else {
            throw YoobError.unsupported("the backend didn't return an OpenAI client secret")
        }
        return value
    }
}

import Foundation

struct VoiceStatus: Decodable {
    struct Wake: Decodable {
        var model: String?; var label: String?; var kind: String?; var loaded: Bool?
        var threshold: Double?; var default_threshold: Double?; var peak: Double?; var fires: Int?
        var quality: String?; var problem: String?
    }
    struct Choice: Decodable { var name: String; var label: String; var kind: String; var quality: String? }
    struct Utterance: Decodable, Identifiable {
        var id: String
        var text: String
        var command: String?
        var answer: String?
        var problem: String?
    }
    var history: [Utterance]?
    var mic_available: Bool?
    var wake_choices: [Choice]?
    var wake_loading: String?
    var wake_problem: String?
    var enroll: EnrollState?
    struct Speech: Decodable { var model: String?; var loaded: Bool?; var last_s: Double?; var problem: String? }
    var on: Bool?
    var state: String?
    var wakes: Int?
    var last_text: String?
    var last_command: String?
    var last_answer: String?
    var wake: Wake?
    var speech: Speech?
    var problem: String?

    static func read(host: String) async -> VoiceStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/voice") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(VoiceStatus.self, from: data)
    }

    /// POST with the wall's answer: the status code and the JSON.
    static func send(host: String, path: String, body: [String: Any]) async -> (Int, [String: Any]) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return (0, [:]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func post(host: String, path: String, body: [String: Any]) async -> Bool {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}


struct EnrollState: Decodable, Equatable {
    var phrase: String
    var stage: String
    var takes: Int
    var samples: Int
    var rejected: Int?
    var message: String
    var event: String?
    var event_ago: Double?
    var talk_left: Double?
    var talk_s: Double?
    var level_over: Double?
    var recording: Bool?
    var quality: String?
    var separation: Double?
    var name: String?
    var problem: String?
}

struct VoiceMeter: Decodable {
    var state: String?
    var label: String?
    var score: Double?
    var peak: Double?
    var threshold: Double?
    var fires: Int?
    var last_fire_ago: Double?
    var level_over: Double?
    var mic_available: Bool?
    var last_audio_ago: Double?
    var enroll: EnrollState?

    static func read(host: String) async -> VoiceMeter? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/voice/meter") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(VoiceMeter.self, from: data)
    }
}


import Foundation

@main struct VoiceModelChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ description: String) {
            precondition(value(), description); checks += 1
        }
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(VoiceStatus.self, from: Data(#"{"on":true,"state":"idle","wake":{"model":"alexa","threshold":0.5}}"#.utf8))
        expect(legacy.on == true, "Legacy status remains usable")
        expect(legacy.history == nil, "Older wall history is optional")
        expect(legacy.mic_available == nil, "Missing microphone freshness does not become false")
        let live = try decoder.decode(VoiceMeter.self, from: Data(#"{"state":"listening","level_over":18.2,"mic_available":true,"last_audio_ago":0.1}"#.utf8))
        expect(live.mic_available == true, "Read real microphone freshness")
        expect(live.level_over == 18.2, "Read microphone level")
        expect(live.last_audio_ago == 0.1, "Read capture age")
        let stale = try decoder.decode(VoiceMeter.self, from: Data(#"{"state":"idle","mic_available":false,"level_over":null,"last_audio_ago":5.2}"#.utf8))
        expect(stale.mic_available == false, "Distinguish unavailable microphone")
        expect(stale.level_over == nil, "Stale level has no amplitude")
        let history = try decoder.decode(VoiceStatus.self, from: Data(#"{"on":true,"history":[{"id":"voice-1","text":"Show the clock","command":"Clock is on the wall","answer":null,"problem":null},{"id":"voice-2","text":"What is playing?","answer":"Nights by Frank Ocean","problem":null}]}"#.utf8))
        expect(history.history?.count == 2, "Read multiple recent utterances")
        expect(history.history?.first?.id == "voice-1", "Stable identities")
        expect(history.history?.last?.answer == "Nights by Frank Ocean", "Transcript and answer stay together")
        let session = try decoder.decode(EnrollState.self, from: Data(#"{"phrase":"Hey Tessera","stage":"takes","takes":3,"samples":6,"message":"Good. Three more.","level_over":14,"recording":true}"#.utf8))
        expect(session.takes == 3 && session.samples == 6, "Recover real enrollment progress")
        expect(session.recording == true, "Read actual recording state")
        let result: [String: Any] = ["checks": checks, "passed": true, "scope": "Production VoiceModels backward compatibility, live capture state, history identity and enrollment decoding"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: data, as: UTF8.self))
    }
}

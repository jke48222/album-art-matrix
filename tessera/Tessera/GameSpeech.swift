import SwiftUI
import Speech
import AVFoundation

@MainActor @Observable
final class SpeechMove {
    var listening = false
    var heard = ""
    var problem: String?
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var settle: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var onFinal: ((String) -> Void)?

    func start(words: [String], onFinal: @escaping (String) -> Void) {
        guard !listening else { return }
        stop(); problem = nil; heard = ""; listening = true
        self.onFinal = onFinal
        let token = generation
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                guard auth == .authorized else { self.fail("Allow Speech Recognition in iOS Settings to speak a move."); return }
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        guard allowed else { self.fail("Allow Microphone access in iOS Settings to speak a move."); return }
                        self.begin(words: words, token: token)
                    }
                }
            }
        }
    }

    private func begin(words: [String], token: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail("Speech recognition is unavailable. You can still type your move."); return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(words.prefix(100))
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { fail("The microphone is unavailable."); return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            self.engine = engine; self.request = request
            engine.prepare(); try engine.start()
        } catch { fail("The microphone couldn't start. Try typing your move."); return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.listening else { return }
                if let text {
                    self.heard = text
                    self.settle?.cancel()
                    if final { self.finish(text); return }
                    self.settle = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1.1))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.finish(text)
                    }
                }
                if failed { self.fail("Couldn't hear a complete move. Try again or use the keyboard.") }
            }
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            if self.heard.isEmpty { self.fail("No move heard. Tap the microphone to try again.") } else { self.finish(self.heard) }
        }
    }
    private func fail(_ text: String) { stop(); problem = text }
    private func finish(_ text: String) {
        guard listening else { return }
        let callback = onFinal
        stop()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { callback?(text) }
    }
    func stop() {
        generation = UUID(); onFinal = nil
        settle?.cancel(); settle = nil
        deadline?.cancel(); deadline = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        if listening { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        listening = false
    }
}

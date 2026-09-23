import AVFoundation
import Observation

/// Speech owns a system-managed audio session so it cannot reconfigure video playback.
@MainActor @Observable final class AnswerReader: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private(set) var text: String?

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    func toggle(_ value: String) {
        if text == value { stop(); return }
        stop()
        let next = AVSpeechUtterance(string: value)
        next.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance = next
        text = value
        synthesizer.speak(next)
    }

    func stop() {
        utterance = nil
        text = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    private func finished(_ completed: AVSpeechUtterance) {
        guard utterance === completed else { return }
        utterance = nil
        text = nil
    }
}

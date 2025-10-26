import AVFoundation
import Combine

class NativeTTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    
    private let synthesizer = AVSpeechSynthesizer()
    private var timer: Timer?
    
    // This property will hold the most recent track list
    private var currentTracks: [Track] = []
    
    @Published var isSpeaking = false
    
    override init() {
        super.init()
        self.synthesizer.delegate = self
        
        // Start a timer that fires every 7 seconds
        // This timer will call our new processing function
        self.timer = Timer.scheduledTimer(
            withTimeInterval: 0.75,
            repeats: true
        ) { [weak self] _ in
            self?.processStoredTracks()
        }
    }
    
    // 1. This is the new function ContentView will call
    /// Passively updates the manager's list of current tracks.
    func updateCurrentTracks(_ tracks: [Track]) {
        self.currentTracks = tracks
    }
    
    // 2. This function runs every 7 seconds
    /// Processes the stored tracks on the timer's schedule.
    private func processStoredTracks() {
        // If the synthesizer is already talking, just wait.
        // The timer will fire again in 7 seconds and we'll re-check.
        guard !isSpeaking else {
            print("Native TTS: Timer fired, but already speaking. Waiting for next cycle.")
            return
        }

        // Find all high-priority tracks from the last known list
        let highPriorityTracks = currentTracks.filter { $0.priority == "high" }
        
        // Pick one random track
        guard let trackToAnnounce = highPriorityTracks.randomElement() else {
            // No high-priority tracks found, which is fine.
            return
        }

        // Build the string
        guard let label = trackToAnnounce.label, let direction = trackToAnnounce.direction else {
            return // Track is missing required info
        }
        let textToSpeak = generateString(label: label, direction: direction)

        // Speak
        print("Native TTS: Timer fired. Preparing to announce '\"\(textToSpeak)\"'")
        self.speak(textToSpeak)
    }
    
    private func generateString(label: String, direction: String) -> String {
        if (label == "person") {
            if (direction == "straight") {
                return "Person straight ahead of you."
            }
            return "Person moving to the \(direction), from your \(direction == "left" ? "right" : "left")."
        } else {
            if (direction == "straight") {
                return "Caution! \(label) in front of you."
            }
            return "Caution! \(label) on your \(direction)."
        }
    }
    
    /// Call this to make the app speak a string.
    private func speak(_ text: String) {
        // We already check isSpeaking in processStoredTracks,
        // but this is a good final safety check.
        guard !isSpeaking else { return }
        
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        synthesizer.speak(utterance)
    }
    
    // Call this when the object is deallocated to prevent retain cycles
    deinit {
        timer?.invalidate()
    }

    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            print("Native TTS: Finished speaking.")
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            print("Native TTS: Speech cancelled.")
        }
    }
    
    // 3. REMOVE the old processTracks function
    // func processTracks(_ tracks: [Track]) { ... }
}

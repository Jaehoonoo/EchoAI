import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
// import Combine // No longer needed
// import Porcupine // No longer needed


class SpatialAudioManager {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    
    private var leftNode = AVAudioPlayerNode()
    private var centerNode = AVAudioPlayerNode()
    private var rightNode = AVAudioPlayerNode()
    
    private var sideAudioFile: AVAudioFile?
    private var centerAudioFile: AVAudioFile?
    
    // --- ALL TTS PROPERTIES REMOVED ---
    // private var ttsPlayerNode = AVAudioPlayerNode()
    // private var acknowledgementBuffer: AVAudioPCMBuffer?
    // private var ttsFormat: AVAudioFormat?
    
    private var audioFormat: AVAudioFormat?
    
    init() {
        loadAudio()
        guard let audioFormat = self.audioFormat else {
            print("⚠️ Audio file not loaded correctly (is it MONO?), aborting audio setup.")
            return
        }
        
        setupAudioSessionForPlayback() // This is still good
        
        engine.attach(environment)
        engine.attach(leftNode)
        engine.attach(centerNode)
        engine.attach(rightNode)
        
        // --- REMOVED: engine.attach(ttsPlayerNode) ---
        
        leftNode.renderingAlgorithm = .HRTF
        centerNode.renderingAlgorithm = .HRTF
        rightNode.renderingAlgorithm = .HRTF
        
        engine.connect(leftNode, to: environment, format: audioFormat)
        engine.connect(centerNode, to: environment, format: audioFormat)
        engine.connect(rightNode, to: environment, format: audioFormat)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        
        // --- REMOVED: All ttsPlayerNode connection logic ---
        
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudioMake3DAngularOrientation(0, 0, 0)
        
        do {
            try engine.start()
            print("✅ Audio Engine Started.")
        } catch {
            print("Error starting audio engine: \(error)")
        }
    }
    
    private func setupAudioSessionForPlayback() {
        print("Configuring Audio Session for Playback...")
        do {
            let session = AVAudioSession.sharedInstance()
            // This is still correct for playing audio alongside ARKit
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
            
            try session.setActive(true)
            print("✅ Audio Session is active (Playback only).")
            
        } catch {
            print("❌ Failed to set up audio session: \(error)")
        }
    }

    // --- ALL TTS FUNCTIONS REMOVED ---
    // func configureTTSNode(...)
    // func preloadAcknowledgeSound(...)
    // enum TTSSound
    // func playTTS(sound:)
    // func playTTS(pcm:sampleRate:completion:)
    
    private func loadAudio() {
        // ... (This function remains unchanged)
        guard let url = Bundle.main.url(forResource: "soft-beep", withExtension: "wav") else {
            print("⚠️ Could not find soft-beep.wav")
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            if file.processingFormat.channelCount > 1 {
                print("❌ ERROR: 'soft-beep.wav' is STEREO. It MUST be MONO for spatial audio.")
                return
            }
            print("✅ Audio file is MONO and loaded.")
            self.sideAudioFile = file
            self.audioFormat = file.processingFormat
        } catch {
            print("Error loading audio file: \(error)")
        }
        
        guard let centerUrl = Bundle.main.url(forResource: "center-beep", withExtension: "wav") else {
            print("⚠️ Could not find center-beep.wav. Center will be silent.")
            return
        }
        do {
            let file = try AVAudioFile(forReading: centerUrl)
            if file.processingFormat.channelCount > 1 {
                print("❌ ERROR: 'center-beep.wav' is STEREO. It MUST be MONO. Center will be silent.")
                return
            }
            if file.processingFormat != self.audioFormat {
                 print("❌ ERROR: 'center-beep.wav' has a different audio format from 'side-beep.wav'. They must match. Center will be silent.")
                 return
            }
            print("✅ Center audio file is MONO and loaded.")
            self.centerAudioFile = file
        } catch {
            print("Error loading center-beep.wav: \(error). Center will be silent.")
        }
    }
    
    func play(zone: String) {
        // ... (This function remains unchanged)
        let node: AVAudioPlayerNode
        let fileToPlay: AVAudioFile?
        let position: AVAudio3DPoint
        
        switch zone.lowercased() {
        case "left":
            node = leftNode
            fileToPlay = sideAudioFile
            position = AVAudio3DPoint(x: -1, y: 0, z: -1)
        case "center":
            node = centerNode
            fileToPlay = centerAudioFile
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        case "right":
            node = rightNode
            fileToPlay = sideAudioFile
            position = AVAudio3DPoint(x: 1, y: 0, z: -1)
        default:
            node = centerNode
            fileToPlay = centerAudioFile
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        }
        
        guard let audioFile = fileToPlay else {
            print("⚠️ Audio file for zone '\(zone)' is not loaded. Cannot play.")
            return
        }
        
        node.position = position
        node.stop()
        node.scheduleFile(audioFile, at: nil)
        node.play()
    }
}

// --- REMOVED: extension Array where Element == Int16 ---

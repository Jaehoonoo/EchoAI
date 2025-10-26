//
//  SpatialAudioManager.swift
//  EchoAI-client
//
//  Created by Jhoon Yi on 10/25/25.
//
import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
import Combine
import Porcupine


class SpatialAudioManager {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    
    private var leftNode = AVAudioPlayerNode()
    private var centerNode = AVAudioPlayerNode()
    private var rightNode = AVAudioPlayerNode()
    
    private var sideAudioFile: AVAudioFile?
    private var centerAudioFile: AVAudioFile?
    
    // --- NEW: TTS Output Node ---
    private var ttsPlayerNode = AVAudioPlayerNode()
    private var acknowledgementBuffer: AVAudioPCMBuffer? // For "Yes?"
    
    // --- NEW: Audio Input Processing ---
    private var audioConverter: AVAudioConverter?
    private let picovoiceSampleRate = Double(Porcupine.sampleRate) // 16000 Hz
    weak var voiceViewModel: VoiceViewModel? // Link to the voice VM
    
    private var audioFormat: AVAudioFormat?
    
    init() {
        loadAudio()
        // If the file didn't load (e.g., it was stereo), stop here
        guard let audioFormat = self.audioFormat else {
            print("⚠️ Audio file not loaded correctly (is it MONO?), aborting audio setup.")
            return
        }
        
        // --- NEW: Configure Audio Session for AirPods (Input + Output) ---
        setupAudioSession() // Do this BEFORE attaching nodes
        
        engine.attach(environment)
        engine.attach(leftNode)
        engine.attach(centerNode)
        engine.attach(rightNode)
        
        // --- NEW: Attach TTS Node ---
        engine.attach(ttsPlayerNode)
        
        // This is essential for headphones/AirPods
        leftNode.renderingAlgorithm = .HRTF
        centerNode.renderingAlgorithm = .HRTF
        rightNode.renderingAlgorithm = .HRTF
        
        engine.connect(leftNode, to: environment, format: audioFormat)
        engine.connect(centerNode, to: environment, format: audioFormat)
        engine.connect(rightNode, to: environment, format: audioFormat)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        
        // --- NEW: Connect TTS Node (non-spatial, direct to output) ---
        engine.connect(ttsPlayerNode, to: engine.mainMixerNode, format: nil)
        
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudioMake3DAngularOrientation(0, 0, 0)
        
        do {
            try engine.start()
            print("✅ Audio Engine Started.")
            self.installInputTap()
        } catch {
            print("Error starting audio engine: \(error)")
        }
    }
    
    // --- NEW: Configure session for Bluetooth I/O ---
    private func setupAudioSession() {
            print("Configuring Audio Session for Bluetooth I/O...")
            do {
                let session = AVAudioSession.sharedInstance()
                
                // 1. Your category and options are correct for this goal.
                try session.setCategory(.playAndRecord,
                                        mode: .default,
                                        options: [.allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
                

                guard let builtInMic = session.availableInputs?.first(where: {
                    $0.portType == .builtInMic
                }) else {
                    print("⚠️ Could not find the built-in microphone. Session will activate with default input.")
                    // Activate anyway, but it will likely default to HFP and break spatial audio
                    try session.setActive(true)
                    print("⚠️ Audio Session is active, but may be in low-quality HFP mode.")
                    return
                }

                // 3. Force the input to be the built-in mic.
                // This tells iOS: "Use Bluetooth for OUTPUT (A2DP, as requested)
                // but use the Phone's Mic for INPUT."
                try session.setPreferredInput(builtInMic)
                print("✅ Set preferred input to built-in mic.")

                try session.setActive(true)
                print("✅ Audio Session is active (A2DP output + Built-in Mic input).")
                
            } catch {
                print("❌ Failed to set up audio session: \(error)")
            }
        }
//
//    // --- NEW: Install Mic Tap & Resampler ---
    private func installInputTap() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // --- ✅ ADD THIS NEW GUARD STATEMENT ---
        // Check if the mic is ready. If sampleRate is 0, it's not.
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("⚠️ Mic not yet ready (format is invalid). Retrying in 1 second...")
            
            // This gives the audio session time to activate
            // and for the user to (hopefully) grant permission.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.installInputTap()
            }
            return
        }
        
        // Create a format for 16kHz MONO (required by Picovoice)
        guard let picovoiceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, // Converter works well with Float32
            sampleRate: picovoiceSampleRate,
            channels: 1,
            interleaved: false)
        else {
            print("❌ Could not create Picovoice audio format.")
            return
        }

        // Create the resampler
        guard let converter = AVAudioConverter(from: inputFormat, to: picovoiceFormat) else {
            print("❌ Could not create audio converter.")
            return
        }
        self.audioConverter = converter
        
        print("Installing audio tap. Input: \(inputFormat.sampleRate)Hz, Output: 16000Hz")
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, let converter = self.audioConverter else { return }

            // Create a buffer to hold the converted (resampled) audio
            let capacity = AVAudioFrameCount(picovoiceFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate)
            guard let pcmBuffer16kHz = AVAudioPCMBuffer(pcmFormat: picovoiceFormat, frameCapacity: capacity) else {
                return
            }
            pcmBuffer16kHz.frameLength = pcmBuffer16kHz.frameCapacity

            var error: NSError? = nil
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            // Perform the conversion
            converter.convert(to: pcmBuffer16kHz, error: &error, withInputFrom: inputBlock)
            
            if let error = error {
                print("Audio conversion error: \(error)")
                return
            }
            
            // Convert the 16kHz buffer to [Int16] for Picovoice
            if let pcmInt16 = pcmBuffer16kHz.toInt16Array() {
                // Send the 16kHz PCM to the VoiceViewModel
                self.voiceViewModel?.processAudio(pcm: pcmInt16)
            }
        }
    }

    // --- NEW: TTS Playback Functions ---
    
    /// Pre-loads the "Yes?" sound synthesized by Orca
    func preloadAcknowledgeSound(pcm: [Int16], sampleRate: Double) {
        self.acknowledgementBuffer = pcm.toAVAudioPCMBuffer(sampleRate: sampleRate)
    }

    enum TTSSound {
        case acknowledgement
    }
    
    /// Plays a pre-loaded sound (like "Yes?")
    func playTTS(sound: TTSSound) {
        guard let buffer = (sound == .acknowledgement ? acknowledgementBuffer : nil) else {
            return
        }
        
        ttsPlayerNode.stop()
        ttsPlayerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        ttsPlayerNode.play()
    }

    /// Plays arbitrary PCM data (the OCR text)
    func playTTS(pcm: [Int16], sampleRate: Double) {
        guard let buffer = pcm.toAVAudioPCMBuffer(sampleRate: sampleRate) else {
            print("❌ Could not create TTS buffer from PCM")
            return
        }
        
        ttsPlayerNode.stop()
        
        // Schedule the buffer to play. The completion handler is critical.
        ttsPlayerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            // This runs when the buffer is finished playing
            DispatchQueue.main.async {
                self?.voiceViewModel?.ttsDidFinish()
            }
        }
        
        ttsPlayerNode.play()
    }
    
    private func loadAudio() {
        guard let url = Bundle.main.url(forResource: "soft-beep", withExtension: "wav") else {
            print("⚠️ Could not find soft-beep.wav")
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            
            // --- 4. ⭐️ CRITICAL CHECK: Ensure file is MONO ---
            if file.processingFormat.channelCount > 1 {
                print("❌ ERROR: 'soft-beep.wav' is STEREO. It MUST be MONO for spatial audio.")
                // You must re-export your audio file as a mono file.
                return
            }
            
            print("✅ Audio file is MONO and loaded.")
            self.sideAudioFile = file
            self.audioFormat = file.processingFormat // Save the format
            
        } catch {
            print("Error loading audio file: \(error)")
        }
        
        // --- 2. Load Center Beep (OPTIONAL, BUT RECOMMENDED) ---
        // This only runs if the side beep was loaded successfully
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

            // IMPORTANT: Check if the format matches the one we're using for the engine
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
        // ⭐️ Select the correct file and node
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
            fileToPlay = centerAudioFile // ⭐️ Use center file
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        case "right":
            node = rightNode
            fileToPlay = sideAudioFile
            position = AVAudio3DPoint(x: 1, y: 0, z: -1)
        default:
            node = centerNode
            fileToPlay = centerAudioFile // ⭐️ Use center file
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        }
        
        // ⭐️ Guard that the file we selected is actually loaded
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

// --- NEW: Helper Extensions (Add to a new file or bottom of this one) ---

extension AVAudioPCMBuffer {
    /// Converts a Float32 AVAudioPCMBuffer to an [Int16] array for Picovoice
    func toInt16Array() -> [Int16]? {
        guard let floatChannelData = self.floatChannelData else { return nil }
        let frameLength = Int(self.frameLength)
        let channelCount = Int(self.format.channelCount)
        
        var pcmInt16 = [Int16]()
        pcmInt16.reserveCapacity(frameLength)
        
        for i in 0..<frameLength {
            // Assuming mono for Picovoice
            let floatSample = floatChannelData[0][i]
            // Convert from [-1.0, 1.0] to [-32768, 32767]
            let intSample = Int16(max(min(floatSample * 32767.0, 32767.0), -32768.0))
            pcmInt16.append(intSample)
        }
        
        return pcmInt16
    }
}

extension Array where Element == Int16 {
    /// Converts an [Int16] array to an AVAudioPCMBuffer for playback
    func toAVAudioPCMBuffer(sampleRate: Double) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(self.count)) else {
            return nil
        }
        
        buffer.frameLength = buffer.frameCapacity
        
        // Copy the data
        let int16ChannelData = buffer.int16ChannelData!
        for i in 0..<self.count {
            int16ChannelData[0][i] = self[i]
        }
        
        return buffer
    }
}

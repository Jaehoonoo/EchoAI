//
//  VoiceViewModel.swift
//  EchoAI-client
//
//  Created by Jhoon Yi on 10/26/25.
//

// VoiceViewModel.swift
import Foundation
import Combine
import Porcupine // Add Picovoice Swift Packages
import Cheetah
import Orca
import AVFoundation // For CVPixelBuffer

class VoiceViewModel: ObservableObject {
    
    // --- 1. State Machine ---
    enum AppState {
        case waiting
        case listening
        case processing
    }
    @Published var appState: AppState = .waiting
    @Published var partialTranscript: String = ""
    @Published var ocrTextForUI: String = "" // Status text for the UI

    // --- 2. Picovoice Engines ---
    private var porcupine: Porcupine?
    private var cheetah: Cheetah?
    private var orca: Orca?
    private let accessKey = "Xyt7RTtQXqncJ99+NxuIhGSpLXUaxY9yZRGlYgCaway9zXJso6LcPw==" // ⚠️ Add your key
    
    // --- 3. Dependencies ---
    private weak var audioManager: SpatialAudioManager?
    private var ocrManager: OCRWebSocketManager
    private var cancellables = Set<AnyCancellable>()
    
    // This is updated by ARViewContainer's Coordinator
    var latestPixelBuffer: CVPixelBuffer?

    // --- 4. Initialization ---
    init(ocrManager: OCRWebSocketManager) {
        self.ocrManager = ocrManager
        
        do {
            try setupPicovoice()
            subscribeToOCRManager()
        } catch {
            print("❌ PICOVOICE ERROR: \(error.localizedDescription)")
            self.ocrTextForUI = "Picovoice init failed."
        }
    }
    
    /// Links this VM to the audio manager for audio I/O
    func setAudioManager(_ audioManager: SpatialAudioManager) {
        self.audioManager = audioManager
    }
    
    
    // --- 5. Core Audio Processing (Called by SpatialAudioManager) ---
    
    /// This is the heart of the state machine, driven by audio from SpatialAudioManager
    public func processAudio(pcm: [Int16]) {
        guard appState == .waiting || appState == .listening else { return }
        
        do {
            if appState == .waiting {
                let result = try porcupine?.process(pcm: pcm)
                if result == 0 { // 0 is the index of "Hey Echo"
                    handleWakeWord()
                }
            } else if appState == .listening {
                // ✅ NEW: Safely unwrap cheetah right at the start of the block
                guard let cheetah = self.cheetah else { return }
                
                let (partial, isEndpoint) = try cheetah.process(pcm)
                
                if !partial.isEmpty {
                    DispatchQueue.main.async {
                        self.partialTranscript += partial
                    }
                }
                
                if isEndpoint {
                    let finalTranscript = try cheetah.flush()
                    handleCommand(partialTranscript + finalTranscript)
                }
            }
        } catch {
            print("❌ PICOVOICE process error: \(error)")
            DispatchQueue.main.async { self.appState = .waiting }
        }
    }
    
    // --- 6. State Machine Logic ---
    
    private func handleWakeWord() {
        print("✅ Wake word detected!")
        DispatchQueue.main.async {
            self.appState = .listening
            self.partialTranscript = ""
            self.ocrTextForUI = "Yes?..."
        }
        // Play "Yes?" sound
        //audioManager?.playTTS(sound: .acknowledgement)
    }
    
    private func handleCommand(_ transcript: String) {
        let command = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        print("Command received: '\(command)'")
        
        if command.contains("read this for me") {
            print("✅ Command recognized! Triggering OCR.")
            DispatchQueue.main.async {
                self.appState = .processing
                self.ocrTextForUI = "Reading..."
            }
            // The `ARViewContainer.renderer` loop will now see
            // this state and tell `OCRWebSocketManager` to send the `do_ocr=true` flag.
            
        } else {
            print("❓ Unknown command. Returning to wait.")
            DispatchQueue.main.async {
                self.ocrTextForUI = "Unknown command."
            }
            returnToWaiting()
        }
    }
    
    /// Subscribes to the text responses from the OCR server
    private func subscribeToOCRManager() {
        ocrManager.$ocrText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.handleOCRText(newText)
            }
            .store(in: &cancellables)
    }

    /// Called when the OCRWebSocketManager gets a new text response
    private func handleOCRText(_ text: String) {
        // We only care about the text if we are in the processing state
        guard appState == .processing, !text.isEmpty else { return }
        
        // ✅ NEW: Safely unwrap both orca and its sampleRate here
        guard let orca = self.orca, let sampleRate = orca.sampleRate else {
            print("❌ Orca engine or its sample rate is not available.")
            returnToWaiting()
            return
        }
        
        print("Synthesizing: \(text)")
        self.ocrTextForUI = text
        
        do {
            // ✅ FIXED: Use the new, unwrapped 'orca' and 'sampleRate'
            let (pcm, _) = try orca.synthesize(text: text)
            //audioManager?.playTTS(pcm: pcm, sampleRate: Double(sampleRate))
        } catch {
            print("❌ Orca synthesis error: \(error)")
            returnToWaiting()
        }
    }
    
    /// This is called by SpatialAudioManager when TTS playback finishes
    func ttsDidFinish() {
        print("TTS finished. Returning to wait.")
        returnToWaiting()
    }
    
    /// Call this from ContentView.onAppear
    func linkAudioAndPreload(audioManager: SpatialAudioManager) {
        self.setAudioManager(audioManager)
        
        // Safely unwrap orca and its sampleRate
        guard let orca = self.orca, let sampleRate = orca.sampleRate else {
            print("❌ Orca not ready or sample rate is nil")
            return
        }
        
        do {
            let (pcm, _) = try orca.synthesize(text: "Yes?")
            // Use the unwrapped sampleRate
            //audioManager.preloadAcknowledgeSound(pcm: pcm, sampleRate: Double(sampleRate))
        } catch {
            print("❌ Orca failed to synthesize 'Yes?': \(error)")
        }
    }

    private func returnToWaiting() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { // Brief delay
            self.appState = .waiting
            self.partialTranscript = ""
            self.ocrTextForUI = ""
        }
    }
    
    // --- 7. Picovoice Setup ---
    private func setupPicovoice() throws {
        // A. Find model files in your app bundle
        guard let porcupinePath = Bundle.main.path(forResource: "Hey-Echo_en_ios_v3_0_0", ofType: "ppn") else { // ⚠️ Rename to your .ppn file
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Hey-Echo .ppn file"])
        }
        guard let cheetahModelPath = Bundle.main.path(forResource: "EchoAI-cheetah-default-v2.3.0-25-10-26--08-24-03", ofType: "pv") else { // ⚠️ Rename to your cheetah .pv file
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Cheetah .pv file"])
        }
        guard let orcaModelPath = Bundle.main.path(forResource: "orca_params_en_male", ofType: "pv") else { // ⚠️ Rename to your orca .pv file
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Orca .pv file"])
        }

        // B. Initialize Porcupine (the low-level engine)
        self.porcupine = try Porcupine(
            accessKey: accessKey,
            keywordPaths: [porcupinePath],
            modelPath: nil, // Use default
            sensitivities: [0.5] // The engine takes an array of sensitivities
        )
        print("✅ Porcupine (Engine) initialized.")
        // We actually want to drive Porcupine manually from our *own* audio engine.
        // Let's re-init PorcupineManager to NOT start its own audio.
        print("✅ Porcupine (Wake Word) initialized.")

        // C. Initialize Cheetah
        self.cheetah = try Cheetah(
            accessKey: accessKey,
            modelPath: cheetahModelPath,
            endpointDuration: 1.0,
            enableAutomaticPunctuation: true
        )
        print("✅ Cheetah (STT) initialized.")

        // D. Initialize Orca
        self.orca = try Orca(accessKey: accessKey, modelPath: orcaModelPath)
        print("✅ Orca (TTS) initialized.")
    }
}

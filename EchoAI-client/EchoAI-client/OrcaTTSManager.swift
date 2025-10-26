////
////  OrcaTTSManager.swift
////  EchoAI-client
////
////  Created by Jhoon Yi on 10/26/25.
////
//
//
//import Foundation
//import Orca
//import Combine
//
//class OrcaTTSManager: ObservableObject {
//
//    private let audioManager: SpatialAudioManager
//    private var announcedTrackIDs = Set<Int>()
//    private var isSpeaking = false
//    
//    // A serial queue to handle synthesis tasks one at a time
//    private let synthesisQueue = DispatchQueue(label: "com.yourapp.orcaSynthesis")
//    
//    // 2. The Orca TTS engine instance
//    private var orca: Orca!
//    
//    public var orcaSampleRate: Double {
//            // Provide a sensible default in case orca fails to init
//            return Double(orca?.sampleRate ?? 16000)
//        }
//
//    // 3. Update init to accept an access key
//    init(audioManager: SpatialAudioManager, accessKey: String) {
//        self.audioManager = audioManager
//        
//        // 4. Initialize the Orca engine
//        do {
//            self.orca = try Orca(accessKey: accessKey, modelPath: "orca_params_en_male.pv")
//            print("✅ OrcaTTSManager initialized and engine created.")
//        } catch {
//            print("❌ Failed to initialize Orca engine: \(error)")
//            self.orca = nil
//        }
//    }
//
//    /// This function should be called repeatedly with the list of current tracks
//    /// (e.g., from your detection update loop).
//    func processTracks(_ tracks: [Track]) {
//        // 1. If we are already in the process of synthesizing/speaking, wait.
//        guard !isSpeaking else { return }
//
//        // 2. Find all current high-priority tracks
//        let highPriorityTracks = tracks.filter { $0.priority == "high" }
//        
//        // 3. Pick one random track from the high-priority list
//        guard let trackToAnnounce = highPriorityTracks.randomElement() else {
//            return // No high-priority tracks to announce
//        }
//
//        // 4. Build the string
//        guard let label = trackToAnnounce.label, let direction = trackToAnnounce.direction else {
//            return // Track is missing required info
//        }
//        let textToSpeak = "\(label), \(direction)"
//
//        // 5. Set flags to "busy"
//        isSpeaking = true
//        // NOTE: We no longer need to track announcedTrackIDs
//        print("Orca: Preparing to announce '\"\(textToSpeak)\"' for track ID \(trackToAnnounce.id)")
//
//        // 6. Dispatch synthesis to a background queue
//        synthesisQueue.async { [weak self] in
//                    
//            // --- Call the REAL synthesis function ---
//            guard let (pcm, sampleRate) = self?.synthesizeWithOrca(text: textToSpeak), let self = self else {
//                print("Orca: Synthesis failed for '\(textToSpeak)'.")
//                DispatchQueue.main.async { self?.isSpeaking = false } // Reset flag on failure
//                return
//            }
//
//            // --- On success, dispatch playback to the main thread ---
//            DispatchQueue.main.async {
//                self.audioManager.playTTS(pcm: pcm, sampleRate: sampleRate) {
//                    // This completion block runs *after* audio finishes playing
//                    self.isSpeaking = false
//                    print("Orca: Finished playing '\"\(textToSpeak)\"'. Ready for next.")
//                }
//            }
//        }
//    }
//    /// Clears the memory of announced tracks.
//    func resetAnnouncedTracks() {
//        announcedTrackIDs.removeAll()
//    }
//
//    // --- 6. REAL Orca synthesis function ---
//    
//    /// Synthesizes text using the Orca engine.
//    /// This function is blocking and should be called from a background thread.
//    private func synthesizeWithOrca(text: String) -> (pcm: [Int16], sampleRate: Double)? {
//        guard let orca = self.orca else {
//            print("❌ Orca engine not initialized.")
//            return nil
//        }
//        
//        print("Orca: Synthesis START for '\(text)'...")
//        
//        do {
//            // 1. Synthesize returns the PCM and word array
//            let result = try orca.synthesize(text: text)
//            
//            // 2. Get the sample rate from the orca instance itself
//            let sampleRate = Double(orca.sampleRate!) // <-- THE FIX
//            
//            print("Orca: Synthesis END for '\(text)'.")
//            
//            // 3. Return the pcm and the correct sample rate
//            return (pcm: result.pcm, sampleRate: sampleRate)
//            
//        } catch {
//            print("❌ Orca synthesis error for '\(text)': \(error)")
//            return nil
//        }
//    }}

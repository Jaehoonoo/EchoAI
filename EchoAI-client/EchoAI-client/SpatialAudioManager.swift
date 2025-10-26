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


class SpatialAudioManager {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    
    private var leftNode = AVAudioPlayerNode()
    private var centerNode = AVAudioPlayerNode()
    private var rightNode = AVAudioPlayerNode()
    
    private var sideAudioFile: AVAudioFile?
    private var centerAudioFile: AVAudioFile?
    
    private var audioFormat: AVAudioFormat?
    
    init() {
        loadAudio()
        // If the file didn't load (e.g., it was stereo), stop here
        guard let audioFormat = self.audioFormat else {
            print("⚠️ Audio file not loaded correctly (is it MONO?), aborting audio setup.")
            return
        }
        engine.attach(environment)
        engine.attach(leftNode)
        engine.attach(centerNode)
        engine.attach(rightNode)
        
        // This is essential for headphones/AirPods
        leftNode.renderingAlgorithm = .HRTF
        centerNode.renderingAlgorithm = .HRTF
        rightNode.renderingAlgorithm = .HRTF
        
        engine.connect(leftNode, to: environment, format: audioFormat)
        engine.connect(centerNode, to: environment, format: audioFormat)
        engine.connect(rightNode, to: environment, format: audioFormat)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudioMake3DAngularOrientation(0, 0, 0)
        
        do {
            try engine.start()
        } catch {
            print("Error starting audio engine: \(error)")
        }
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

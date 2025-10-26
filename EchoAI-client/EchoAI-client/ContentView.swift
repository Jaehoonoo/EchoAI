import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
import Combine


struct ContentView: View {
    @State private var distances: [String: Float] = ["Left": 99, "Center": 99, "Right": 99]
    @State private var lastTriggerTime = Date(timeIntervalSince1970: 0)
    
    @State private var tracks: [Track] = []
    @State private var arImageResolution: CGSize = .zero
    
    @StateObject private var webSocketManager = WebSocketManager()
    @StateObject private var ocrWebSocketManager = OCRWebSocketManager()
    
    // --- 1. Define the managers ---
    private let audioManager: SpatialAudioManager
    @StateObject private var ttsManager = NativeTTSManager()
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    // --- 2. Add custom init to wire up dependencies ---
    init() {
        // Create the audio manager first
        let am = SpatialAudioManager()
        self.audioManager = am

    }
    
    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(distances: $distances,
                            lastTriggerTime: $lastTriggerTime,
                            tracks: $tracks,
                            audioManager: audioManager, // Pass the same audioManager
                            webSocketManager: webSocketManager,
                            imageResolution: $arImageResolution)
            .edgesIgnoringSafeArea(.all)
            
            
            DetectionOverlayView(tracks: tracks,
                                 imageResolution: arImageResolution)
            
            
            VStack {
                Spacer()
                HStack(spacing: 20) {
                    ForEach(["Left", "Center", "Right"], id: \.self) { zone in
                        if let distance = distances[zone] {
                            VStack {
                                Text("Zone \(zone)")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(String(format: "%.2f m", distance))
                                    .foregroundColor(distance < 0.5 ? .red : .white)
                            }
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        // --- 3. Update .onReceive ---
        .onReceive(webSocketManager.$tracks) { newTracks in
            // When the manager gets new tracks, update our local state
            self.tracks = newTracks
        
            // NEW: Ask the TTS manager to process these new tracks
            ttsManager.updateCurrentTracks(newTracks)
        }
        .onAppear {
            feedbackGenerator.prepare()
        }
        .onDisappear {
            webSocketManager.disconnect()
            //ocrWebSocketManager.disconnect() // NEW
        }
    }
}

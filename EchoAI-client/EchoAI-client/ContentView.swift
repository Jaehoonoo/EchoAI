import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
import Combine


struct ContentView: View {
    @State private var distances: [String: Float] = ["Left": 99, "Center": 99, "Right": 99]
    @State private var lastTriggerTime = Date(timeIntervalSince1970: 0)
    
    // This state is now populated by the WebSocketManager
    @State private var tracks: [Track] = []
    // NEW: Add state to hold the resolution from the ARSession
    @State private var arImageResolution: CGSize = .zero
    
    // Create the WebSocketManager as a StateObject
    @StateObject private var webSocketManager = WebSocketManager()
    
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let audioManager = SpatialAudioManager()

    
    var body: some View {
        ZStack {
            ARViewContainer(distances: $distances,
                            lastTriggerTime: $lastTriggerTime,
                            tracks: $tracks,
                            audioManager: audioManager,
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
        .onReceive(webSocketManager.$tracks) { newTracks in
                    // When the manager gets new tracks, update our local state
                    self.tracks = newTracks
                }
                .onAppear {
                    feedbackGenerator.prepare()
                    setupAudioSession()
                    // The manager connects itself in its init()
                }
                .onDisappear {
                     // Optionally disconnect
                     webSocketManager.disconnect()
                }
    }
    private func setupAudioSession() {
            do {
                let session = AVAudioSession.sharedInstance()
                
                // ⭐️ FIX IS HERE: Use .allowBluetoothA2DP ⭐️
                try session.setCategory(.playback,
                                        mode: .default,
                                        options: [.allowBluetoothA2DP, .mixWithOthers]) // ⬅️ CORRECTED LINE
                
                try session.setActive(true)
                print("✅ Audio Session is active and configured for Bluetooth A2DP.")
                
            } catch {
                print("Failed to set up audio session: \(error)")
            }
        }
}


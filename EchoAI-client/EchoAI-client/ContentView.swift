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
    @StateObject private var ocrWebSocketManager = OCRWebSocketManager() // NEW
    
    // NEW: Initialize VoiceViewModel and inject the OCR manager
    //@StateObject private var voiceViewModel: VoiceViewModel
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let audioManager = SpatialAudioManager()
    
    // NEW: Custom init to wire up the VM
    init() {
//        let ocrManager = OCRWebSocketManager()
//        _ocrWebSocketManager = StateObject(wrappedValue: ocrManager)
//        _voiceViewModel = StateObject(wrappedValue: VoiceViewModel(ocrManager: ocrManager))
    }
    
    var body: some View {
        ZStack {
            // 1. AR View (now with new managers)
            ARViewContainer(distances: $distances,
                            lastTriggerTime: $lastTriggerTime,
                            tracks: $tracks,
                            audioManager: audioManager,
                            webSocketManager: webSocketManager,
//                            ocrWebSocketManager: ocrWebSocketManager, // NEW
//                            voiceViewModel: voiceViewModel,           // NEW
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
            // 4. --- NEW: Voice Status Overlay ---
            //VoiceStatusOverlay(viewModel: voiceViewModel)
            
        }
        .onReceive(webSocketManager.$tracks) { newTracks in
            // When the manager gets new tracks, update our local state
            self.tracks = newTracks
        }
        .onAppear {
            feedbackGenerator.prepare()
                
            // This connects the mic tap to the voice VM
            //audioManager.voiceViewModel = voiceViewModel
            
            // ✅ Make sure this line is correct
            // This connects the VM to the TTS player AND pre-synthesizes "Yes?"
            //voiceViewModel.linkAudioAndPreload(audioManager: audioManager)

            // We also need to add back the mic permission request
            //audioManager.requestPermissionAndStartMicTap()
            
            // REMOVED: setupAudioSession() is now handled by SpatialAudioManager
        }
        .onDisappear {
            webSocketManager.disconnect()
            //ocrWebSocketManager.disconnect() // NEW
        }
    }
    //    private func setupAudioSession() {
    //            do {
    //                let session = AVAudioSession.sharedInstance()
    //
    //                // ⭐️ FIX IS HERE: Use .allowBluetoothA2DP ⭐️
    //                try session.setCategory(.playback,
    //                                        mode: .default,
    //                                        options: [.allowBluetoothA2DP, .mixWithOthers]) // ⬅️ CORRECTED LINE
    //
    //                try session.setActive(true)
    //                print("✅ Audio Session is active and configured for Bluetooth A2DP.")
    //
    //            } catch {
    //                print("Failed to set up audio session: \(error)")
    //            }
    //        }
    //}
    
    // --- NEW: UI View for Voice Status (Add at bottom or new file) ---
//    struct VoiceStatusOverlay: View {
//        @ObservedObject var
//        
//        var body: some View {
//            VStack {
//                // Top-center status
//                if viewModel.appState != .waiting || !viewModel.ocrTextForUI.isEmpty {
//                    Text(statusText)
//                        .font(.title2)
//                        .fontWeight(.bold)
//                        .foregroundColor(.white)
//                        .padding()
//                        .background(statusColor.opacity(0.8))
//                        .cornerRadius(15)
//                        .transition(.opacity.combined(with: .move(edge: .top)))
//                        .padding(.top, 20)
//                }
//                Spacer()
//            }
//            .animation(.easeInOut, value: statusText)
//        }
//        
//        var statusText: String {
//            switch viewModel.appState {
//            case .waiting:
//                return viewModel.ocrTextForUI // Shows "Unknown command" briefly
//            case .listening:
//                return "Listening... \(viewModel.partialTranscript)"
//            case .processing:
//                return viewModel.ocrTextForUI // "Reading..." or the final text
//            }
//        }
//        
//        var statusColor: Color {
//            switch viewModel.appState {
//            case .waiting: return .gray
//            case .listening: return .blue
//            case .processing: return .green
//            }
//        }
//    }
}


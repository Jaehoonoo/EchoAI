import SwiftUI
import ARKit
import SceneKit
import AVFoundation

// MARK: - Spatial Audio Manager
class SpatialAudioManager {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    
    private var leftNode = AVAudioPlayerNode()
    private var centerNode = AVAudioPlayerNode()
    private var rightNode = AVAudioPlayerNode()
    
    private var audioFile: AVAudioFile?
    
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
            self.audioFile = file
            self.audioFormat = file.processingFormat // Save the format
            
        } catch {
            print("Error loading audio file: \(error)")
        }
    }
    
    func play(zone: String) {
        guard let audioFile = audioFile else { return }
        let node: AVAudioPlayerNode
        let position: AVAudio3DPoint
        
        switch zone.lowercased() {
        case "left":
            node = leftNode
            position = AVAudio3DPoint(x: -1, y: 0, z: -1)
        case "center":
            node = centerNode
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        case "right":
            node = rightNode
            position = AVAudio3DPoint(x: 1, y: 0, z: -1)
        default:
            node = centerNode
            position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        }
        
        node.position = position
        node.stop()
        node.scheduleFile(audioFile, at: nil)
        node.play()
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @State private var distances: [String: Float] = ["Left": 99, "Center": 99, "Right": 99]
    @State private var lastTriggerTime = Date(timeIntervalSince1970: 0)
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let audioManager = SpatialAudioManager()
    
    var body: some View {
        ZStack {
            ARViewContainer(distances: $distances,
                            lastTriggerTime: $lastTriggerTime,
                            audioManager: audioManager)
                .edgesIgnoringSafeArea(.all)
            
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
        .onAppear {
            feedbackGenerator.prepare()
            setupAudioSession()
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

// MARK: - ARViewContainer
struct ARViewContainer: UIViewRepresentable {
    @Binding var distances: [String: Float]
    @Binding var lastTriggerTime: Date
    
    let audioManager: SpatialAudioManager
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.scene = SCNScene()
        arView.autoenablesDefaultLighting = true
        
        let config = ARWorldTrackingConfiguration()
        
        // Enable mesh reconstruction for wireframe
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        // Enable depth for distance calculations
        config.frameSemantics = .sceneDepth
        config.environmentTexturing = .automatic
        
        arView.session.run(config)
        
        // Black background - wireframe only, no camera feed
        arView.scene.background.contents = UIColor.black
        
        context.coordinator.arView = arView
        
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self, audioManager: audioManager)
    }
    
    class Coordinator: NSObject, ARSCNViewDelegate {
        var parent: ARViewContainer
        let audioManager: SpatialAudioManager
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
        
        weak var arView: ARSCNView?
        var meshNodes: [UUID: SCNNode] = [:]
        var meshGeometryVersions: [UUID: Int] = [:]
        
        // ⭐️ Define the maximum distance to keep wireframes visible/active ⭐️
        let maxDisplayDistance: Float = 6.0 // Meters (Adjust as needed)
        
        init(_ parent: ARViewContainer, audioManager: SpatialAudioManager) {
            self.parent = parent
            self.audioManager = audioManager
        }
        
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // 1. Get the current frame and camera's "point of view"
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let pointOfView = arView.pointOfView // Camera node
            else { return }
            
            // --- DEPTH ANALYSIS FOR ZONES ---
            if let sceneDepth = frame.sceneDepth {
                let depthMap = sceneDepth.depthMap
                let width = CVPixelBufferGetWidth(depthMap)
                let height = CVPixelBufferGetHeight(depthMap)
                
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
                
                guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
                let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
                
                var leftMin: Float = .greatestFiniteMagnitude
                var centerMin: Float = .greatestFiniteMagnitude
                var rightMin: Float = .greatestFiniteMagnitude
                
                let step = 8
                
                for y in stride(from: 0, to: height, by: step) {
                    for x in stride(from: 0, to: width, by: step) {
                        let index = y * width + x
                        let distance = floatBuffer[index]
                        if distance.isNaN || distance <= 0 { continue }
                        
                        let px = Float(x - width / 2) / 500.0
                        
                        // Zone classification
                        if px < -0.1 { leftMin = min(leftMin, distance) }
                        else if px <= 0.1 { centerMin = min(centerMin, distance) }
                        else { rightMin = min(rightMin, distance) }
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // Update distances in SwiftUI
                    self.parent.distances["Left"] = leftMin.isFinite ? leftMin : 99
                    self.parent.distances["Center"] = centerMin.isFinite ? centerMin : 99
                    self.parent.distances["Right"] = rightMin.isFinite ? rightMin : 99
                    
                    // Haptic + audio for close objects
                    if [leftMin, centerMin, rightMin].contains(where: { $0 < 0.5 }) {
                        let now = Date()
                        if now.timeIntervalSince(self.parent.lastTriggerTime) > 0.5 {
                            self.parent.lastTriggerTime = now
                            self.feedbackGenerator.impactOccurred()
                            
                            if leftMin < 0.5 { self.audioManager.play(zone: "left") }
                            if centerMin < 0.5 { self.audioManager.play(zone: "center") }
                            if rightMin < 0.5 { self.audioManager.play(zone: "right") }
                        }
                    }
                }
            }
            
            // --- MESH WIREFRAME RENDERING (PERSISTENT + DISTANCE & VISIBILITY OPTIMIZED) ---

            // Get camera position
            let cameraTransform = frame.camera.transform
            let cameraPosition = simd_float3(cameraTransform.columns.3.x,
                                             cameraTransform.columns.3.y,
                                             cameraTransform.columns.3.z)

            // Get all mesh anchors ARKit currently provides
            let currentMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

            // Iterate through the current anchors to add new ones or update existing ones
            for anchor in currentMeshAnchors {
                let id = anchor.identifier
                let node: SCNNode
                let currentGeometryVersion = Int(anchor.geometry.vertices.buffer.length) // Use buffer length as version

                // Get or create the node
                if let existingNode = meshNodes[id] {
                    node = existingNode
                } else {
                    node = SCNNode()
                    meshNodes[id] = node
                    arView.scene.rootNode.addChildNode(node)
                    meshGeometryVersions[id] = -1 // Initialize version tracker
                }

                // ALWAYS update the node's position
                node.simdTransform = anchor.transform

                // ⭐️ CALCULATE DISTANCE from camera to anchor's center ⭐️
                let anchorPosition = simd_float3(anchor.transform.columns.3.x,
                                                anchor.transform.columns.3.y,
                                                anchor.transform.columns.3.z)
                let distanceToAnchor = simd_distance(cameraPosition, anchorPosition)

                // Determine if the node should be active based on distance
                let isActive = distanceToAnchor <= maxDisplayDistance

                // Determine if the node is within the camera's view frustum
                let isVisible = isActive && arView.isNode(node, insideFrustumOf: pointOfView)

                // Check if ARKit has provided updated geometry
                let geometryHasUpdated = meshGeometryVersions[id] != currentGeometryVersion

                // ⭐️ HIDE the node if it's too far away ⭐️
                node.isHidden = !isActive // Hide if beyond max distance

                // Regenerate geometry ONLY IF the node is active (within distance)
                // AND (it's visible OR its geometry has changed)
                if isActive && (isVisible || geometryHasUpdated) {
                    node.geometry = anchor.geometry.toSCNGeometry(
                        cameraPosition: cameraPosition,
                        anchorTransform: anchor.transform
                    )
                    meshGeometryVersions[id] = currentGeometryVersion
                }
                // If the node is inactive (too far), we hide it AND skip geometry update.
                // If active but not visible and geometry hasn't changed, we also skip update.
            }

            // --- CLEANUP ---
            // Remove nodes for anchors that ARKit itself has stopped tracking
            let currentIDs = Set(currentMeshAnchors.map { $0.identifier })
            let removedIDs = meshNodes.keys.filter { !currentIDs.contains($0) }

            for id in removedIDs {
                meshNodes[id]?.removeFromParentNode()
                meshNodes.removeValue(forKey: id)
                meshGeometryVersions.removeValue(forKey: id)
            }

        }
    }
}

// MARK: - ARMeshGeometry Extension
extension ARMeshGeometry {
    func toSCNGeometry(cameraPosition: simd_float3, anchorTransform: simd_float4x4) -> SCNGeometry {
        // Get vertex positions for distance calculation
        let vertexBuffer = vertices.buffer.contents()
        let vertexStride = vertices.stride
        let vertexOffset = vertices.offset
        let vertexCount = vertices.count
        
        var colors: [Float] = []
        colors.reserveCapacity(vertexCount * 3)
        
        for i in 0..<vertexCount {
            let vertexPointer = vertexBuffer.advanced(by: vertexOffset + (i * vertexStride))
            let vertex = vertexPointer.assumingMemoryBound(to: Float.self)
            
            // Get vertex in local space
            let localVertex = simd_float3(vertex[0], vertex[1], vertex[2])
            
            // Transform vertex to world space using anchor transform
            let worldVertex = simd_make_float3(anchorTransform * simd_float4(localVertex, 1.0))
            
            // Calculate distance from camera to vertex in world space
            let distance = simd_distance(cameraPosition, worldVertex)
            
            // Color gradient: red (close) -> yellow -> green (far)
            // 0-1m = red, 1-2m = yellow, 2m+ = green
            let r: Float
            let g: Float
            let b: Float
            
            if distance < 1.0 {
                // 0-1m: red to yellow
                r = 1.0
                g = distance // 0 to 1
                b = 0.0
            } else if distance < 2.0 {
                // 1-2m: yellow to green
                let t2 = distance - 1.0 // 0 to 1
                r = 1.0 - t2 // 1 to 0
                g = 1.0
                b = 0.0
            } else {
                // 2m+: pure green (capped, no white)
                r = 0.0
                g = 1.0
                b = 0.0
            }
            
            colors.append(r)
            colors.append(g)
            colors.append(b)
        }
        
        // Vertices
        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: .float3,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )
        
        // Colors
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        
        // Indices (faces)
        let indexData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        
        // Create geometry with vertex colors
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        
        // Material for WIREFRAME effect
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white // Will be multiplied by vertex colors
        mat.isDoubleSided = true
        mat.fillMode = .lines  // <--- THIS CREATES THE WIREFRAME!
        mat.lightingModel = .constant
        
        geometry.materials = [mat]
        
        return geometry
    }
}

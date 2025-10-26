//
//  ARViewContainer.swift
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



struct ARViewContainer: UIViewRepresentable {
    @Binding var distances: [String: Float]
    @Binding var lastTriggerTime: Date
    @Binding var tracks: [Track]

    let audioManager: SpatialAudioManager
    let webSocketManager: WebSocketManager // NEW: Accept the manager
    
    @Binding var imageResolution: CGSize
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.scene = SCNScene()
        arView.autoenablesDefaultLighting = true
        
        let config = ARWorldTrackingConfiguration()
        
        // This is crucial for performance and coordinate matching.
        // We find a 640x480 format and set the session to use it.
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.imageResolution.width == 640 && $0.imageResolution.height == 480
        }) {
            config.videoFormat = format
            print("✅ ARSession video format set to 640x480.")
        } else {
            print("⚠️ Could not find 640x480 format. Using default. Bounding boxes may be misaligned.")
        }

        // Enable mesh reconstruction for wireframe
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        // Enable depth for distance calculations
        config.frameSemantics = .sceneDepth
        config.environmentTexturing = .automatic
        
        arView.session.run(config)
        
        // Black background - wireframe only, no camera feed
        // arView.scene.background.contents = UIColor.black
        
        context.coordinator.arView = arView
        
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {        
        Coordinator(self, audioManager: audioManager, webSocketManager: webSocketManager)
    }
    
    class Coordinator: NSObject, ARSCNViewDelegate {
        var parent: ARViewContainer
        let audioManager: SpatialAudioManager
        let webSocketManager: WebSocketManager // NEW

        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
        
        weak var arView: ARSCNView?
        var meshNodes: [UUID: SCNNode] = [:]
        var meshGeometryVersions: [UUID: Int] = [:]
        
        // ⭐️ Define the maximum distance to keep wireframes visible/active ⭐️
        let maxDisplayDistance: Float = 6.0 // Meters (Adjust as needed)
        
        // Re-usable CIContext for performance
        private let ciContext = CIContext()
        private let jpegQuality: CGFloat = 0.7 // 70%
        private var hasSetResolution: Bool = false

        // ⭐️ Modified init
        init(_ parent: ARViewContainer, audioManager: SpatialAudioManager, webSocketManager: WebSocketManager) {
            self.parent = parent
            self.audioManager = audioManager
            self.webSocketManager = webSocketManager // NEW
            super.init()
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // 1. Get the current frame and camera's "point of view"
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let pointOfView = arView.pointOfView // Camera node
            else { return }
            
            // --- NEW: Update resolution binding (runs once) ---
            if !hasSetResolution, let format = arView.session.configuration?.videoFormat {
                // Update the binding on the main thread
                DispatchQueue.main.async {
                    self.parent.imageResolution = format.imageResolution
                    self.hasSetResolution = true
                    print("✅ Resolution source of truth set: \(format.imageResolution)")
                }
            }

            // --- WEBSOCKET FRAME SENDING ---
            let pixelBuffer = frame.capturedImage
            
            // Convert to JPEG and send.
            // The manager's 'isAwaitingResponse' lock will automatically
            // handle throttling, dropping frames if the server is busy.
            if let frameData = self.jpegData(from: pixelBuffer) {
                self.webSocketManager.sendFrame(frameData)
            }
            // --- END SEND FRAME ---
            
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

        private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            let properties: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality
            ]

            // We use ciContext.jpegRepresentation for better performance
            return ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: properties
            )
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

//
//  CameraManager.swift
//  EchoAI-client
//
//  Created by Jhoon Yi on 10/25/25.
//


import AVFoundation
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @Published var session = AVCaptureSession()
    @Published var error: Error?
    
    // This is the delegate that will receive the frame data
    weak var webSocketManager: WebSocketManager?
    
    private let sessionQueue = DispatchQueue(label: "com.example.sessionQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameRateTimer: Timer?
    
    // Configuration
    private let targetFPS: Double = 20.0
    private let jpegQuality: CGFloat = 0.7 // 70%
    
    override init() {
        super.init()
        setupSession()
    }
    
    func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .vga640x480 // Use a preset matching your Python script
            
            // 1. Input
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
                print("Failed to get camera device")
                return
            }
            
            if self.session.canAddInput(videoDeviceInput) {
                self.session.addInput(videoDeviceInput)
            }
            
            // 2. Output
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true // Don't buffer
            
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            
            self.session.commitConfiguration()
        }
    }
    
    func start() {
        print("Starting camera session...")
        sessionQueue.async {
            self.session.startRunning()
            
            // Use a timer to throttle frames to the target FPS
            DispatchQueue.main.async {
                self.frameRateTimer?.invalidate()
                self.frameRateTimer = Timer.scheduledTimer(
                    withTimeInterval: 1.0 / self.targetFPS,
                    repeats: true
                ) { [weak self] _ in
                    // This timer just ensures the 'captureOutput' delegate
                    // isn't firing *too* fast, though 'setSampleBufferDelegate'
                    // is the main driver. This logic might need refinement.
                    // For now, the main work is in captureOutput.
                }
            }
        }
    }
    
    func stop() {
        print("Stopping camera session...")
        sessionQueue.async {
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.frameRateTimer?.invalidate()
                self.frameRateTimer = nil
            }
        }
    }
    
    // This delegate function is called for EVERY frame
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // Convert the CMSampleBuffer to JPEG Data
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frameData = self.jpegData(from: imageBuffer) else {
            return
        }
        
        // Send the frame to our WebSocket manager
        webSocketManager?.sendFrame(frameData)
    }
    
    /// Converts a CVPixelBuffer (from the camera) to JPEG Data
    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        // Use UIImage to handle the JPEG conversion
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: self.jpegQuality)
    }
}

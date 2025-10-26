//
//  OCRWebSocketManager.swift
//  EchoAI-client
//
//  Created by Jhoon Yi on 10/26/25.
//

// OCRWebSocketManager.swift
import Foundation
import Combine

// --- Data models for the OCR server ---
private struct FrameMetadata: Codable {
    let frame_id: Int
    let do_ocr: Bool
}

private struct OCRResponse: Codable {
    let text: String?
    let latency_ms: Double?
}
// ----------------------------------------

class OCRWebSocketManager: ObservableObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)
    
    // ⚠️ Use your local/ngrok/etc. URL for the OCR server
    private let serverURL = URL(string: "wss://extras-registration-ate-everyday.trycloudflare.com/ws")! // change with cloudflare server
    private var frameId: Int = 0
    private var isAwaitingResponse: Bool = false
    
    // Published properties
    @Published var ocrText: String = ""
    @Published var latency: Double = 0.0
    @Published var isConnected: Bool = false
    
    init() {
        connect()
    }
    
    func connect() {
        guard !isConnected, webSocketTask == nil else { return }
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        isConnected = true
        isAwaitingResponse = false
        print("Connecting to OCR WebSocket at \(serverURL)...")
        listen()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        ocrText = ""
        print("Disconnected from OCR WebSocket.")
    }
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .failure(let error):
                print("❌ OCR WebSocket receive error: \(error.localizedDescription)")
                self.isConnected = false
                self.isAwaitingResponse = false
                self.webSocketTask = nil // Clear task
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.connect() // Attempt reconnect
                }
                
            case .success(let message):
                switch message {
                case .string(let text):
                    self.parseResponse(jsonString: text)
                case .data:
                    print("OCR WS: Received unexpected binary data")
                @unknown default:
                    fatalError()
                }
                self.listen() // Listen for the next message
            }
        }
    }
    
    private func parseResponse(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            let response = try JSONDecoder().decode(OCRResponse.self, from: data)
            
            DispatchQueue.main.async {
                // Only update if we got new text
                if let newText = response.text, !newText.isEmpty {
                    self.ocrText = newText
                }
                self.latency = response.latency_ms ?? 0.0
                self.isAwaitingResponse = false // Unlock
            }
        } catch {
            print("❌ OCR JSON Decoding Error: \(error.localizedDescription)")
            self.isAwaitingResponse = false // Unlock even on error
        }
    }
    
    /// Sends a frame. The `doOCR` flag tells the server if this is the frame to process.
    func sendFrame(_ frameData: Data, doOCR: Bool) {
        guard isConnected, let task = webSocketTask else {
            print("Cannot send OCR frame, not connected.")
            return
        }
        
        // This is the Python script's rate-limiting logic.
        // It's a 5FPS target, BUT it also waits for a response.
        // We'll just use the "wait for response" lock.
        guard !isAwaitingResponse else {
            // Dropping frame, awaiting server response...
            return
        }
        
        isAwaitingResponse = true
        
        // 1. Create JSON metadata
        let meta = FrameMetadata(frame_id: self.frameId, do_ocr: doOCR)
        guard let metaData = try? JSONEncoder().encode(meta),
              let metaString = String(data: metaData, encoding: .utf8) else {
            isAwaitingResponse = false
            return
        }
        
        // 2. Send JSON, then send Binary (just like Python script)
        task.send(.string(metaString)) { [weak self] error in
            if let error = error {
                print("❌ OCR WS Error sending metadata: \(error.localizedDescription)")
                self?.isAwaitingResponse = false // Unlock on send error
            } else {
                // Metadata sent, now send binary
                task.send(.data(frameData)) { [weak self] error in
                    if let error = error {
                        print("❌ OCR WS Error sending frame data: \(error.localizedDescription)")
                        self?.isAwaitingResponse = false // Unlock on send error
                    } else {
                        // Frame sent successfully. Lock remains until response.
                         print("Sent frame \(self?.frameId ?? 0) for OCR: \(doOCR)")
                    }
                }
            }
        }
        
        frameId += 1
    }
}

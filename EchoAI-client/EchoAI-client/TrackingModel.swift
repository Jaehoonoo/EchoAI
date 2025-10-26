//
//  ServerResponse.swift
//  EchoAI-client
//
//  Created by Jhoon Yi on 10/25/25.
//


import Foundation

// Matches the overall JSON response
struct ServerResponse: Codable {
    let tracks: [Track]
    let latencyMs: Double?
    let zone: Zone?
    
    // Match Python's 'latency_ms'
    enum CodingKeys: String, CodingKey {
        case tracks
        case latencyMs = "latency_ms"
        case zone
    }
}

// Matches a single tracked object
struct Track: Codable, Identifiable {
    let id: Int
    let bbox: [Double] // [x1, y1, x2, y2] - Use Double, as Python's map(int,..) implies they may be floats
    let label: String?
    let conf: Double?
    let priority: String?
    let predPath: [[Double]]? // Changed from 'predictions'
    
    enum CodingKeys: String, CodingKey {
        case id, bbox, label, conf, priority
        case predPath = "pred_path" // Maps 'pred_path' from JSON to 'predPath'
    }
}

// Matches the optional warning zone
struct Zone: Codable {
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int
}

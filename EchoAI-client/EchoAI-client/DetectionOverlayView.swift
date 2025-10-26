import SwiftUI

struct DetectionOverlayView: View {
    let tracks: [Track]
    
    // NEW: Receive the resolution from the parent view
    let imageResolution: CGSize
    
    // MODIFIED: These are now computed properties
    private var imageWidth: CGFloat {
        // Use max(1, ...) to avoid divide-by-zero if resolution is (0,0)
        max(1, imageResolution.width)
    }
    private var imageHeight: CGFloat {
        max(1, imageResolution.height)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ForEach(tracks) { track in
                // Draw one box, label, and path per track
                drawTrack(for: track, in: geometry.size)
            }
        }
    }
    
    /// Scales a point from image coordinates (640x480) to view coordinates.
    private func scalePoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint {
        // --- Coordinate Scaling Logic ---
        let scaleX = viewSize.width / imageWidth
        let scaleY = viewSize.height / imageHeight
        
        // Use the larger scale factor for 'fill'
        let scale = max(scaleX, scaleY)
        
        // Calculate offsets to center the 'filled' image
        let offsetX = (viewSize.width - (imageWidth * scale)) / 2.0
        let offsetY = (viewSize.height - (imageHeight * scale)) / 2.0
        
        let scaledX = (point.x * scale) + offsetX
        let scaledY = (point.y * scale) + offsetY
        
        return CGPoint(x: scaledX, y: scaledY)
    }
    
    /// Helper function to draw a single track (box, label, and path)
    @ViewBuilder
    private func drawTrack(for track: Track, in viewSize: CGSize) -> some View {
        
        // Scale the bbox points
        let p1 = scalePoint(CGPoint(x: track.bbox[0], y: track.bbox[1]), in: viewSize)
        let p2 = scalePoint(CGPoint(x: track.bbox[2], y: track.bbox[3]), in: viewSize)

        let width = p2.x - p1.x
        let height = p2.y - p1.y
        let midX = p1.x + (width / 2)

        // Determine color based on priority
        let color = (track.priority == "high") ? Color.red : (track.priority == "medium" ? Color.yellow : Color.green)

        // Draw the box
        Rectangle()
            .stroke(color, lineWidth: 2)
            .frame(width: width, height: height)
            .position(x: midX, y: p1.y + (height / 2))
        
        // Draw the label
        Text("ID:\(track.id) \(track.label ?? "obj")")
            .font(.system(size: 12, weight: .semibold))
            .padding(2)
            .background(color)
            .foregroundColor(.black)
            .position(x: midX, y: p1.y - 10) // Position above the box
        
        // Draw prediction path
        if let predPath = track.predPath, predPath.count >= 2 {
            Path { path in
                guard let firstRawPoint = predPath.first else { return }
                let firstPoint = scalePoint(CGPoint(x: firstRawPoint[0], y: firstRawPoint[1]), in: viewSize)
                path.move(to: firstPoint)
                
                for point in predPath.dropFirst() {
                    let scaledP = scalePoint(CGPoint(x: point[0], y: point[1]), in: viewSize)
                    path.addLine(to: scaledP)
                }
            }
            .stroke(Color.cyan, lineWidth: 2)
        }
    }
}

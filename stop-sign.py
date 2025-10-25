import cv2
import numpy as np
import torch
from pathlib import Path
from boxmot import DeepOcSort
from ultralytics import YOLO

# Initialize YOLO detector
yolo_model = YOLO("yolov10n.pt")

# Initialize tracker
tracker = DeepOcSort(
    reid_weights=Path("osnet_x0_25_msmt17.pt"),
    device="0" if torch.cuda.is_available() else "cpu",
    half=False,
)

# Start webcam
cap = cv2.VideoCapture(1)

# Prediction parameters
N_FRAMES_AHEAD = 30  # Predict ~1 second ahead at 30 FPS


def get_yolo_detections(frame):
    """Run YOLO detection and format results for tracker."""
    results = yolo_model(frame, verbose=False)
    detections = []

    for r in results:
        boxes = r.boxes
        for box in boxes:
            x1, y1, x2, y2 = box.xyxy[0].cpu().numpy()
            conf = box.conf[0].cpu().numpy()
            cls = box.cls[0].cpu().numpy()
            detections.append([x1, y1, x2, y2, conf, cls])

    return np.array(detections) if detections else np.empty((0, 6))


print("Starting motion intent prediction...")
print("Press 'q' to quit")

while True:
    ret, frame = cap.read()
    if not ret:
        break

    # Get YOLO detections
    detections = get_yolo_detections(frame)

    # Update tracker with detections
    tracks = tracker.update(detections, frame)

    # --- MOTION INTENT PREDICTION ---
    future_predictions = {}

    for track in tracker.active_tracks:
        track_id = track.id

        # Access Kalman filter and current state
        kf = track.kf

        ## --- FIX: Save the original state ---
        original_x = kf.x.copy()
        original_P = kf.P.copy()

        current_mean = track.kf.x.copy()
        current_covariance = track.kf.P.copy()

        predicted_path = []

        # Predict future positions by repeatedly calling predict()
        for _ in range(N_FRAMES_AHEAD):
            # Predict next state
            kf.predict()
            current_mean = kf.x.copy()
            current_covariance = kf.P.copy()

            # Extract center position (x, y) from state vector
            # For DeepOcSort: state is [x, y, s, r, vx, vy, vs]
            predicted_x = int(kf.x[0])
            predicted_y = int(kf.x[1])

            # Clamp to frame boundaries
            predicted_x = max(0, min(frame.shape[1], predicted_x))
            predicted_y = max(0, min(frame.shape[0], predicted_y))

            predicted_path.append((predicted_x, predicted_y))

        # Restore original state (since we modified it during prediction)
        kf.x = original_x
        kf.P = original_P

        future_predictions[track_id] = predicted_path

    # Visualize: Draw historical trajectories (blue)
    annotated_frame = tracker.plot_results(frame, show_trajectories=True)

    # Draw predicted trajectories (green)
    for track_id, path in future_predictions.items():
        if len(path) > 1:
            for i in range(len(path) - 1):
                cv2.line(
                    annotated_frame,
                    path[i],
                    path[i + 1],
                    (0, 255, 0),  # Green for future predictions
                    2,
                )
            # Draw endpoint circle
            cv2.circle(annotated_frame, path[-1], 5, (0, 255, 0), -1)

    # Display
    cv2.imshow("Motion Intent Prediction", annotated_frame)

    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cap.release()
cv2.destroyAllWindows()
print("Stopped.")

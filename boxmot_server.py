import json, time
from typing import List, Dict, Any, Tuple
import numpy as np
import cv2

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware

from ultralytics import YOLO
from boxmot import DeepOcSort  # Use DeepOcSort as specified
from pathlib import Path
import torch

# =========================
# Utility helpers (No changes needed)
# =========================
def clamp_box_xyxy(b, w, h):
    x1, y1, x2, y2 = b
    x1 = max(0.0, min(float(x1), w - 1))
    y1 = max(0.0, min(float(y1), h - 1))
    x2 = max(0.0, min(float(x2), w - 1))
    y2 = max(0.0, min(float(y2), h - 1))
    return [x1, y1, x2, y2]

def rect_overlap(a, b) -> bool:
    x1 = max(a[0], b[0]); y1 = max(a[1], b[1])
    x2 = min(a[2], b[2]); y2 = min(a[3], b[3])
    return (x2 - x1) > 0 and (y2 - y1) > 0

def tlwh_to_xyxy(x, y, w, h):
    return [x, y, x + w, y + h]

def tlbr_to_xyxy(tlbr):
    return [float(tlbr[0]), float(tlbr[1]), float(tlbr[2]), float(tlbr[3])]

def xyxy_from_xysr(x, y, s, r):
    w = float(np.sqrt(max(1e-6, s * max(1e-6, r))))
    h = float(np.sqrt(max(1e-6, s / max(1e-6, r))))
    x1 = x - 0.5 * w
    y1 = y - 0.5 * h
    x2 = x + 0.5 * w
    y2 = y + 0.5 * h
    return [x1, y1, x2, y2]

def predicted_point_overlaps_zone(center_point, estimated_width, zone_rect):
    # ... (Keep this function as defined previously) ...
    px, py = center_point
    radius = estimated_width / 2.0 # Approximate radius
    rx1, ry1, rx2, ry2 = zone_rect
    closest_x = max(rx1, min(px, rx2))
    closest_y = max(ry1, min(py, ry2))
    distance_x = px - closest_x
    distance_y = py - closest_y
    distance_squared = (distance_x ** 2) + (distance_y ** 2)
    return distance_squared < (radius ** 2)

# =========================
# App + models + tracker
# =========================
ALLOWED_CLASSES = {
    1: u"person",
    2: u'bicycle',
    3: u'car',
    4: u'motorcycle',
    6: u'bus',
    7: u'train',
    8: u'truck',
    9: u'boat',
    10: u'traffic light',
    11: u'fire hydrant',
    # stop sign?
    12: u'stop sign',
    13: u'parking meter',
    14: u'bench',
    15: u'bird',
    16: u'cat',
    17: u'dog',
    25: u'backpack',
    26: u'umbrella',
    27: u'handbag',
    57: u'chair',
}

app = FastAPI(title="YOLOv11 + BoxMOT DeepOcSort (WebSocket)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"]
)

# Detector
YOLO_WEIGHTS = "yolo11m.pt"
YOLO_CONF = 0.5 # Define confidence threshold
YOLO_IMG_SZ = 640 # Define image size

try:
    model = YOLO(YOLO_WEIGHTS)
except Exception:
    print(f"Could not load {YOLO_WEIGHTS}, falling back to yolov8n.pt")
    model = YOLO("yolov8n.pt") 

# Warmup to trigger weight load
_dummy = np.zeros((YOLO_IMG_SZ, YOLO_IMG_SZ, 3), dtype=np.uint8)
_ = model.predict(_dummy, imgsz=YOLO_IMG_SZ, conf=YOLO_CONF, verbose=False)
print("Model loaded and warmed up.")

def make_tracker():
    return DeepOcSort(
        reid_weights=Path("osnet_x0_25_msmt17.pt"),
        device="0" if torch.cuda.is_available() else "cpu",
        half=False,
        n_init=3,
        max_age=10,
    )

# Prediction horizon + zone config
PREDICT_K = 10   # future steps to simulate from KF
ZONE_Y1, ZONE_Y2 = 0.60, 1.00
ZONE_X1, ZONE_X2 = 0.20, 0.80

@app.get("/", response_class=PlainTextResponse)
def root():
    return "BoxMOT DeepOcSort WebSocket server running at /ws"

@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        tracker = make_tracker()

        while True:
            message_bytes = await websocket.receive_bytes()

            if len(message_bytes) < 8:
                print(f"Received invalid message (too short). only {len(message_bytes)} bytes")
                continue

            frame_id = int.from_bytes(message_bytes[:8], 'little') 
            jpg_bytes = message_bytes[8:]   

            frame = cv2.imdecode(np.frombuffer(jpg_bytes, np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                await websocket.send_text(json.dumps({"frame_id": frame_id, "error": "decode_failed"}))
                continue

            h, w = frame.shape[:2]
            t0 = time.time()
            
            # FIX: Pass consistent parameters to the model
            yres = model(
                frame, 
                verbose=False, 
                conf=YOLO_CONF, 
                # imgsz=YOLO_IMG_SZ
            )
            
            # FIX: Efficiently get detections as a single NumPy array
            # This replaces the manual for-loop
            if yres and hasattr(yres[0], "boxes") and len(yres[0].boxes.data) > 0:
                dets = yres[0].boxes.data.cpu().numpy() # [x1, y1, x2, y2, conf, cls]
                # Ensure it's a contiguous float32 array as required by boxmot
                dets = np.ascontiguousarray(dets, dtype=np.float32)
            else:
                dets = np.empty((0, 6), dtype=np.float32)


            # -------------------
            # 2) Update tracker
            # -------------------
            current_tracks_data = tracker.update(dets, frame)
            
            zx1 = int(ZONE_X1 * w); zx2 = int(ZONE_X2 * w)
            zy1 = int(ZONE_Y1 * h); zy2 = int(ZONE_Y2 * h)
            zone_rect = [zx1, zy1, zx2, zy2]

            out_tracks = []
            
            active = list(getattr(tracker, "active_tracks", []))
            
            print('processing frame: ', frame_id)

            for trk in active:
                if not trk.history_observations:
                    continue
                if len(trk.history_observations) < 3:
                    continue
                box = trk.history_observations[-1]

                print('determined class',trk.cls)
                predicted_class = int(trk.cls) + 1
                if predicted_class not in ALLOWED_CLASSES:
                    # skip predictions for these
                    continue

                x1, y1, x2, y2 = box[0], box[1], box[2], box[3]

                bbox_now = clamp_box_xyxy([x1, y1, x2, y2], w, h)
                x1, y1, x2, y2 = map(int, bbox_now) # Re-assign after clamping

                track_id = int(getattr(trk, "id", getattr(trk, "track_id", -1)))
                
                # FIX: Safely handle NoneType for confidence
                # This prevents the TypeError we discussed previously.
                det_conf_val = getattr(trk, "det_conf", 1.0)
                conf = float(det_conf_val) if det_conf_val is not None else 0.0

                label = ALLOWED_CLASSES.get(predicted_class, "obj")

                pred_path = []
                pred_widths = []
                current_center_x, current_center_y = 0.0, 0.0
                vx = 0.0
                vy = 0.0
                direction = "unknown"

                if hasattr(trk, "kf") and hasattr(trk.kf, "x") and hasattr(trk.kf, "P"):
                    current_mean = trk.kf.x.copy()
                    if len(current_mean) >= 6: # Check if state includes velocity
                        current_center_x = float(current_mean[0])
                        current_center_y = float(current_mean[1])
                        vx = float(current_mean[4])
                        vy = float(current_mean[5])

                        # Determine direction based on current velocity
                        velocity_threshold = 1.0 # Pixels per frame threshold
                        if vx > velocity_threshold: 
                            direction = "right"
                        elif vx < -velocity_threshold: 
                            direction = "left"
                        else: 
                            direction = "straight" # Simplified horizontal direction
                    
                    X0, P0 = trk.kf.x.copy(), trk.kf.P.copy()

                    # FIX: Use the PREDICT_K constant, not a magic number (30)
                    for _ in range(PREDICT_K): 
                        trk.kf.predict()
                        current_mean = trk.kf.x.copy()
                        current_cov = trk.kf.P.copy()

                        # Extract center position (x, y) from state vector
                        # For DeepOcSort: state is [x, y, s, r, vx, vy, vs]
                        pred_x = int(trk.kf.x[0])
                        pred_y = int(trk.kf.x[1])

                        # Clamp to frame boundaries
                        pred_x = max(0, min(frame.shape[1], pred_x))
                        pred_y = max(0, min(frame.shape[0], pred_y))

                        pred_s = max(1e-3, float(trk.kf.x[2]))
                        pred_r = max(1e-3, float(trk.kf.x[3]))
                        pred_w = float(np.sqrt(pred_s * pred_r))

                        pred_path.append((pred_x, pred_y))
                        pred_widths.append(pred_w)

                    # restore KF state
                    trk.kf.x, trk.kf.P = X0, P0

                # --- Refined Prioritization Logic ---
                crosses = False
                soon = False
                first_cross_step = -1
                moving_towards_zone = False # New flag based on velocity

                # Check if currently moving towards the zone
                # (only if the object is currently outside the zone horizontally)
                if current_center_x < zx1 and vx > 0: # Left of zone, moving right
                    moving_towards_zone = True
                elif current_center_x > zx2 and vx < 0: # Right of zone, moving left
                    moving_towards_zone = True
                elif zx1 <= current_center_x <= zx2: # Already inside zone horizontally
                        moving_towards_zone = True # Treat as moving towards/within

                # Check predicted path overlap
                for i in range(len(pred_path)):
                        point = pred_path[i]
                        est_width = pred_widths[i] if i < len(pred_widths) else (bbox_now[2]-bbox_now[0])
                        if predicted_point_overlaps_zone(point, est_width, zone_rect):
                            crosses = True
                            if first_cross_step == -1: first_cross_step = i
                            if i < 5: soon = True
                            if soon: break

                # Nearness check (same as before)
                area = max(1, (bbox_now[2] - bbox_now[0]) * (bbox_now[3] - bbox_now[1]))
                near = area >= 0.08 * (w * h)

                # --- Assign Priority using Velocity ---
                priority = "none" # Default to none
                if crosses:
                    if near and soon and moving_towards_zone:
                        priority = "high"
                    elif soon and moving_towards_zone:
                            priority = "medium"
                    elif moving_towards_zone: # Crosses eventually, moving towards
                            priority = "low"
                    # else: # Crosses but moving away -> priority remains "none"
                    # --- End Priority Assignment ---

                out_tracks.append({
                    "id": track_id,
                    "label": label,
                    "conf": round(conf, 3),
                    "bbox": bbox_now,            
                    "pred_path": pred_path,
                    "priority": priority,

                    "direction": direction, # Add the calculated direction
                    "vx": round(vx, 2),     # Optional: send velocity values
                    "vy": round(vy, 2)      # Optional: send velocity values
                })
            
            # This print is helpful for debugging
            # print(f'Frame {frame_id}: Found {len(out_tracks)} tracks.')
            
            resp = {
                "frame_id": frame_id,
                "zone": {"x1": zone_rect[0], "y1": zone_rect[1],
                         "x2": zone_rect[2], "y2": zone_rect[3]},
                "tracks": out_tracks,
                "latency_ms": int((time.time() - t0) * 1000)
            }
            await websocket.send_text(json.dumps(resp))

    except WebSocketDisconnect:
        print("Client disconnected.")
    except Exception as e:
        print(f"An error occurred: {e}")
        try:
            # Try to send a final error message
            await websocket.send_text(json.dumps({"error": str(e)}))
        except Exception:
            pass # Connection might be closed already

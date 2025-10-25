# server.py
import json, time, math
from typing import List, Dict, Any, Tuple
import cv2, numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware

from ultralytics import YOLO
from deep_sort_realtime.deepsort_tracker import DeepSort  # <-- DeepSORT
import torch

# -----------------------------
# Small utilities
# -----------------------------
def bbox_to_center(b: np.ndarray) -> Tuple[float,float,float,float]:
    w = max(1.0, b[2] - b[0]); h = max(1.0, b[3] - b[1])
    cx = b[0] + 0.5 * w; cy = b[1] + 0.5 * h
    return cx, cy, w, h

def center_to_bbox(cx, cy, w, h) -> np.ndarray:
    return np.array([cx - 0.5*w, cy - 0.5*h, cx + 0.5*w, cy + 0.5*h], dtype=np.float32)

def rect_overlap(a, b) -> bool:
    x1 = max(a[0], b[0]); y1 = max(a[1], b[1])
    x2 = min(a[2], b[2]); y2 = min(a[3], b[3])
    return (x2 - x1) > 0 and (y2 - y1) > 0

# -----------------------------
# Constant-velocity Kalman (center x,y)
# -----------------------------
class KalmanCV2D:
    # State: [x, y, vx, vy]^T ; Measurement: [x, y]^T
    def __init__(self, dt=0.1, proc_var=5.0, meas_var=25.0):
        self.dt = dt
        self.F = np.array([[1,0,dt,0],[0,1,0,dt],[0,0,1,0],[0,0,0,1]], dtype=np.float32)
        self.H = np.array([[1,0,0,0],[0,1,0,0]], dtype=np.float32)
        self.Q = np.eye(4, dtype=np.float32) * proc_var
        self.R = np.eye(2, dtype=np.float32) * meas_var
        self.x = np.zeros((4,1), dtype=np.float32)
        self.P = np.eye(4, dtype=np.float32) * 1000.0
        self.inited = False

    def set_dt(self, dt: float):
        self.dt = float(dt)
        self.F = np.array([[1,0,dt,0],[0,1,0,dt],[0,0,1,0],[0,0,0,1]], dtype=np.float32)

    def init(self, x, y):
        self.x[:] = np.array([[x],[y],[0],[0]], dtype=np.float32)
        self.P = np.eye(4, dtype=np.float32) * 100.0
        self.inited = True

    def predict(self):
        self.x = self.F @ self.x
        self.P = self.F @ self.P @ self.F.T + self.Q
        return self.x.copy(), self.P.copy()

    def update(self, z: np.ndarray):
        S = self.H @ self.P @ self.H.T + self.R
        K = self.P @ self.H.T @ np.linalg.inv(S)
        y = z.reshape(2,1) - (self.H @ self.x)
        self.x = self.x + K @ y
        I = np.eye(4, dtype=np.float32)
        self.P = (I - K @ self.H) @ self.P
        return self.x.copy(), self.P.copy()

# -----------------------------
# App + models + trackers
# -----------------------------
app = FastAPI(title="YOLO + DeepSORT + KF predictions (WebSocket)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"]
)

DEVICE = 'cuda' if torch.cuda.is_available() else 'cpu' 
print(f"Using device: {DEVICE}")
MODEL_PATH = "yolov8n.pt"
model = YOLO(MODEL_PATH).to(DEVICE)

# Warm up (download weights on first run)
_dummy = np.zeros((640, 640, 3), dtype=np.uint8)
_ = model.predict(source=_dummy, imgsz=640, conf=0.25, verbose=False)

# DeepSORT tracker
# embedder options: "mobilenet" (OpenCV dnn), "torchreid" (heavier, best re-id), None (IoU only)
deepsort = DeepSort(
    max_age=30,
    n_init=3,
    nms_max_overlap=0.7,
    max_cosine_distance=0.4,
    embedder="mobilenet",          # good hackathon default
    bgr=True,                      # frames are BGR (OpenCV)
    embedder_gpu=(DEVICE == 'cuda')             # set True if you want to push embedder to GPU (torch needed)
)

# Per-track Kalman store {track_id: (KF, (w,h))}
track_kf: Dict[int, Tuple[KalmanCV2D, Tuple[float,float]]] = {}

# Prediction horizon and zone
PREDICT_K = 10
ZONE_Y1, ZONE_Y2 = 0.60, 1.00
ZONE_X1, ZONE_X2 = 0.20, 0.80

@app.get("/", response_class=PlainTextResponse)
def root():
    return "YOLO DeepSORT server running. Connect via WebSocket at /ws"

@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    await websocket.accept()
    last_ts = time.time()
    try:
        while True:
            meta_text = await websocket.receive_text()
            meta = json.loads(meta_text)
            frame_id = meta.get("frame_id", None)

            msg = await websocket.receive()
            if "bytes" not in msg:
                await websocket.send_text(json.dumps({"frame_id": frame_id, "error": "expected_binary_frame"}))
                continue

            jpg_bytes = msg["bytes"]
            frame = cv2.imdecode(np.frombuffer(jpg_bytes, np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                await websocket.send_text(json.dumps({"frame_id": frame_id, "error": "decode_failed"}))
                continue

            h, w = frame.shape[:2]
            t0 = time.time()
            yolo_out = model.predict(source=frame, imgsz=640, conf=0.25, verbose=False)

            dets = []  # each: [ [x1,y1,x2,y2], conf, class_id ]
            names = None
            for r in yolo_out:
                names = r.names
                if getattr(r, "boxes", None) is None:
                    continue
                for b in r.boxes:
                    xyxy = b.xyxy[0].tolist()
                    x1, y1, x2, y2 = map(float, xyxy)
                    # clamp
                    x1 = max(0.0, min(x1, w-1)); y1 = max(0.0, min(y1, h-1))
                    x2 = max(0.0, min(x2, w-1)); y2 = max(0.0, min(y2, h-1))
                    conf = float(b.conf[0]) if b.conf is not None else 0.0
                    cls_id = int(b.cls[0]) if b.cls is not None else -1
                    dets.append(([x1, y1, x2, y2], conf, cls_id))

            # Update DeepSORT
            tracks = deepsort.update_tracks(dets, frame=frame)  # returns list of Track objects

            # adapt KF dt to actual frame interval
            now = time.time()
            dt = max(1e-3, now - last_ts)
            last_ts = now

            # Zone rectangle
            zx1 = int(ZONE_X1 * w); zx2 = int(ZONE_X2 * w)
            zy1 = int(ZONE_Y1 * h); zy2 = int(ZONE_Y2 * h)
            zone_rect = np.array([zx1, zy1, zx2, zy2], dtype=np.int32)

            out_tracks = []

            for trk in tracks:
                if not trk.is_confirmed():
                    continue
                tlbr = trk.to_tlbr()  # [x1,y1,x2,y2]
                bx = np.array(tlbr, dtype=np.float32)
                cx, cy, bw, bh = bbox_to_center(bx)

                # label/conf if available
                label = str(trk.get_det_class()) if hasattr(trk, "get_det_class") else "obj"

                det_conf = getattr(trk, "det_conf", 1.0)
                conf = float(det_conf) if det_conf is not None else 0.0

                # Maintain per-ID KF
                if trk.track_id not in track_kf:
                    kf = KalmanCV2D(dt=dt, proc_var=5.0, meas_var=25.0)
                    kf.init(cx, cy)
                    track_kf[trk.track_id] = (kf, (bw, bh))
                kf, (pw, ph) = track_kf[trk.track_id]
                kf.set_dt(dt)
                # predict then update with current center
                kf.predict()
                kf.update(np.array([cx, cy], dtype=np.float32))
                track_kf[trk.track_id] = (kf, (bw, bh))  # store latest size

                # Build future predictions by simulating K predicts on a copy
                preds = []
                x_save, P_save = kf.x.copy(), kf.P.copy()
                for _ in range(PREDICT_K):
                    pred_x, _ = kf.predict()
                    pcx, pcy = float(pred_x[0,0]), float(pred_x[1,0])
                    pb = center_to_bbox(pcx, pcy, bw, bh).astype(int)
                    preds.append(pb.tolist())
                # restore state (we only predicted "virtually")
                kf.x, kf.P = x_save, P_save

                # Zone crossing / priority
                crosses = any(rect_overlap(p, zone_rect) for p in preds)
                area = (bx[2]-bx[0]) * (bx[3]-bx[1])
                near = area >= 0.08 * (w*h)
                soon = any(i < 5 and rect_overlap(preds[i], zone_rect) for i in range(min(5, len(preds))))
                if crosses and near and soon:
                    priority = "high"
                elif crosses:
                    priority = "medium"
                else:
                    priority = "low"

                out_tracks.append({
                    "id": int(trk.track_id),
                    "label": label,
                    "conf": round(conf, 3),
                    "bbox": [int(bx[0]), int(bx[1]), int(bx[2]), int(bx[3])],
                    "predictions": preds,
                    "zone_cross": bool(crosses),
                    "priority": priority
                })

            resp = {
                "frame_id": frame_id,
                "zone": {"x1": int(zone_rect[0]), "y1": int(zone_rect[1]),
                         "x2": int(zone_rect[2]), "y2": int(zone_rect[3])},
                "tracks": out_tracks,
                "latency_ms": int((time.time() - t0) * 1000)
            }
            await websocket.send_text(json.dumps(resp))

    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await websocket.send_text(json.dumps({"error": str(e)}))
        except Exception:
            pass
        raise


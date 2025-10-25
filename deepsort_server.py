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

import pytesseract
import Levenshtein
from collections import deque
from datetime import datetime

try:
    pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'
except Exception:
    print("Warning: Tesseract executable path not found. OCR will fail.")
    print("Please edit server.py to set the correct 'pytesseract.pytesseract.tesseract_cmd' path.")

class Linguist:
    @staticmethod
    def language_string(language_code):
        if language_code == 'eng':
            return "English"
        elif language_code:
            return language_code
        return "English (Default)"

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

OCR_INTERVAL = 0.2  # Run OCR every 0.2 seconds (5 FPS)
OCR_LANGUAGE = 'eng'
OCR_CROP_PERCENT_X = 0.2 # Crop 20% from left/right
OCR_CROP_PERCENT_Y = 0.2 # Crop 20% from top/bottom
LAST_OCR_TIME = 0.0
ocr_processor = OCR()

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

           # ...
            h, w = frame.shape[:2]
            
            # --- NEW: RUN OCR ---
            global LAST_OCR_TIME
            ocr_results = {
                "stable": ocr_processor.is_stable,
                "stable_text": ocr_processor.stable_text,
                "boxes": [],
                "crop_rect": [0,0,0,0]
            }
            
            # Define the crop rectangle in pixels
            cx1 = int(w * OCR_CROP_PERCENT_X)
            cx2 = int(w * (1.0 - OCR_CROP_PERCENT_X))
            cy1 = int(h * OCR_CROP_PERCENT_Y)
            cy2 = int(h * (1.0 - OCR_CROP_PERCENT_Y))
            crop_rect_pixels = (cx1, cy1, cx2, cy2)
            ocr_results["crop_rect"] = crop_rect_pixels # Send to client for drawing
            
            current_time = time.time()
            if (current_time - LAST_OCR_TIME) >= OCR_INTERVAL:
                ocr_processor.process_frame(frame, crop_rect_pixels, lang=OCR_LANGUAGE)
                LAST_OCR_TIME = current_time

            # Get the latest results (even if we didn't run this frame)
            ocr_results["stable"] = ocr_processor.is_stable
            ocr_results["stable_text"] = ocr_processor.stable_text
            ocr_results["boxes"] = ocr_processor.parsed_boxes
            # --- END OF OCR ---
            
            t0 = time.time()
            yolo_out = model.predict(source=frame, imgsz=640, conf=0.25, verbose=False)
            # ...

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
                "ocr": ocr_results,  # <--- ADD THIS
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



class OCR:
    """
    Refactored class to perform OCR processing on-demand per frame.
    It no longer runs in its own thread.
    """
    def __init__(self, history_len=10, grace_period=15, stability_thresh=0.6):
        self.text_history = deque(maxlen=history_len)
        self.stable_text = ""
        self.is_stable = False
        self.instability_counter = 0
        self.parsed_boxes = [] # Will store clean box data: [x, y, w, h, conf, word]

        self.GRACE_PERIOD_FRAMES = grace_period
        self.STABILITY_THRESHOLD = stability_thresh
    
    def start(self):
        """Creates a thread targeted at the ocr process"""
        Thread(target=self.ocr, args=()).start()
        return self

    def set_exchange(self, video_stream):
        """Sets the self.exchange attribute with a reference to VideoStream class"""
        self.exchange = video_stream

    def set_language(self, language):
        """Sets the self.language parameter"""
        self.language = language

    def set_dimensions(self, width, height, crop_width, crop_height):
        """Sets the dimensions attributes"""
        self.width = width
        self.height = height
        self.crop_width = crop_width
        self.crop_height = crop_height

    def stop_process(self):
        """Sets the self.stopped attribute to True"""
        self.stopped = True

    def _clean_text(self, raw_text):
        """Removes common OCR junk (spaces, newlines) for better comparison."""
        return " ".join(raw_text.split()).strip()

    def _check_stability(self):
        if len(self.text_history) < self.text_history.maxlen:
            self.is_stable = False
            return False

        current_text = self.text_history[0]
        mid_text = self.text_history[int(self.text_history.maxlen / 2)]
        old_text = self.text_history[-1]

        ratio1 = Levenshtein.ratio(current_text, mid_text)
        ratio2 = Levenshtein.ratio(current_text, old_text)

        if ratio1 > self.STABILITY_THRESHOLD and ratio2 > self.STABILITY_THRESHOLD:
            self.instability_counter = 0
            if not self.is_stable:
                self.is_stable = True
                # Find the best text from the history
                best_text = max(self.text_history, key=len)
                self.stable_text = best_text
            return True
        else:
            self.instability_counter += 1
            if self.is_stable:
                if self.instability_counter > self.GRACE_PERIOD_FRAMES:
                    self.is_stable = False
                    self.instability_counter = 0
                    self.text_history.clear()
                    return False
                else:
                    return True # Lie and say we are stable during grace period
            else:
                return False
        
    def ocr(self):
        """
        The core OCR process that runs in a separate thread.
        Performs temporal sampling and stability checks.
        """
        LAST_OCR_TIME = time.time()
        OCR_INTERVAL = 0.2  # Time in seconds between OCR runs (5 runs/sec)

        while not self.stopped:
            if self.exchange is None:
                time.sleep(0.1)
                continue

            frame = self.exchange.frame
            if frame is None:
                continue
                
            current_time = time.time()

            # 1. TEMPORAL SAMPLING: Only run OCR if the time interval has passed
            if (current_time - LAST_OCR_TIME) >= OCR_INTERVAL:
                
                # Pre-processing and Cropping (Optimized)
                try:
                    cropped_frame = frame[self.crop_height:(self.height - self.crop_height),
                                          self.crop_width:(self.width - self.crop_width)]
                except TypeError:
                    # Frame dimensions might not be set on the first loop
                    continue 

                gray = cv2.cvtColor(cropped_frame, cv2.COLOR_BGR2GRAY) 
                _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)

                # Tesseract processing
                # Get raw string for stability check
                raw_output = pytesseract.image_to_string(
                    binary, 
                    lang=self.language,
                    config='--oem 1 --psm 6'  # Use fast LSTM engine, assume single block of text
                )
                
                # Get boxes for visualization
                self.boxes = pytesseract.image_to_data(binary, lang=self.language, config='--oem 1 --psm 6')
                
                # Store the cleaned text for stability checking
                cleaned_text = self._clean_text(raw_output)
                if len(cleaned_text) > 5: # Ignore very short/empty results
                    self.text_history.appendleft(cleaned_text) # Add to the front of the buffer

                # 2. STABILITY CHECK: Check the history for a stable reading
                self._check_stability()
                
                LAST_OCR_TIME = current_time # Update the time of the last successful run

            else:
                # Give up the processor for a moment to let other threads run
                time.sleep(0.001)

    def process_frame(self, frame: np.ndarray, crop_rect: Tuple[int,int,int,int], lang='eng'):
        """
        Runs one cycle of OCR processing on the given frame.
        """
        x1, y1, x2, y2 = crop_rect
        
        try:
            cropped_frame = frame[y1:y2, x1:x2]
            gray = cv2.cvtColor(cropped_frame, cv2.COLOR_BGR_GRAY)
            _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)
        except Exception as e:
            # print(f"OCR crop/preprocess error: {e}")
            self.parsed_boxes = []
            return # Failed to crop, maybe frame size is wrong

        # 1. Get raw string for stability check
        raw_output = pytesseract.image_to_string(
            binary, 
            lang=lang,
            config='--oem 1 --psm 6'
        )
        
        # 2. Get boxes for visualization
        boxes_data = pytesseract.image_to_data(binary, lang=lang, config='--oem 1 --psm 6')

        # 3. Store cleaned text for stability checking
        cleaned_text = self._clean_text(raw_output)
        if len(cleaned_text) > 5:
            self.text_history.appendleft(cleaned_text)

        # 4. Run stability check
        self._check_stability()
        
        # 5. Parse boxes and store them (using logic from your 'put_ocr_boxes')
        self.parsed_boxes = []
        if boxes_data is not None:
            for i, box_line in enumerate(boxes_data.splitlines()):
                box = box_line.split()
                if i != 0 and len(box) == 12:
                    try:
                        conf = int(float(box[10]))
                        if conf == -1: continue # Skip blocks
                        
                        x, y, w, h = int(box[6]), int(box[7]), int(box[8]), int(box[9])
                        word = box[11]
                        
                        # Adjust box coordinates to full frame (add crop offset)
                        x_full = x + x1
                        y_full = y + y1
                        
                        self.parsed_boxes.append([x_full, y_full, w, h, conf, word])
                    except ValueError:
                        pass


def views(mode: int, confidence: int):
    """
    View modes changes the style of text-boxing in OCR.
    """
    conf_thresh = 0
    color = (0, 0, 255) # Red (Default)

    if mode == 1:
        conf_thresh = 75     # Only shows boxes with confidence greater than 75
        color = (0, 255, 0)  # Green
    elif mode == 2:
        conf_thresh = 0      # Will show every box
        color = (0, 255, 0) if confidence >= 50 else (0, 0, 255) # Green/Red
    elif mode == 3:
        conf_thresh = 0      # Will show every box
        color = (int(confidence * 2.55), int(confidence * 2.55), 0) # Blue/Green gradient
    elif mode == 4:
        conf_thresh = 0      # Will show every box
        color = (0, 0, 255)  # Red

    return conf_thresh, color

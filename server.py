
# server.py
# FastAPI + WebSocket YOLO inference server
# Usage: python -m uvicorn server:app --host 0.0.0.0 --port 8000
import json
import asyncio
from typing import List, Dict, Any

import cv2
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware

import time, logging

try:
    from ultralytics import YOLO
except Exception as e:
    raise RuntimeError("Ultralytics YOLO is required. Install with: pip install ultralytics") from e

app = FastAPI(title="YOLO Streaming Inference Server")

# Optional CORS (not strictly needed for WS, but fine to enable for future REST endpoints)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Load a small model by default; change to yolov8s.pt or a custom .pt if desired
MODEL_PATH = "yolo11n.pt"
model = YOLO(MODEL_PATH)

@app.get("/", response_class=PlainTextResponse)
def root():
    return "YOLO Streaming Inference Server is running. Connect via WebSocket at /ws"

@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    """Protocol: client alternates a TEXT JSON metadata message followed by a BINARY JPEG frame.
       Server returns a TEXT JSON with detections for that frame_id.
       TEXT meta example: {"frame_id": 123}
       Response example: {"frame_id": 123, "detections":[{"label":"person","conf":0.91,"x1":10,"y1":20,"x2":100,"y2":200}]}"""
    await websocket.accept()
    try:
        while True:
            try:
                meta_text = await websocket.receive_text()
            except WebSocketDisconnect:
                break
            except Exception:
                # If the client sent binary when we expected text, consume and continue
                data_maybe = await websocket.receive()
                continue

            try:
                meta = json.loads(meta_text)
            except json.JSONDecodeError:
                await websocket.send_text(json.dumps({"error": "invalid_meta_json"}))
                continue

            frame_id = meta.get("frame_id", None)

            # Receive the binary JPEG frame
            msg = await websocket.receive()
            if "bytes" not in msg:
                await websocket.send_text(json.dumps({"frame_id": frame_id, "error": "expected_binary_frame"}))
                continue

            jpg_bytes = msg["bytes"]
            npbuf = np.frombuffer(jpg_bytes, dtype=np.uint8)
            frame = cv2.imdecode(npbuf, cv2.IMREAD_COLOR)
            if frame is None:
                await websocket.send_text(json.dumps({"frame_id": frame_id, "error": "decode_failed"}))
                continue

            # Run YOLO inference
            t0 = time.time()
            results = model.predict(source=frame, imgsz=640, conf=0.25, verbose=False)
            logging.info("Inference %.2f ms, frame_id=%s, shape=%s",
             (time.time()-t0)*1000, frame_id, frame.shape)

            detections: List[Dict[str, Any]] = []
            for r in results:
                names = r.names
                if getattr(r, "boxes", None) is None:
                    continue
                for b in r.boxes:
                    xyxy = b.xyxy[0].tolist()
                    x1, y1, x2, y2 = map(lambda v: int(max(0, round(v))), xyxy)
                    conf = float(b.conf[0]) if b.conf is not None else 0.0
                    cls_id = int(b.cls[0]) if b.cls is not None else -1
                    label = names.get(cls_id, str(cls_id))
                    detections.append({
                        "label": label,
                        "cls": cls_id,
                        "conf": conf,
                        "x1": x1, "y1": y1, "x2": x2, "y2": y2
                    })

            await websocket.send_text(json.dumps({
                "frame_id": frame_id,
                "detections": detections
            }))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        # Best-effort error message to client
        try:
            await websocket.send_text(json.dumps({"error": str(e)}))
        except Exception:
            pass
        raise


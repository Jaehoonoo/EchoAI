# ocr_server.py  
# FastAPI + WebSocket OCR server using Tesseract  
# Usage: python -m uvicorn ocr_server:app --host 0.0.0.0 --port 8000  
import json  
import time  
from typing import Optional  
  
import cv2  
import numpy as np  
from PIL import Image  
from fastapi import FastAPI, WebSocket, WebSocketDisconnect  
from fastapi.responses import PlainTextResponse  
from fastapi.middleware.cors import CORSMiddleware  
  
try:  
    import pytesseract  
except Exception as e:  
    raise RuntimeError("pytesseract is required. Install with: pip install pytesseract") from e  
  
app = FastAPI(title="OCR Streaming Server")  
  
app.add_middleware(  
    CORSMiddleware,  
    allow_origins=["*"],  
    allow_credentials=True,  
    allow_methods=["*"],  
    allow_headers=["*"],  
)  
  
# Optional: Set tesseract path if not in system PATH  
pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'  
  
@app.get("/", response_class=PlainTextResponse)  
def root():  
    return "OCR Streaming Server is running. Connect via WebSocket at /ws"  
  
@app.websocket("/ws")  
async def ws_endpoint(websocket: WebSocket):  
    """Protocol: client sends TEXT JSON metadata followed by BINARY JPEG frame.  
       Server returns TEXT JSON with extracted text for that frame_id.  
       TEXT meta example: {"frame_id": 123}  
       Response example: {"frame_id": 123, "text": "extracted text here"}"""  
    await websocket.accept()  
    try:  
        while True:  
            try:  
                meta_text = await websocket.receive_text()  
            except WebSocketDisconnect:  
                break  
            except Exception:  
                # If client sent binary when we expected text, consume and continue  
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
  
            # Convert BGR (OpenCV) to RGB (PIL)  
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)  
            pil_image = Image.fromarray(frame_rgb)  
  
            # Run OCR  
            t0 = time.time()  
            extracted_text = pytesseract.image_to_string(pil_image)  
            latency_ms = int((time.time() - t0) * 1000)  
  
            await websocket.send_text(json.dumps({  
                "frame_id": frame_id,  
                "text": extracted_text.strip(),  
                "latency_ms": latency_ms  
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
# YOLO Streaming Demo (Server + Local Webcam Client + Browser Client)

## Overview

- **server.py**: FastAPI WebSocket server that runs a YOLO model and returns detections for each frame.
- **client.py**: Python desktop client that streams your laptop webcam to the server and draws detections locally.
- **web_client.html**: Browser client (works on desktop and iPhone Safari) that streams camera frames to the server and can draw returned boxes.

## Quickstart

1. **Install requirements** (prefer a virtualenv):

   ```bash
   pip install -r requirements.txt
   ```

2. **Run the server** (downloads YOLO weights on first run):

   ```bash
   python -m uvicorn server:app --host 0.0.0.0 --port 8000
   ```

3. **Run the desktop client** (on the same machine or a different one):

   - Edit `SERVER_WS_URL` in `client.py` to point to your server (e.g., `ws://<server-ip>:8000/ws`)

   ```bash
   python client.py
   ```

   - Press `q` to quit.

4. **Try the browser client**:
   - Open `web_client.html` in a browser **over HTTPS** or via `python -m http.server` and visit `http://localhost:8000` (adjust for your static server).
   - Click **Connect** (allow camera). It will stream frames to `ws://127.0.0.1:8000/ws` by default—change the field to your server URL if remote.

## Notes

- Protocol: client sends **TEXT JSON meta** then **BINARY JPEG**; server replies **TEXT JSON** with detections.
- Tweak `JPEG_QUALITY` and `TARGET_FPS` on the clients for bandwidth/latency tradeoffs.
- For GPU inference, install CUDA-compatible PyTorch and Ultralytics as per their docs.
- Security: this is a demo—add authentication, rate limiting, and TLS for production.
- iPhone: use **web_client.html** in Mobile Safari; frame sizes and FPS should be lowered for stability.

## Files

- `server.py`
- `client.py`
- `web_client.html`
- `requirements.txt`

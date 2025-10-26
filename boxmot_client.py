# client.py — YOLO + DeepSORT + KF predictions viewer (desktop webcam -> server)
# Requires: websocket-client, opencv-python, numpy
import json
import struct
import time
import cv2
import numpy as np

try:
    import websocket  # pip install websocket-client
except Exception as e:
    raise RuntimeError("Install websocket-client: pip install websocket-client") from e

# =======================
# Configuration
# =======================
SERVER_WS_URL = "wss://retain-poor-found-upload.trycloudflare.com/ws"
CAMERA_INDEX = 0
TARGET_FPS = 20
JPEG_QUALITY = 70
PREVIEW_SIZE = None

# Optional: only render these classes (None = all)
RENDER_CLASSES = None  # e.g., {"   person", "car"}

# =======================
# Drawing utilities
# =======================
GREEN = (0, 255, 0)
RED = (0, 0, 255)
YEL = (0, 255, 255)
CYAN = (255, 255, 0)
GRAY = (200, 200, 200)
WHITE = (255, 255, 255)


def put_label(img, text, tl, color=GREEN, scale=0.6, thickness=2):
    x, y = tl
    cv2.putText(
        img,
        text,
        (x, y),
        cv2.FONT_HERSHEY_SIMPLEX,
        scale,
        color,
        thickness,
        cv2.LINE_AA,
    )


def draw_zone(img, zone):
    x1, y1, x2, y2 = zone["x1"], zone["y1"], zone["x2"], zone["y2"]
    cv2.rectangle(img, (x1, y1), (x2, y2), YEL, 2)
    put_label(img, "WARNING ZONE", (x1 + 6, max(0, y1 - 6)), YEL, 0.55, 2)


def draw_current_box(img, t):
    x1, y1, x2, y2 = map(int, t["bbox"])
    pr = t.get("priority", "low")
    color = RED if pr == "high" else (YEL if pr == "medium" else GREEN)
    cv2.rectangle(img, (x1, y1), (x2, y2), color, 2)
    txt = f'ID:{t["id"]} {t.get("label","obj")} {t.get("conf",0):.2f} [{pr}]'
    put_label(img, txt, (x1 + 4, max(12, y1 - 6)), color, 0.6, 2)


def draw_predictions(img, preds):
    if len(preds) >= 2:
        # Polyline showing motion direction
        pts = np.array(preds, dtype=np.int32).reshape((-1, 1, 2))
        cv2.polylines(img, [pts], isClosed=False, color=CYAN, thickness=2)


def draw_hud(img, latency_ms, fps):
    put_label(img, f"Latency: {latency_ms} ms", (10, 22), WHITE, 0.6, 2)
    put_label(img, f"FPS: {fps:.1f}", (10, 44), WHITE, 0.6, 2)


# =======================
# Main
# =======================
def main():
    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        raise RuntimeError("Could not open webcam")

    ws = websocket.create_connection(
        SERVER_WS_URL, timeout=30, ping_interval=20, ping_timeout=10
    )
    print("Connected to server:", SERVER_WS_URL)

    frame_id = 0
    prev = time.time()
    vis_fps = 0.0
    fps_t0 = time.time()
    fps_cnt = 0

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break

            # JPEG encode for network efficiency
            ok, enc = cv2.imencode(
                ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY]
            )
            if not ok:
                continue

            header = struct.pack("<Q", frame_id)
            jpg_bytes = enc.tobytes()
            # print(len(jpg_bytes) + len(header))

            ws.send_binary(header + jpg_bytes)

            # Receive detection/tracking/predictions
            ws.settimeout(60)
            msg = ws.recv()
            resp = json.loads(msg)
            # print(resp)

            # Copy original for drawing
            vis = frame.copy()

            # Draw zone if present
            if "zone" in resp and isinstance(resp["zone"], dict):
                draw_zone(vis, resp["zone"])

            tracks = resp.get("tracks", [])
            for t in tracks:
                label = t.get("label", "obj")
                if RENDER_CLASSES and label not in RENDER_CLASSES:
                    continue
                draw_current_box(vis, t)
                preds = t.get("pred_path", [])
                if preds:
                    draw_predictions(vis, preds)

            # HUD
            latency_ms = resp.get("latency_ms", 0)
            # crude FPS calc (display rate)
            fps_cnt += 1
            if time.time() - fps_t0 >= 0.5:
                vis_fps = fps_cnt / (time.time() - fps_t0)
                fps_cnt = 0
                fps_t0 = time.time()
            draw_hud(vis, latency_ms, vis_fps)

            # Optional preview resize
            if PREVIEW_SIZE:
                vis = cv2.resize(vis, PREVIEW_SIZE)

            cv2.imshow("YOLO Client (with DeepSORT + KF predictions)", vis)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

            # Simple FPS cap
            elapsed = time.time() - prev
            target = 1.0 / max(1, TARGET_FPS)
            if elapsed < target:
                time.sleep(target - elapsed)
            prev = time.time()
            frame_id += 1

    finally:
        try:
            ws.close()
        except Exception:
            pass
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()

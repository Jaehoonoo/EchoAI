import argparse
import math
import time
from collections import defaultdict, deque

import cv2
from ultralytics import YOLO

# -----------------------------
# Heuristics / risk thresholds
# -----------------------------
# Bearing-rate: approaching collision tends to keep a near-constant bearing (|dβ/dt| small)
BEARING_RATE_EPS = 0.15   # rad/s; lower => stricter "constant bearing"
# Scale-rate: growing bbox size indicates approach when camera is roughly steady
SCALE_RATE_MIN = 0.35     # 1/s relative growth (tune)
# Debounce to avoid spamming alerts
ALERT_COOLDOWN_S = 1.5
# Only warn on these classes (COCO ids). Adjust as needed.
# COCO: person=0, bicycle=1, car=2, motorcycle=3, bus=5, truck=7
INTERESTING_CLASS_IDS = {0, 1, 2, 3, 5, 7}

# Keep short history per track to compute rates
class TrackState:
    __slots__ = ("history", "last_alert_t")
    def __init__(self):
        # Each item: (t, cx, cy, size_proxy)
        self.history = deque(maxlen=6)
        self.last_alert_t = 0.0

def bearing(cx, cy, W, H):
    """Bearing angle in image plane relative to center; left<0, right>0."""
    # x-axis: right positive; define bearing using x only (lateral intent)
    # Use arctan of normalized x-offset; keeps units in radians and bounded.
    nx = (cx - W / 2.0) / (W / 2.0)
    # map [-1,1] => angle ~ [-pi/4, pi/4] by tan^-1(k*nx); choose k=1.0
    return math.atan(nx)

def size_proxy_from_box(xyxy):
    """Use sqrt(area) as a scale proxy; grows roughly linearly with image proximity."""
    x1, y1, x2, y2 = xyxy
    w = max(1.0, float(x2 - x1))
    h = max(1.0, float(y2 - y1))
    return math.sqrt(w * h)

def motion_intent_from_history(hist):
    """
    Given a short time-ordered deque of (t, cx, cy, s), compute:
    - bearing rate dβ/dt  (rad/s) using last two samples
    - relative scale rate (1/s): (s_t - s_{t-1}) / (dt * max(s_{t-1}, eps))
    """
    if len(hist) < 2:
        return None
    (t1, cx1, cy1, s1) = hist[-2]
    (t2, cx2, cy2, s2) = hist[-1]
    dt = max(1e-6, t2 - t1)
    # bearing computed externally because it depends on frame size; we stored cx,cy only
    return dt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=str, default="0", help="camera index or video file path")
    ap.add_argument("--model", type=str, default="yolov8n.pt", help="Ultralytics model path")
    ap.add_argument("--conf", type=float, default=0.25, help="detection confidence")
    ap.add_argument("--tracker", type=str, default="bytetrack.yaml", help="tracker config (Ultralytics)")
    ap.add_argument("--show", action="store_true", help="show OpenCV window")
    args = ap.parse_args()

    source = int(args.source) if args.source.isdigit() else args.source
    model = YOLO(args.model)

    # Track state by ID
    tracks = defaultdict(TrackState)

    # Ultralytics streaming tracker yields per-frame Results
    # persist=True keeps IDs consistent across frames
    stream = model.track(
        source=source,
        conf=args.conf,
        tracker=args.tracker,
        stream=True,
        persist=True,
        verbose=False,
    )

    win = "motion-intent"
    last_global_alert_t = 0.0

    for result in stream:
        t = time.time()

        # Raw frame to overlay (if available)
        frame = result.orig_img if hasattr(result, "orig_img") else None
        H, W = (frame.shape[0], frame.shape[1]) if frame is not None else (1080, 1920)

        boxes = result.boxes
        if boxes is None or boxes.xyxy is None:
            if args.show and frame is not None:
                cv2.imshow(win, frame)
                if cv2.waitKey(1) == 27:  # ESC
                    break
            continue

        xyxy = boxes.xyxy.cpu().numpy()
        cls = boxes.cls.cpu().numpy().astype(int) if boxes.cls is not None else []
        ids = boxes.id.cpu().numpy().astype(int) if boxes.id is not None else [-1] * len(xyxy)
        confs = boxes.conf.cpu().numpy() if boxes.conf is not None else []

        # Update histories
        for k, (bb, c, track_id) in enumerate(zip(xyxy, cls, ids)):
            if track_id < 0 or c not in INTERESTING_CLASS_IDS:
                continue
            x1, y1, x2, y2 = bb
            cx = 0.5 * (x1 + x2)
            cy = 0.5 * (y1 + y2)
            s = size_proxy_from_box(bb)
            st = tracks[track_id]
            st.history.append((t, cx, cy, s))

        # Compute risk and issue warnings
        best_left = (-1, -1.0, None)   # (track_id, risk, bb)
        best_right = (-1, -1.0, None)

        for k, (bb, c, track_id) in enumerate(zip(xyxy, cls, ids)):
            if track_id < 0 or c not in INTERESTING_CLASS_IDS:
                continue
            st = tracks[track_id]
            hist = st.history
            if len(hist) < 2:
                continue

            # bearing(t-1), bearing(t)
            (_, cx1, cy1, s1) = hist[-2]
            (_, cx2, cy2, s2) = hist[-1]
            dt = max(1e-3, hist[-1][0] - hist[-2][0])

            b1 = bearing(cx1, cy1, W, H)
            b2 = bearing(cx2, cy2, W, H)
            bdot = (b2 - b1) / dt

            # relative scale-rate (proxy for approach)
            sdot_rel = (s2 - s1) / (max(s1, 1e-3) * dt)

            # Simple risk score: low bearing rate (≈constant) + positive scale growth
            # risk in [0, 1+] rough scale
            const_bearing = max(0.0, (BEARING_RATE_EPS - abs(bdot)) / BEARING_RATE_EPS)  # 1 when |b'|==0
            growth = max(0.0, sdot_rel / SCALE_RATE_MIN)  # >=1 when strongly growing
            risk = 0.6 * const_bearing + 0.4 * min(2.0, growth)

            # Decide left/right channel by current bearing
            b_now = b2
            side = "left" if b_now < 0 else "right"

            # Keep best per side
            if side == "left" and risk > best_left[1]:
                best_left = (track_id, risk, bb)
            elif side == "right" and risk > best_right[1]:
                best_right = (track_id, risk, bb)

            # Draw overlays (optional)
            if frame is not None:
                color = (0, 255, 0) if risk < 0.7 else (0, 165, 255) if risk < 1.0 else (0, 0, 255)
                x1, y1, x2, y2 = map(int, bb)
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                cv2.putText(frame,
                            f"id {track_id} r={risk:.2f} b'={bdot:.2f} s'={sdot_rel:.2f}",
                            (x1, max(15, y1 - 8)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 1, cv2.LINE_AA)

        # Issue alerts (stdout + overlay banner) with cooldown
        now = t
        for (side, best) in (("LEFT", best_left), ("RIGHT", best_right)):
            track_id, risk, bb = best
            if track_id >= 0 and risk >= 1.0:  # tune threshold; 1.0 ~ "urgent"
                st = tracks[track_id]
                if now - st.last_alert_t >= ALERT_COOLDOWN_S:
                    print(f"[ALERT] {side} APPROACH — track {track_id}  risk={risk:.2f}")
                    st.last_alert_t = now
                    last_global_alert_t = now
                # Optional: draw side banner
                if frame is not None:
                    banner = f"{side} APPROACH"
                    cv2.putText(frame, banner, (10, 30 if side == "LEFT" else 60),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)

        if args.show and frame is not None:
            cv2.imshow(win, frame)
            if cv2.waitKey(1) == 27:  # ESC to quit
                break

    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()

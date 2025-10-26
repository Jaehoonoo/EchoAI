# ocr_client.py
# Webcam OCR client - streams frames to server and displays extracted text
import json
import time
import cv2
import os
import pvorca
import numpy as np  # <-- 1. ADD THIS IMPORT

import re # <-- 1. Import the regex library for sanitizing

from dotenv import load_dotenv

# --- ADD THIS IMPORT ---
try:
    import sounddevice as sd
except Exception as e:
    raise RuntimeError("Install sounddevice: pip install sounddevice") from e
# ----------------------------

load_dotenv()

ACCESS_KEY = os.getenv("ACCESS_KEY")
orca = pvorca.create(access_key=ACCESS_KEY)

# --- ADD THIS LINE ---
SAMPLE_RATE = orca.sample_rate
# ---------------------

# --- 2. GET THE LIST OF VALID CHARACTERS ---
# We'll use this to clean the text
VALID_CHARS_SET = set(orca.valid_characters)
# -------------------------------------------

# --- 3. ADD A SANITIZATION FUNCTION ---
def sanitize_text(text: str) -> str:
    """
    Removes any characters not supported by Orca and normalizes whitespace.
    """
    # Keep only valid characters
    filtered_chars = [
        char for char in text if char in VALID_CHARS_SET
    ]
    
    # --- FIX: Also remove special pronunciation chars ---
    # These chars ({, }, |) are "valid" but will cause a crash
    # if they appear without the proper {word|pronunciation} format.
    safe_chars = [
        char for char in filtered_chars if char not in ('{', '}', '|')
    ]
    # ---------------------------------------------------
    
    # Join them back into a string
    filtered_text = "".join(safe_chars) # Use safe_chars now
    
    # Optional: Collapse multiple spaces/newlines into a single space
    # This prevents weird pauses from janky OCR output
    normalized_text = re.sub(r'\s+', ' ', filtered_text).strip()
    
    return normalized_text
# --------------------------------------

try:
    import websocket  # from websocket-client
except Exception as e:
    raise RuntimeError("Install websocket-client: pip install websocket-client") from e

SERVER_WS_URL = "ws://127.0.0.1:8000/ws"  # change to your server's IP/port
CAMERA_INDEX = 1
JPEG_QUALITY = 75
TARGET_FPS = 5  # Lower FPS since OCR is slower than YOLO

def draw_text_overlay(img, text, latency_ms):
    """Draw extracted text and latency on the frame"""
    h, w = img.shape[:2]

    # Semi-transparent overlay at bottom
    overlay = img.copy()
    cv2.rectangle(overlay, (0, h - 150), (w, h), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.7, img, 0.3, 0, img)

    # Display latency at top
    cv2.putText(
        img,
        f"Latency: {latency_ms} ms",
        (10, 30),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (0, 255, 0),
        2,
        cv2.LINE_AA,
    )

    # Display extracted text at bottom
    y_offset = h - 130
    for line in text.split('\n')[:5]:  # Show max 5 lines
        if line.strip():
            cv2.putText(
                img,
                line[:60],  # Truncate long lines
                (10, y_offset),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (255, 255, 255),
                1,
                cv2.LINE_AA,
            )
            y_offset += 25

    return img

def main():
    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        raise RuntimeError("Could not open webcam")

    ws = websocket.create_connection(
        SERVER_WS_URL,
        timeout=30,
        ping_interval=20,
        ping_timeout=10,
    )
    print("Connected to server:", SERVER_WS_URL)
    print("--- Press 'o' to trigger one-frame OCR ---") # Changed prompt
    print("--- Press 'q' to quit ---")

    frame_id = 0
    last_text = ""
    last_latency = 0
    ocr_enabled = False  # Start with OCR disabled

    try:
        prev = time.time()
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # --- Handle Key Presses for Toggle ---
            key = cv2.waitKey(1) & 0xFF
            if key == ord("q"):
                break
            elif key == ord("o"):
                # Only set to True if it's currently False
                if not ocr_enabled:
                    ocr_enabled = True # Toggle the flag ON
                    print(f"OCR Toggled: ON (for one frame)")
            # -------------------------------------

            # JPEG encode for network efficiency
            ok, enc = cv2.imencode(
                ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY]
            )
            if not ok:
                continue
            jpg_bytes = enc.tobytes()

            # Send metadata (with the new flag) then frame
            meta = {
                "frame_id": frame_id,
                "do_ocr": ocr_enabled  # Send the current OCR state
            }
            ws.send(json.dumps(meta))
            ws.send_binary(jpg_bytes)
            
            # --- BUG FIX: DO NOT SET ocr_enabled = False HERE ---

            # Receive OCR results
            msg = ws.recv()
            resp = json.loads(msg)

            current_text = ""
            if "text" in resp:
                received_text = resp.get("text")
                current_text = received_text if received_text is not None else ""
                last_latency = resp.get("latency_ms", 0)
            
            # --- 4. SANITIZE THE TEXT BEFORE USING IT ---
            sanitized_text = sanitize_text(current_text)
            
            # This block will now run correctly
            # Check against the *sanitized* text
            if ocr_enabled and sanitized_text and sanitized_text != last_text:
                
                # Use the clean text for synthesis
                print(f"Synthesizing: {sanitized_text}")
                pcm, alignments = orca.synthesize(text=sanitized_text)
                
                pcm_int16 = np.array(pcm).astype(np.int16)
                
                sd.stop()
                sd.play(pcm_int16, samplerate=SAMPLE_RATE)
            
            # Store the *sanitized* text for the next loop's comparison
            last_text = sanitized_text

            # --- LOGIC FIX: SET FLAG TO FALSE *HERE* ---
            if ocr_enabled:
                ocr_enabled = False
            
            # Draw overlay with the *original* (unsanitized) text
            # This way, the user sees what the OCR *actually* read
            vis = draw_text_overlay(frame.copy(), current_text, last_latency)
            
            # Also draw the current OCR status
            status_text = f"OCR: {'PENDING' if ocr_enabled else 'OFF'} (Press 'o')"
            status_color = (0, 255, 0) if ocr_enabled else (0, 0, 255)
            cv2.putText(vis, status_text, (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, status_color, 2)

            cv2.imshow("OCR Client", vis)
            
            frame_id += 1

            # Simple FPS control
            elapsed = time.time() - prev
            target = 1.0 / TARGET_FPS
            if elapsed < target:
                time.sleep(target - elapsed)
            prev = time.time()
    finally:
        # --- FIX: ADD CLEANUP CODE ---
        orca.delete() # Clean up orca
        sd.stop()     # Stop all audio
        # -----------------------------
        ws.close()
        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
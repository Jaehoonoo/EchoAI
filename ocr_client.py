# ocr_client.py  
# Webcam OCR client - streams frames to server and displays extracted text  
import json  
import time  
import cv2  
  
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
    print("--- Press 'o' to toggle OCR on/off ---")
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
                ocr_enabled = not ocr_enabled  # Toggle the flag
                print(f"OCR Toggled: {'ON' if ocr_enabled else 'OFF'}")
                if not ocr_enabled:
                    last_text = ""  # Clear text when turning off
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

            # Receive OCR results
            msg = ws.recv()
            resp = json.loads(msg)

            # Update text only if we get a valid text response
            if "text" in resp:
                # Coerce `null` (from no-ocr) to "" for safe drawing
                received_text = resp.get("text")
                last_text = received_text if received_text is not None else ""
                last_latency = resp.get("latency_ms", 0)

            # Draw overlay with extracted text
            vis = draw_text_overlay(frame.copy(), last_text, last_latency)
            
            # Also draw the current OCR status
            status_text = f"OCR: {'ON' if ocr_enabled else 'OFF'} (Press 'o')"
            status_color = (0, 255, 0) if ocr_enabled else (0, 0, 255)
            cv2.putText(vis, status_text, (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, status_color, 2)

            cv2.imshow("OCR Client", vis)
            
            # We already handled 'q' and 'o' above, so remove waitKey from here
            # if cv2.waitKey(1) & 0xFF == ord("q"):
            #    break

            frame_id += 1

            # Simple FPS control
            elapsed = time.time() - prev
            target = 1.0 / TARGET_FPS
            if elapsed < target:
                time.sleep(target - elapsed)
            prev = time.time()
    finally:
        ws.close()
        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":  
    main()
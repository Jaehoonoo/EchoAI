# ocr_client.py
# Webcam OCR client with full voice command integration
import json
import time
import cv2
import os
import pvorca
import numpy as np
import re
from dotenv import load_dotenv

# --- 1. PICOWORLD IMPORTS ---
import pvporcupine
import pvcheetah
# import pvrecorder  # <-- CHANGE 1: We no longer need this

# --- SOUNDDEVICE IMPORT ---
try:
    import sounddevice as sd
except Exception as e:
    raise RuntimeError("Install sounddevice: pip install sounddevice") from e
# ----------------------------

load_dotenv()

ACCESS_KEY = os.getenv("ACCESS_KEY")
YOUR_MIC_INDEX = 6 # <-- Set your mic index here

# --- 2. INITIALIZE ALL PICOVOICE ENGINES ---
try:
    # ORCA (TTS)
    orca = pvorca.create(access_key=ACCESS_KEY, model_path="models/orca_params_en_male.pv")
    SAMPLE_RATE = orca.sample_rate # Use Orca's sample rate for everything
    VALID_CHARS_SET = set(orca.valid_characters)
    print("Orca (TTS) initialized.")

    # PORCUPINE (Wake Word)
    porcupine = pvporcupine.create(
        access_key=ACCESS_KEY,
        keyword_paths=["models/Hey-Echo_en_windows_v3_0_0.ppn"]
    )
    print("Porcupine (Wake Word) initialized for 'Hey Echo'.")

    # CHEETAH (STT)
    cheetah = pvcheetah.create(
        access_key=ACCESS_KEY,
        model_path="models/echo-cheetah-default-v2.3.0-25-10-26--03-20-25.pv",
        endpoint_duration_sec=1.0
    )
    print("Cheetah (STT) initialized.")

    # --- 3. PRE-SYNTHESIZE "YES?" RESPONSE ---
    print("Synthesizing 'Yes?' acknowledgement...")
    yes_pcm, _ = orca.synthesize(text="Yes?")
    yes_pcm_int16 = np.array(yes_pcm).astype(np.int16)
    print("Acknowledgement ready.")

except Exception as e:
    print(f"Error initializing Picovoice engines: {e}")
    raise

# --- 4. INITIALIZE RECORDER (USING SOUNDDEVICE) ---
# <-- CHANGE 2: Replaced the entire pvrecorder block with this
try:
    print(f"Attempting to open mic {YOUR_MIC_INDEX} at {porcupine.sample_rate} Hz...")
    
    # We will request 16000 Hz (porcupine.sample_rate)
    # sounddevice will automatically resample if the mic doesn't support it
    stream = sd.InputStream(
        device=YOUR_MIC_INDEX,
        channels=1,
        samplerate=porcupine.sample_rate, # Request 16000 Hz
        blocksize=porcupine.frame_length,
        dtype='int16' # Picovoice engines need int16
    )
    stream.start()
    print(f"Audio stream started (samplerate={stream.samplerate}).")

except Exception as e:
    print(f"Failed to open audio stream: {e}")
    print(f"Check if device index {YOUR_MIC_INDEX} is a valid INPUT device.")
    raise
# ---------------------------------

def sanitize_text(text: str) -> str:
    """Removes any characters not supported by Orca and normalizes whitespace."""
    filtered_chars = [char for char in text if char in VALID_CHARS_SET]
    safe_chars = [char for char in filtered_chars if char not in ('{', '}', '|')]
    filtered_text = "".join(safe_chars)
    normalized_text = re.sub(r'\s+', ' ', filtered_text).strip()
    return normalized_text

try:
    import websocket  # from websocket-client
except Exception as e:
    raise RuntimeError("Install websocket-client: pip install websocket-client") from e

SERVER_WS_URL = "ws://127.0.0.1:8000/ws"
CAMERA_INDEX = 1
JPEG_QUALITY = 75
TARGET_FPS = 5

def draw_text_overlay(img, text, latency_ms):
    """Draw extracted text and latency on the frame"""
    h, w = img.shape[:2]

    overlay = img.copy()
    cv2.rectangle(overlay, (0, h - 150), (w, h), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.7, img, 0.3, 0, img)

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

    y_offset = h - 130
    for line in text.split('\n')[:5]:
        if line.strip():
            cv2.putText(
                img,
                line[:60],
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
    print("--- Press 'q' to quit ---")

    frame_id = 0
    last_text = ""
    current_text = ""
    last_latency = 0
    ocr_enabled = False
    
    # --- 5. STATE MACHINE SETUP ---
    STATE_WAITING = "WAITING"
    STATE_LISTENING = "LISTENING"
    STATE_PROCESSING = "PROCESSING"
    current_state = STATE_WAITING
    
    partial_transcript = "" # For STT
    
    prev_network_time = time.time()
    target_network_interval = 1.0 / TARGET_FPS

    try:
        while True:
            # --- 6. AUDIO-DRIVEN MAIN LOOP ---
            # <-- CHANGE 3: Read from the sounddevice stream
            try:
                pcm_2d, overflowed = stream.read(porcupine.frame_length)
                if overflowed:
                    print("Warning: Audio buffer overflowed")
                
                # Porcupine/Cheetah need a 1D array
                pcm = pcm_2d.flatten()
            
            except sd.PortAudioError as e:
                print(f"Audio stream error: {e}")
                break
            # ------------------------------------
            
            ret, frame = cap.read()
            if not ret:
                break

            key = cv2.waitKey(1) & 0xFF
            if key == ord("q"):
                print("Quitting...")
                break

            # --- 7. STATE MACHINE LOGIC ---
            if current_state == STATE_WAITING:
                result = porcupine.process(pcm)
                if result >= 0:
                    print("Wake word 'Hey Echo' detected!")
                    sd.play(yes_pcm_int16, SAMPLE_RATE)
                    current_state = STATE_LISTENING
                    partial_transcript = ""
                    cheetah.flush() # Clear STT buffer

            elif current_state == STATE_LISTENING:
                try:
                    partial, is_endpoint = cheetah.process(pcm)
                    partial_transcript += partial
                    
                    if partial:
                        print(f"Listening... '{partial_transcript}'")

                    if is_endpoint:
                        final_transcript = cheetah.flush() + partial_transcript
                        print(f"Command received: '{final_transcript}'")
                        
                        # --- COMMAND CHECK ---
                        if "read this for me" in final_transcript.lower():
                            print("Command recognized! Triggering OCR.")
                            ocr_enabled = True # Trigger the one-shot OCR
                            current_state = STATE_PROCESSING
                        else:
                            print("Unknown command. Returning to wait.")
                            current_state = STATE_WAITING
                        partial_transcript = ""
                        
                except pvcheetah.CheetahActivationLimitError:
                    print("STT reached activation limit. Resetting.")
                    current_state = STATE_WAITING

            elif current_state == STATE_PROCESSING:
                pass
            # --- END OF STATE MACHINE ---


            # --- 8. RATE-LIMITED NETWORK/OCR LOOP ---
            time_now = time.time()
            elapsed = time_now - prev_network_time
            
            if elapsed >= target_network_interval:
                prev_network_time = time_now
                
                ok, enc = cv2.imencode(
                    ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY]
                )
                if not ok:
                    print("JPEG encode failed")
                    continue
                jpg_bytes = enc.tobytes()

                meta = {
                    "frame_id": frame_id,
                    "do_ocr": ocr_enabled
                }
                ws.send(json.dumps(meta))
                ws.send_binary(jpg_bytes)
                
                msg = ws.recv()
                resp = json.loads(msg)

                if "text" in resp:
                    received_text = resp.get("text")
                    current_text = received_text if received_text is not None else ""
                    last_latency = resp.get("latency_ms", 0)
                
                sanitized_text = sanitize_text(current_text)
                
                if ocr_enabled and sanitized_text and sanitized_text != last_text:
                    print(f"Synthesizing: {sanitized_text}")
                    try:
                        pcm_tts, alignments = orca.synthesize(text=sanitized_text)
                        pcm_int16 = np.array(pcm_tts).astype(np.int16)
                        sd.stop()
                        sd.play(pcm_int16, samplerate=SAMPLE_RATE)
                    except Exception as e:
                        print(f"Orca synthesis error: {e}")
                
                last_text = sanitized_text

                if ocr_enabled:
                    ocr_enabled = False # Reset one-shot flag
                    current_state = STATE_WAITING # Go back to waiting
                
                frame_id += 1
            # --- END OF RATE-LIMITED LOOP ---
            
            
            # --- 9. DISPLAY LOOP (Runs every audio frame) ---
            vis = draw_text_overlay(frame.copy(), current_text, last_latency)
            
            status_text = ""
            if current_state == STATE_WAITING:
                status_text = "STATUS: Waiting for 'Hey Echo'..."
            elif current_state == STATE_LISTENING:
                status_text = f"STATUS: Listening... '{partial_transcript}'"
            elif current_state == STATE_PROCESSING:
                status_text = "STATUS: Reading..."
            
            status_color = (0, 255, 0) if ocr_enabled else (0, 0, 255)
            cv2.putText(vis, status_text[:50], (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, status_color, 2)

            cv2.imshow("OCR Client", vis)
            # ---------------------------------------------

    finally:
        # --- 10. CLEANUP ALL 5 RESOURCES ---
        # <-- CHANGE 4: Update cleanup to use the 'stream' object
        print("Cleaning up all resources...")
        if 'stream' in locals() and stream is not None:
            stream.stop()
            stream.close()
        if 'porcupine' in locals() and porcupine is not None:
            porcupine.delete()
        if 'cheetah' in locals() and cheetah is not None:
            cheetah.delete()
        if 'orca' in locals() and orca is not None:
            orca.delete()
        sd.stop()
        ws.close()
        cap.release()
        cv2.destroyAllWindows()
        print("Done.")

if __name__ == "__main__":
    main()
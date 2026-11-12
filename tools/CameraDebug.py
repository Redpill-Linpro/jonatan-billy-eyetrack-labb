import cv2
import sys
import os

def log_debug_info():
    print("--- OpenCV Build Information ---")
    print(cv2.getBuildInformation())
    print("-" * 30)

def test_camera(index, backend_name, backend_id):
    print(f"\n[Testing] Index {index} using backend: {backend_name}")
    
    # Attempt to open the camera with the specific backend
    cap = cv2.VideoCapture(index, backend_id)
    
    if not cap.isOpened():
        print(f"  [Error] Could not open camera at index {index} with {backend_name}.")
        return False

    try:
        # Get properties
        w = cap.get(cv2.CAP_PROP_FRAME_WIDTH)
        h = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
        backend_used = cap.getBackendName()
        print(f"  [Success] Connected! Backend: {backend_used} | Resolution: {int(w)}x{int(h)}")

        # Attempt to capture a single frame
        ret, frame = cap.read()
        if ret and frame is not None:
            filename = f"debug_frame_idx{index}_{backend_name}.jpg"
            cv2.imwrite(filename, frame)
            print(f"  [Success] Frame captured and saved as: {filename}")
            return True
        else:
            print("  [Error] Connected, but failed to read frame (ret=False).")
            return False
            
    except Exception as e:
        print(f"  [Exception] An error occurred during capture: {e}")
        return False
    finally:
        cap.release()

def main():
    print("Camera Debug Utility Starting...")
    log_debug_info()
    
    # Backends to test (Common across OS)
    backends = [
        ("CAP_ANY (Default)", cv2.CAP_ANY),
    ]
    
    # OS-specific backends for deep debugging
    if sys.platform == "win32":
        backends.append(("DSHOW (DirectShow)", cv2.CAP_DSHOW))
        backends.append(("MSMF (Media Foundation)", cv2.CAP_MSMF))
    elif sys.platform == "linux":
        backends.append(("V4L2", cv2.CAP_V4L2))
    elif sys.platform == "darwin": # macOS
        backends.append(("AVFOUNDATION", cv2.CAP_AVFOUNDATION))

    found_any = False
    
    # Probe indices 0 through 10
    for i in range(11):
        for name, bid in backends:
            if test_camera(i, name, bid):
                found_any = True
    
    if not found_any:
        print("\n" + "!"*40)
        print("CRITICAL: No working camera devices found.")
        print("1. Check if the camera is plugged in.")
        print("2. Verify Privacy Settings (Allow apps to access camera).")
        print("3. Ensure no other app (Zoom, Teams, etc.) is using it.")
        print("!"*40)
    else:
        print("\nDebug complete. Review the logs above to see which index/backend worked.")

if __name__ == "__main__":
    main()

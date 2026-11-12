import argparse
import cv2
import numpy as np
import socket
import struct
import time
import math
import configparser
import glob
import os
import re
import select
import sys
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision
from scipy.spatial.distance import pdist
from scipy.spatial.transform import Rotation as Rscipy

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, 'settings.ini')
MODEL_PATH = os.path.join(SCRIPT_DIR, 'face_landmarker.task')

config = configparser.ConfigParser(inline_comment_prefixes=(';', '#'))
config.read(CONFIG_PATH)

CAM_INDEX = config.get('Camera', 'index', fallback='auto').strip() or 'auto'
CAM_NAME = config.get('Camera', 'name', fallback='').strip()

INV_X = -1 if config.getboolean('Inversion', 'invert_x', fallback=True) else 1
INV_Y = -1 if config.getboolean('Inversion', 'invert_y', fallback=False) else 1
INV_YAW = -1 if config.getboolean('Inversion', 'invert_yaw', fallback=True) else 1
INV_PIT = -1 if config.getboolean('Inversion', 'invert_pitch', fallback=False) else 1
INV_ROL = -1 if config.getboolean('Inversion', 'invert_roll', fallback=False) else 1

GAZE_BOOST = config.getfloat('Sensitivity', 'gaze_boost', fallback=1.2)
SCALE_X = config.getfloat('Sensitivity', 'scale_x', fallback=100.0)
SCALE_Y = config.getfloat('Sensitivity', 'scale_y', fallback=100.0)

LOST_TIMEOUT = config.getint('Tracking', 'lost_timeout_ms', fallback=500)
AUTO_CENTER = config.getboolean('Tracking', 'auto_center_on_acquire', fallback=True)
RECALIBRATE_BLINKS = config.getint('Tracking', 'recalibrate_blinks', fallback=3)

# -----------------------------------------------------------------------------
# Core Classes
# -----------------------------------------------------------------------------
class OneEuroFilter:
    def __init__(self, freq, min_cutoff=1.0, beta=0.0, d_cutoff=1.0):
        self.freq, self.min_cutoff, self.beta, self.d_cutoff = freq, min_cutoff, beta, d_cutoff
        self.x_prev, self.dx_prev = None, 0.0

    def reset(self):
        self.x_prev = None
        self.dx_prev = 0.0

    def _alpha(self, cutoff):
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau * self.freq)

    def __call__(self, x):
        if self.x_prev is None:
            self.x_prev = x
            return x
        dx = (x - self.x_prev) * self.freq
        edx = self._alpha(self.d_cutoff) * dx + (1 - self._alpha(self.d_cutoff)) * self.dx_prev
        self.dx_prev = edx
        a = self._alpha(self.min_cutoff + self.beta * abs(edx))
        self.x_prev = a * x + (1 - a) * self.x_prev
        return self.x_prev

class OpenTrackClient:
    def __init__(self, ip="127.0.0.1", port=4242):
        self.addr = (ip, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    def send(self, x, y, z, yaw, pitch, roll):
        packet = struct.pack('dddddd', x, y, z, yaw, pitch, roll)
        self.sock.sendto(packet, self.addr)

class StateMonitor:
    def __init__(self, timeout_ms, auto_center, uncentered=(2,)):
        self.timeout_ms = timeout_ms
        self.auto_center = auto_center
        self.uncentered = list(uncentered)  # axes auto-centering leaves alone (z; yaw/pitch once calibrated)
        self.last_valid_time = 0
        self.is_lost = True
        self.offsets = np.zeros(6) 
        
        # Store the Rotation Matrix from the last valid frame to prevent flipping
        self.R_prev = None 

    def check(self, has_data, current_time_ms, raw_values, filters, R_current=None):
        if has_data:
            if self.is_lost:
                print(f"[Tracking] Reacquired after {current_time_ms - self.last_valid_time}ms gap.")
                self.is_lost = False
                # If we lost tracking for a long time, reset R_prev so we don't try 
                # to stabilize against a stale, totally different head pose.
                self.R_prev = None 
                
                for f in filters: f.reset()
                
                if self.auto_center:
                    print("[Tracking] Auto-Centering...")
                    self.center(raw_values)
            
            # === STABILIZATION LOGIC ===
            # If we have a history, force R_current to match its general direction
            if self.R_prev is not None and R_current is not None:
                # Check columns 0 (Right), 1 (Up), 2 (Forward)
                for i in range(3):
                    # Dot product < 0 means the axis points in the opposite direction
                    if np.dot(R_current[:, i], self.R_prev[:, i]) < 0:
                        R_current[:, i] *= -1
            
            # Save corrected matrix for next frame
            if R_current is not None:
                self.R_prev = R_current.copy()
            # ===========================

            self.last_valid_time = current_time_ms
            centered_values = np.array(raw_values) - self.offsets
            angles = centered_values[3:]  # wrap into +-180, e.g. roll -347 -> 13
            angles[np.abs(angles) > 180] = (angles[np.abs(angles) > 180] + 180) % 360 - 180
            return True, centered_values

        else:
            time_since_valid = current_time_ms - self.last_valid_time
            if time_since_valid > self.timeout_ms and not self.is_lost:
                print(f"[Tracking] Target Lost (No data for {time_since_valid}ms)")
                self.is_lost = True
                self.R_prev = None # Clear history on loss
            return False, None

    def center(self, raw_values):
        self.offsets = np.array(raw_values)
        self.offsets[self.uncentered] = 0

# -----------------------------------------------------------------------------
# Math Helpers
# -----------------------------------------------------------------------------
def get_eye_center(landmarks, indices, w, h):
    pts = np.array([[landmarks[i].x * w, landmarks[i].y * h, landmarks[i].z * w] for i in indices])
    return np.mean(pts, axis=0)

def compute_gaze_offset(landmarks, w, h):
    LEFT_EYE_SOCKET = [33, 160, 158, 133, 153, 144]
    RIGHT_EYE_SOCKET = [362, 385, 387, 263, 373, 380]
    L_IRIS_CENTER, R_IRIS_CENTER = 468, 473
    
    l_socket = get_eye_center(landmarks, LEFT_EYE_SOCKET, w, h)
    r_socket = get_eye_center(landmarks, RIGHT_EYE_SOCKET, w, h)
    l_iris = np.array([landmarks[L_IRIS_CENTER].x * w, landmarks[L_IRIS_CENTER].y * h, landmarks[L_IRIS_CENTER].z * w])
    r_iris = np.array([landmarks[R_IRIS_CENTER].x * w, landmarks[R_IRIS_CENTER].y * h, landmarks[R_IRIS_CENTER].z * w])
    
    eye_width = np.linalg.norm(np.array([landmarks[33].x*w, landmarks[33].y*h]) - np.array([landmarks[133].x*w, landmarks[133].y*h]))
    avg_offset = ((l_iris - l_socket) + (r_iris - r_socket)) / (2.0 * eye_width)
    return avg_offset[0], avg_offset[1]

def head_plus_iris(lms, w, h, h_yaw, h_pitch):
    """Default gaze: head angles plus the iris offset in its socket. No calibration."""
    gaze_x, gaze_y = compute_gaze_offset(lms, w, h)
    combined_yaw = (h_yaw * INV_YAW) + (gaze_x * 50 * GAZE_BOOST)
    combined_pitch = (h_pitch * INV_PIT) + (gaze_y * 50 * GAZE_BOOST)
    return combined_yaw, combined_pitch

# -----------------------------------------------------------------------------
# Eye-Sphere Gaze (--calibrate)
# -----------------------------------------------------------------------------
# Each eyeball centre is fixed in the head frame at calibration; gaze is the ray
# from it through the iris, so it already contains head rotation.
NOSE = [1, 2, 3, 4, 5, 6, 168, 197, 195]  # same landmarks as the default head pose
EYES = [(468, 33, 133), (473, 362, 263)]  # (iris centre, eye corner, eye corner)
EYE_RADIUS = 0.4  # eyeball centre to iris, as a fraction of eye width
MIN_RAY_COS = math.cos(math.radians(60))  # ignore an eye whose ray is over 60 deg from where it was at calibration

def to_px(lms, w, h):
    return np.array([[p.x * w, p.y * h, p.z * w] for p in lms])

def head_frame(P):
    """Nose centre, SVD axes and scale (mean pairwise distance) from pixel landmarks P."""
    pts = P[NOSE]
    center = pts.mean(axis=0)
    R = np.linalg.svd(pts - center)[2].T
    if np.linalg.det(R) < 0: R[:, 2] *= -1
    return center, R, pdist(pts).mean()

def unit(v): return v / np.linalg.norm(v)

class EyeSpheres:
    def __init__(self, P): self.lock(P)

    def lock(self, P):
        """Lock both spheres from landmarks P of a face looking at the screen centre."""
        center, self.R, self.scale = head_frame(P)
        back = self.R.T @ [0, 0, 1]  # camera viewing axis (away from camera), head-local
        self.offsets = [self.R.T @ (P[iris] - center) + EYE_RADIUS * np.linalg.norm(P[a] - P[b]) * back
                        for iris, a, b in EYES]

    def recalibrate(self, cap, detector, monitor, raw):
        P = sample_face(cap, detector)
        if P is not None: self.lock(P)
        print("[Calibrate] Blink gesture: eye spheres re-locked." if P is not None else
              "[Calibrate] Blink gesture: face lost, spheres unchanged.", flush=True)

    def __call__(self, lms, w, h, h_yaw, h_pitch):
        """Gaze (yaw, pitch), or None when neither eye gives a usable ray."""
        P = to_px(lms, w, h)
        center, R, scale = head_frame(P)
        R = R * np.where(np.sum(R * self.R, axis=0) < 0, -1, 1)  # axis signs as at calibration
        rays = [(P[iris], unit(P[iris] - center - R @ (off * scale / self.scale)))
                for off, (iris, _, _) in zip(self.offsets, EYES)]
        # An iris outside the image is extrapolated; a ray that far off is junk.
        # Weighting by the margin to that limit fades an eye out instead of switching it off.
        rays = [(-d[2] - MIN_RAY_COS) * d for (x, y, _), d in rays
                if 0 <= x < w and 0 <= y < h and -d[2] > MIN_RAY_COS]
        if not rays: return None
        d = sum(rays)
        # Same signs as the default: iris right -> +yaw, iris down -> +pitch; 0 at calibration.
        yaw = math.degrees(math.atan2(d[0], -d[2]))
        pitch = math.degrees(math.atan2(d[1], -d[2]))
        return yaw * GAZE_BOOST, pitch * GAZE_BOOST

# -----------------------------------------------------------------------------
# Blinks
# -----------------------------------------------------------------------------
BLINK_RISE = 0.2       # eyeBlink score rise over the open-eye baseline that means closed
BLINK_REOPEN = 0.1     # ...and the rise below which it is open again
BLINK_MAX_MS = 700     # a longer closure is not a blink: breaks a gesture, stops holding gaze
BLINK_GAP_MS = 600     # max open time between blinks of one gesture; the gesture fires after it
BLINK_SETTLE_MS = 200  # gaze stays held this long after the eyes reopen (they roll back)

class EyeLids:
    """eyeBlink score -> eye closed, against a running open-eye baseline: looking down
    lowers the lids and raises the score for long stretches, a blink is a short rise."""
    def __init__(self):
        self.base, self.closed_at = None, None

    def __call__(self, score, t_ms):
        if score is None:
            self.closed_at = None
            return None
        if self.base is None: self.base = score
        closed = score - self.base > (BLINK_REOPEN if self.closed_at else BLINK_RISE)
        if not closed: self.closed_at = None
        elif self.closed_at is None: self.closed_at = t_ms
        if not closed or t_ms - self.closed_at > BLINK_MAX_MS:  # too long for a blink: re-baseline
            self.base += (score - self.base) / 30  # ~1 s at 30 fps
        return closed

class Blinks:
    """Per-frame eye-closed flags -> gaze hold, and the N-blink gesture event.
    Either eye closed counts, so a wink is a blink."""
    def __init__(self, n):
        self.n = n  # 0 disables the gesture
        self.count = 0
        self.closed_at = None
        self.opened_at = -math.inf

    def update(self, closed, t_ms):
        """closed: True/False, or None without a face. Returns (hold gaze, gesture done)."""
        if closed is None:
            self.count, self.closed_at = 0, None
            return False, False
        if closed:
            if self.closed_at is None: self.closed_at = t_ms
            return t_ms - self.closed_at <= BLINK_MAX_MS, False
        if self.closed_at is not None:  # eyes just reopened
            self.count = self.count + 1 if t_ms - self.closed_at <= BLINK_MAX_MS else 0
            self.closed_at, self.opened_at = None, t_ms
        open_ms = t_ms - self.opened_at
        if self.count and open_ms > BLINK_GAP_MS:  # run of blinks over: exactly N fires
            done, self.count = self.count == self.n, 0
            return False, done
        return open_ms < BLINK_SETTLE_MS, False

# -----------------------------------------------------------------------------
# Camera Selection
# -----------------------------------------------------------------------------
def _read_sysfs(path, default=''):
    try:
        with open(path) as f: return f.read().strip()
    except OSError:
        return default

def list_cameras():
    """[(num, name)] for V4L2 capture nodes (sysfs index 0), sorted by /dev/videoN."""
    cams = []
    for d in glob.glob('/sys/class/video4linux/video*'):
        m = re.fullmatch(r'video(\d+)', os.path.basename(d))
        if not m or _read_sysfs(os.path.join(d, 'index'), '0') != '0': continue
        cams.append((int(m.group(1)), _read_sysfs(os.path.join(d, 'name'), '?')))
    return sorted(cams)

def _is_ir(name): return re.search(r'\bir\b|infrared', name.lower()) is not None

def _auto_rank(name):
    # 0 = external webcam, 1 = integrated RGB, 2 = IR
    if _is_ir(name): return 2
    return 1 if 'integrated' in name.lower() else 0

def open_camera(num, tries=10):
    """Open /dev/video<num> and grab a frame. Returns (cap, frame) or (None, None)."""
    cap = cv2.VideoCapture(num, cv2.CAP_V4L2)
    if cap.isOpened():
        for _ in range(tries):
            ok, frame = cap.read()
            if ok and frame is not None: return cap, frame
            time.sleep(0.05)
    cap.release()
    return None, None

def camera_error(msg, cams):
    print(f"ERROR: {msg}", file=sys.stderr)
    print("Detected cameras:", file=sys.stderr)
    for num, name in cams:
        print(f"  /dev/video{num}  {name}", file=sys.stderr)
    if not cams:
        print("  (none - is the camera plugged in and visible in this container?)", file=sys.stderr)
    print(f"Set [Camera] in {CONFIG_PATH}:\n"
          "  name  = <part of a camera name above>   (takes precedence)\n"
          "  index = <N for /dev/videoN> | auto", file=sys.stderr)
    sys.exit(1)

def select_camera(index=CAM_INDEX, name=CAM_NAME):
    """Resolve name/index/auto to an opened camera. Returns (cap, num, cam_name, frame)."""
    cams = list_cameras()
    names = dict(cams)

    if name:
        matches = [n for n, cname in cams if name.lower() in cname.lower()]
        if not matches: camera_error(f"No camera name contains '{name}'.", cams)
        cap, frame = open_camera(matches[0])
        if cap is None: camera_error(f"/dev/video{matches[0]} ({names[matches[0]]}) matched '{name}' but gave no frame.", cams)
        return cap, matches[0], names[matches[0]], frame

    if index.lower() != 'auto':
        try: num = int(index)
        except ValueError: camera_error(f"Invalid index '{index}' (expected 'auto' or an integer).", cams)
        cap, frame = open_camera(num)
        if cap is None: camera_error(f"Could not open /dev/video{num} or read a frame from it.", cams)
        return cap, num, names.get(num, '?'), frame

    for num, cname in sorted(cams, key=lambda c: _auto_rank(c[1])):
        cap, frame = open_camera(num)
        if cap is not None: return cap, num, cname, frame
        print(f"[Camera] /dev/video{num} ({cname}) unusable, trying next...", file=sys.stderr)
    camera_error("Auto-detect found no working camera.", cams)

# -----------------------------------------------------------------------------
# Main Loop
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Webcam head/eye tracker sending pose to opentrack (UDP 127.0.0.1:4242).")
    parser.add_argument('--calibrate', action='store_true',
                        help="use the eye-sphere gaze model, starting with a calibration step "
                             "(look at the screen centre, press Enter)")
    args = parser.parse_args()
    if args.calibrate and not sys.stdin.isatty():
        print("ERROR: --calibrate waits for Enter on a terminal, but stdin is not a terminal.", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(MODEL_PATH):
        print(f"ERROR: Model file not found: {MODEL_PATH}\n"
              "Download face_landmarker.task from the MediaPipe Face Landmarker docs "
              "and place it next to this script.", file=sys.stderr)
        sys.exit(1)

    cap, cam_num, cam_name, first = select_camera()
    print(f"[Camera] Using /dev/video{cam_num} ({cam_name}), {first.shape[1]}x{first.shape[0]}", flush=True)

    detector = None
    try:
        base_options = python.BaseOptions(model_asset_path=MODEL_PATH)
        options = vision.FaceLandmarkerOptions(
            base_options=base_options,
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            output_face_blendshapes=True  # eyeBlink scores
        )
        detector = vision.FaceLandmarker.create_from_options(options)
        if args.calibrate:
            spheres = calibrate(cap, detector)
            # yaw/pitch are zeroed by calibration, not auto-centring. The eye-sphere eye gain is
            # ~3x the default's, so 1/3 the filter beta gives the same response to an eye movement.
            run_loop(cap, detector, spheres, uncentered=(2, 3, 4), recalibrate=spheres.recalibrate, gaze_beta=0.01)
        else:
            run_loop(cap, detector)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        if detector is not None: detector.close()
        cap.release()

def read_face(cap, detector):
    """Grab a frame and run the landmarker.
    Returns (landmarks, eyeBlink score of the more closed eye, w, h, t_ms); both None without a face."""
    success, frame = cap.read()
    if not success:
        print("ERROR: Camera stopped delivering frames (unplugged or in use by another app?).", file=sys.stderr)
        sys.exit(1)

    h, w, _ = frame.shape
    t_ms = int(time.time() * 1000)

    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
    result = detector.detect_for_video(mp_image, t_ms)
    if not result.face_landmarks: return None, None, w, h, t_ms
    scores = {c.category_name: c.score for c in result.face_blendshapes[0]}
    return result.face_landmarks[0], max(scores['eyeBlinkLeft'], scores['eyeBlinkRight']), w, h, t_ms

def sample_face(cap, detector, frames=10):
    """Per-landmark median over the faces in the next few frames (a stray blink frame drops out), or None."""
    faces = [to_px(lms, w, h) for lms, _, w, h, _ in (read_face(cap, detector) for _ in range(frames))
             if lms is not None]
    return np.median(faces, axis=0) if faces else None

def calibrate(cap, detector, frames=10):
    """Wait for Enter (frames keep flowing), then lock the eye spheres from the next few faces."""
    print("[Calibrate] Look at the centre of your screen, keep your head still, then press Enter.", flush=True)
    while True:
        while not select.select([sys.stdin], [], [], 0)[0]:
            read_face(cap, detector)
        if not os.read(sys.stdin.fileno(), 1024):
            print("ERROR: stdin closed before calibration.", file=sys.stderr)
            sys.exit(1)
        P = sample_face(cap, detector, frames)
        if P is not None: break
        print("[Calibrate] No face visible. Face the camera and press Enter again.", flush=True)
    print("[Calibrate] Eye spheres locked.", flush=True)
    return EyeSpheres(P)

def recenter(cap, detector, monitor, raw):
    """Default mode's blink gesture: make the current pose the zero."""
    monitor.center(raw)
    print("[Tracking] Blink gesture: re-centred.", flush=True)

def run_loop(cap, detector, gaze=head_plus_iris, uncentered=(2,), recalibrate=recenter, gaze_beta=0.03):
    ot_client = OpenTrackClient()
    filters = [OneEuroFilter(freq=30, min_cutoff=0.05, beta=gaze_beta if i in (3, 4) else 0.03) for i in range(6)]
    monitor = StateMonitor(timeout_ms=LOST_TIMEOUT, auto_center=AUTO_CENTER, uncentered=uncentered)
    lids, blinks = EyeLids(), Blinks(RECALIBRATE_BLINKS)
    held = None  # last good (yaw, pitch), sent while blinking or when gaze is unusable

    print("Tracking Started (Ctrl+C to stop)", flush=True)

    while True:
        lms, blink_score, w, h, t_ms = read_face(cap, detector)
        hold, gesture = blinks.update(lids(blink_score, t_ms), t_ms)
        if monitor.is_lost: held = None
        
        has_face = False
        raw_telemetry = None
        R_mat_current = None
        
        if lms is not None:
            # 1. Pose Math
            nose_indices = [1, 2, 3, 4, 5, 6, 168, 197, 195]
            pts = np.array([[lms[i].x * w, lms[i].y * h, lms[i].z * w] for i in nose_indices])
            center = np.mean(pts, axis=0)
            
            # PCA/SVD Calculation
            _, _, Vt = np.linalg.svd(pts - center)
            R_mat_current = Vt.T
            
            # Initial deterministic check (Flip Z if determinant is negative)
            if np.linalg.det(R_mat_current) < 0: R_mat_current[:, 2] *= -1

            # --- CRITICAL: We pass R_mat_current to monitor.check below for stabilization ---
            # We delay Euler conversion until AFTER stabilization inside monitor.check?
            # Actually, to keep it clean, we should do stabilization HERE or pass it into monitor.
            # Let's rely on monitor.check to modify R_mat_current in place BEFORE we use it.

            # We need to perform stabilization BEFORE calculating Euler angles
            # Access the internal R_prev from monitor to fix R_mat_current immediately
            if monitor.R_prev is not None:
                for i in range(3):
                    if np.dot(R_mat_current[:, i], monitor.R_prev[:, i]) < 0:
                        R_mat_current[:, i] *= -1
            
            # Now R_mat_current is stable. We can safely convert to Euler.
            rot = Rscipy.from_matrix(R_mat_current)
            h_yaw, h_pitch, h_roll = rot.as_euler('yxz', degrees=True)
            
            angles = None if hold else gaze(lms, w, h, h_yaw, h_pitch)
            held = angles or held

            tx = (center[0] / w - 0.5) * SCALE_X * INV_X
            ty = (center[1] / h - 0.5) * SCALE_Y * INV_Y
            tz = (center[2] / w) * 100
            
            if held is not None:  # translation and roll keep updating while gaze is held
                has_face = True
                combined_yaw, combined_pitch = held
                raw_telemetry = [tx, ty, tz, combined_yaw, combined_pitch, h_roll * INV_ROL]
                if gesture: recalibrate(cap, detector, monitor, raw_telemetry)

        # 2. State Monitor Check
        # We pass R_mat_current so the monitor can save it as 'R_prev' for the next frame
        is_valid, processed_values = monitor.check(has_face, t_ms, raw_telemetry, filters, R_current=R_mat_current)
        
        if is_valid:
            filtered = [filters[i](processed_values[i]) for i in range(6)]
            ot_client.send(*filtered)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:  # Ctrl+C during camera probing
        print("\nStopped.")

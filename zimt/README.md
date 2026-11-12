# zimt

Head and eye tracking from a webcam, sent to [opentrack](https://github.com/opentrack/opentrack) over UDP. A Zig port of [immediate-tracking](..), with no Python: Zig drives MediaPipe's Face Landmarker through its C library and OpenCV's camera capture through a small C shim.

Runs on Linux (x86_64), macOS (Apple silicon) and Windows 11 (x86_64).

## Build

You need `make`, `curl`, `unzip`, a C++ compiler and the OpenCV development files:

| OS | Install |
| --- | --- |
| Fedora | `sudo dnf install make gcc-c++ opencv-devel` |
| Debian/Ubuntu | `sudo apt install make g++ pkg-config libopencv-dev` |
| macOS | `xcode-select --install`, then `brew install opencv pkg-config` |
| Windows 11 | Install [MSYS2](https://www.msys2.org), open its **UCRT64** shell, then `pacman -S make unzip mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-opencv` |

Then:

```
make
```

This downloads Zig 0.17.1 (unless that version is already on your PATH), MediaPipe's shared library (taken out of the official `mediapipe` 0.10.32 wheel) and the face model, checks their checksums, and builds everything into `dist/`.

## Run

```
make run
```

or run `dist/zimt` directly. Stop with Ctrl+C. On Windows, start it from the UCRT64 shell so OpenCV's DLLs are found.

In opentrack, choose "UDP over network" as input, port 4242.

For more accurate gaze, calibrate first:

```
make run ARGS=--calibrate
```

Look at the centre of your screen and press Enter when asked. To recalibrate later, look at the centre and blink three times quickly; without `--calibrate` this re-centres.

Other options: `--list-cameras`, `--print` (show every pose sent), `--source PATH` (track a video file), `--config PATH`, `--model PATH`.

## Settings

Edit `dist/settings.ini` (`make` creates it once and never overwrites it). By default the first working camera is used; set `name` or `index` under `[Camera]` to pick another. `zimt --list-cameras` prints the choices. Only one program can use a camera at a time.

## Differences from the Python tracker

- Head yaw and pitch always run the same way. In the Python tracker their direction depended on the signs numpy's SVD happened to return when a face was acquired, so it could invert from one acquisition to the next. zimt fixes the axes to the orientation in which head and eye movement add up under the default `invert_yaw`/`invert_pitch`.
- `[Camera] index` is the number `--list-cameras` prints: N of `/dev/videoN` on Linux, the DirectShow or AVFoundation device index on Windows and macOS.

## Layout

| Path | Contents |
| --- | --- |
| `src/tracker.zig` | the loop: frame, landmarks, pose, opentrack |
| `src/pose.zig`, `src/linalg.zig` | head frame, iris and eye-sphere gaze |
| `src/blink.zig`, `src/monitor.zig`, `src/filter.zig` | blink gesture, lost/reacquired state, One Euro filter |
| `src/mediapipe.zig` | MediaPipe C API binding |
| `src/capture.zig`, `shim/` | OpenCV capture through the C shim |
| `src/camera.zig`, `src/camera/` | camera selection; one enumeration backend per OS |
| `src/opentrack.zig` | UDP output |

`make test` runs the unit tests.

## License

MIT. See `LICENSE`. MediaPipe and the face model are Apache 2.0; OpenCV is Apache 2.0.

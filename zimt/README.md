# zimt

Head and eye tracking from a webcam, sent to [opentrack](https://github.com/opentrack/opentrack) over UDP. A Zig port of [immediate-tracking](..), with no Python: Zig drives MediaPipe's Face Landmarker through its C library and OpenCV's camera capture through a small C shim.

Runs on Linux (x86_64), macOS (Apple silicon) and Windows 11 (x86_64).

## Build

You need `make`, `curl`, `unzip` and `cmake`, and on macOS and Windows a C++ compiler; on Linux, Zig compiles the C++ as well. `nasm` is optional and makes JPEG decoding faster on x86_64.

| OS | Install |
| --- | --- |
| Fedora | `sudo dnf install make cmake nasm` |
| Debian/Ubuntu | `sudo apt install make cmake nasm curl unzip xz-utils` |
| macOS | `xcode-select --install`, then `brew install cmake` |
| Windows 11 | Install [MSYS2](https://www.msys2.org), open its **UCRT64** shell, then `pacman -S make unzip mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-nasm` |

Then:

```
make
```

This downloads Zig 0.17.1 (unless that version is already on your PATH), the OpenCV 4.14.0 source, MediaPipe's shared library (taken out of the official `mediapipe` 0.10.32 wheel) and the face model, checks their checksums, and builds everything into `dist/`. The first build takes several minutes, most of it compiling OpenCV.

OpenCV is built with only what zimt uses (camera capture, MJPEG decoding, colour conversion; no FFmpeg or GStreamer) and linked statically into `libzimt_cv`, so `dist/` runs without OpenCV installed. `dist/zimt.cdx.json` is a CycloneDX SBOM of everything in `dist/`, written by `sbom.sh` from the versions and checksums pinned in the `Makefile`.

## Run

```
make run
```

or run `dist/zimt` directly. Stop with Ctrl+C.

In opentrack, choose "UDP over network" as input, port 4242.

For more accurate gaze, calibrate first:

```
make run ARGS=--calibrate
```

Look at the centre of your screen and press Enter when asked. To recalibrate later, look at the centre and blink three times quickly; without `--calibrate` this re-centres.

Other options: `--list-cameras`, `--print` (show every pose sent), `--config PATH`, `--model PATH`.

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
| `sbom.sh` | writes the SBOM |
| `src/camera.zig`, `src/camera/` | camera selection; one enumeration backend per OS |
| `src/opentrack.zig` | UDP output |

`make test` runs the unit tests.

## Releases

GitHub Actions (`../.github/workflows/zimt.yml`) builds and tests every pull request and every push to `master` for Linux, macOS and Windows. To publish a release, set `.version` in `build.zig.zon`, merge, then push a matching tag:

```
git tag zimt-v0.1.0 && git push origin zimt-v0.1.0
```

The release gets one archive and one CycloneDX SBOM (`.cdx.json`) per platform, a `SHA256SUMS` file and a signed build provenance; check a download with `gh attestation verify FILE --repo Redpill-Linpro/jonatan-billy-eyetrack-labb`.

The archives need nothing installed. The Linux one runs on any distribution with glibc 2.28 or newer, the same as MediaPipe's library.

All three are built in one [SUSE Linux Base Container Image](https://registry.suse.com) pinned by digest, where Zig is the only compiler: `make package TARGET=x86_64-windows` (or `x86_64-linux`, `aarch64-macos`) cross-compiles a release archive into `pkg/`. Only the macOS camera library is built on a Mac, because it needs Apple's SDK. Each archive is then started once on its own platform.

## License

MIT. See `LICENSE`. MediaPipe, the face model and OpenCV are Apache 2.0; `dist/licenses/` has the licences of OpenCV and the libjpeg-turbo and zlib built into it.

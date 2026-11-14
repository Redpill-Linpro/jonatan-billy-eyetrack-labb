#!/bin/sh
# Writes the CycloneDX 1.6 SBOM of one platform's dist/ directory to stdout.
# Run by the Makefile, which passes the pinned versions, URLs and checksums in
# the environment; hashes of the built files are taken from dist/.
set -eu

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
hash() { printf '[{"alg": "SHA-256", "content": "%s"}]' "$1"; }
# download URL SHA256: where a component came from, and the checksum it was verified against.
download() { printf '[{"type": "distribution", "url": "%s", "hashes": %s}]' "$1" "$(hash "$2")"; }

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
jpeg_version=$(sed -n 's/^set(VERSION \(.*\))$/\1/p' "$OPENCV_SRC/3rdparty/libjpeg-turbo/CMakeLists.txt")
zlib_version=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"$/\1/p' "$OPENCV_SRC/3rdparty/zlib/zlib.h")
for v in "$version" "$jpeg_version" "$zlib_version"; do
    [ -n "$v" ] || { echo "sbom.sh: could not read a component version" >&2; exit 1; }
done

repo=https://github.com/Redpill-Linpro/jonatan-billy-eyetrack-labb
shim_parts='"opencv"'
windows_runtime=
if [ -n "$ZIGCC" ]; then
    # Built with zig c++, which links its libc++ into the shim.
    shim_parts='"opencv", "zig"'
elif [ "$OS" = windows ]; then
    # Built with MSYS2's GCC and linked with -static, so these are inside the DLL.
    gcc_version=$(c++ -dumpfullversion)
    mingw_version=$(printf '#include <_mingw.h>\n__MINGW64_VERSION_STR\n' | c++ -E -P -x c - | tr -d '" \r' | tail -n 1)
    shim_parts='"opencv", "gcc-runtime", "mingw-w64"'
    windows_runtime=$(cat <<EOF
    {
      "type": "library", "bom-ref": "gcc-runtime", "name": "gcc-libs", "version": "$gcc_version",
      "description": "GCC runtime libraries (libstdc++, libgcc), linked statically into libzimt_cv",
      "licenses": [{"expression": "GPL-3.0-or-later WITH GCC-exception-3.1"}],
      "externalReferences": [{"type": "website", "url": "https://gcc.gnu.org"}]
    },
    {
      "type": "library", "bom-ref": "mingw-w64", "name": "mingw-w64", "version": "$mingw_version",
      "description": "MinGW-w64 C runtime and winpthreads, linked statically into libzimt_cv",
      "licenses": [{"license": {"name": "MinGW-w64 runtime licence (ZPL-2.1 and others)"}}],
      "externalReferences": [{"type": "website", "url": "https://www.mingw-w64.org"}]
    },
EOF
)
fi

cat <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "version": 1,
  "metadata": {
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "lifecycles": [{"phase": "build"}],
    "supplier": {"name": "$SUPPLIER"},
    "component": {
      "type": "application", "bom-ref": "zimt", "name": "zimt", "version": "$version",
      "description": "Webcam head and eye tracking for opentrack ($PLATFORM build)",
      "supplier": {"name": "$SUPPLIER"},
      "licenses": [{"license": {"id": "MIT"}}],
      "externalReferences": [{"type": "vcs", "url": "$repo"}]
    }
  },
  "components": [
    {
      "type": "file", "bom-ref": "zimt-exe", "name": "zimt$EXE", "version": "$version",
      "hashes": $(hash "$(sha256 "$DIST/zimt$EXE")")
    },
    {
      "type": "file", "bom-ref": "zimt-cv", "name": "libzimt_cv$SO", "version": "$version",
      "description": "zimt's C interface to OpenCV, with OpenCV linked in statically",
      "hashes": $(hash "$(sha256 "$DIST/libzimt_cv$SO")")
    },
    {
      "type": "library", "bom-ref": "zig", "name": "zig", "version": "$ZIG_VERSION",
      "description": "Zig toolchain; its standard library and compiler runtime are compiled into zimt$EXE and, where Zig is the C++ compiler (Linux and Windows releases), its libc++ and C runtime startup code into libzimt_cv$SO",
      "licenses": [{"license": {"id": "MIT"}}],
      "externalReferences": $(download "$ZIG_URL" "$ZIG_SHA256")
    },
    {
      "type": "library", "bom-ref": "opencv", "name": "opencv", "version": "$OPENCV_VERSION",
      "description": "Built from source with only core, imgproc, imgcodecs (JPEG) and videoio (native camera backend); no FFmpeg or GStreamer",
      "licenses": [{"license": {"id": "Apache-2.0"}}],
      "cpe": "cpe:2.3:a:opencv:opencv:$OPENCV_VERSION:*:*:*:*:*:*:*",
      "purl": "pkg:github/opencv/opencv@$OPENCV_VERSION",
      "externalReferences": $(download "$OPENCV_URL" "$OPENCV_SHA256")
    },
    {
      "type": "library", "bom-ref": "libjpeg-turbo", "name": "libjpeg-turbo", "version": "$jpeg_version",
      "description": "Copy bundled in the OpenCV source (3rdparty/libjpeg-turbo)",
      "licenses": [{"expression": "IJG AND BSD-3-Clause AND Zlib"}],
      "cpe": "cpe:2.3:a:libjpeg-turbo:libjpeg-turbo:$jpeg_version:*:*:*:*:*:*:*",
      "purl": "pkg:github/libjpeg-turbo/libjpeg-turbo@$jpeg_version"
    },
    {
      "type": "library", "bom-ref": "zlib", "name": "zlib", "version": "$zlib_version",
      "description": "Copy bundled in the OpenCV source (3rdparty/zlib)",
      "licenses": [{"license": {"id": "Zlib"}}],
      "cpe": "cpe:2.3:a:zlib:zlib:$zlib_version:*:*:*:*:*:*:*",
      "purl": "pkg:github/madler/zlib@v$zlib_version"
    },
$windows_runtime
    {
      "type": "library", "bom-ref": "mediapipe", "name": "mediapipe", "version": "$MEDIAPIPE_VERSION",
      "description": "libmediapipe$SO, the prebuilt C library taken unmodified from the official Python wheel; the libraries linked inside it are not listed",
      "licenses": [{"license": {"id": "Apache-2.0"}}],
      "purl": "pkg:pypi/mediapipe@$MEDIAPIPE_VERSION",
      "hashes": $(hash "$(sha256 "$DIST/libmediapipe$SO")"),
      "externalReferences": $(download "$WHEEL_URL" "$WHEEL_SHA256")
    },
    {
      "type": "machine-learning-model", "bom-ref": "face-landmarker", "name": "face_landmarker.task", "version": "float16/1",
      "description": "MediaPipe Face Landmarker model",
      "licenses": [{"license": {"id": "Apache-2.0"}}],
      "hashes": $(hash "$(sha256 "$DIST/face_landmarker.task")"),
      "externalReferences": $(download "$MODEL_URL" "$MODEL_SHA256")
    }
  ],
  "dependencies": [
    {"ref": "zimt", "dependsOn": ["zimt-exe", "zimt-cv", "mediapipe", "face-landmarker"]},
    {"ref": "zimt-exe", "dependsOn": ["zig"]},
    {"ref": "zimt-cv", "dependsOn": [$shim_parts]},
    {"ref": "opencv", "dependsOn": ["libjpeg-turbo", "zlib"]}
  ]
}
EOF

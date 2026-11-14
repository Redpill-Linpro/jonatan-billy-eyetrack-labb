# zimt: webcam head and eye tracking for opentrack.
#
#   make            build everything into dist/
#   make run        build, then run dist/zimt (pass options with ARGS="--calibrate")
#   make test       run the unit tests
#   make package    build, then pack a release archive and its SBOM into pkg/
#   make clean      remove build output (keeps dist/settings.ini, downloads and the OpenCV build)
#   make distclean  also remove downloads, the OpenCV build and the local Zig toolchain
#
# Needs: make, curl, unzip and cmake, and on macOS and Windows a C++ compiler.
# Zig is downloaded if the right version is not on PATH. On Windows, run this
# from an MSYS2 UCRT64 shell.
#
# TARGET=x86_64-linux, x86_64-windows or aarch64-macos builds for another
# platform, into dist-$(TARGET)/. Linux and Windows cross-compile fully from
# Linux or macOS. The macOS shim needs Apple's SDK: build it on a Mac with
# `make shim` and copy it to dist-aarch64-macos/libzimt_cv.dylib first.
#
# Everything downloaded is pinned here by version and SHA-256, and listed in
# the SBOM (zimt.cdx.json) that sbom.sh writes from the same values.

ZIG_VERSION       := 0.17.1
MEDIAPIPE_VERSION := 0.10.32
OPENCV_VERSION    := 4.14.0
OPENCV_URL        := https://github.com/opencv/opencv/archive/refs/tags/$(OPENCV_VERSION).tar.gz
OPENCV_SHA256     := ee8fb9b30eb60850431b4656447080e3737b56e45719c92b67f245950609f86e
MODEL_URL         := https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
MODEL_SHA256      := 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
PYPI              := https://files.pythonhosted.org/packages
OPTIMIZE          ?= ReleaseSafe
# Named as the supplier in the SBOM.
SUPPLIER          ?= Redpill Linpro AB
# In the name of the release archive; the pipeline adds the commit to it.
VERSION           ?= $(shell sed -n 's/^ *\.version = "\(.*\)",$$/\1/p' build.zig.zon)

# --- Platform -----------------------------------------------------------------

UNAME_S   := $(shell uname -s)
UNAME_M   := $(shell uname -m)
HOST_ARCH := $(patsubst arm64,aarch64,$(patsubst amd64,x86_64,$(UNAME_M)))

ifeq ($(UNAME_S),Linux)
  HOST_OS := linux
else ifeq ($(UNAME_S),Darwin)
  HOST_OS := macos
else ifneq ($(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)),)
  HOST_OS := windows
else
  $(error Unsupported OS "$(UNAME_S)")
endif
HOST := $(HOST_ARCH)-$(HOST_OS)

# Zig runs on the build machine.
ifeq ($(HOST),x86_64-linux)
  ZIG_SHA256 := 3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
else ifeq ($(HOST),aarch64-macos)
  ZIG_SHA256 := 75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d
else ifeq ($(HOST),x86_64-windows)
  ZIG_SHA256 := b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e
else
  $(error No pinned Zig for $(HOST); supported: x86_64-linux, aarch64-macos, x86_64-windows)
endif
ZIG_ARCHIVE := zig-$(HOST)-$(ZIG_VERSION)$(if $(filter windows,$(HOST_OS)),.zip,.tar.xz)
ZIG_URL     := https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_ARCHIVE)

# What is built runs on TARGET. MediaPipe's shared library comes out of the
# official Python wheel for it; the wheel is only an archive here, Python is
# not involved. ZIG_TARGET names the oldest system that library runs on.
TARGET ?= $(HOST)
ifeq ($(TARGET),x86_64-linux)
  WHEEL        := e3/98/00cd8b2dcb563f2298655633e6611a791b2c1a7df1dae064b2b96084f1bf/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-manylinux_2_28_x86_64.whl
  WHEEL_SHA256 := 4b0941fbbbce41862f13cb1850c4878c13dbc62cd5e81e74880051b7a20ce3b6
  ZIG_TARGET   := x86_64-linux-gnu.2.28
  OS := linux
  SO := .so
else ifeq ($(TARGET),aarch64-macos)
  WHEEL        := 24/d9/ca1be234911c76ccd87a9e0d8210394153cb6ad9b5da65a231aff8769d6f/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-macosx_11_0_arm64.whl
  WHEEL_SHA256 := b62178b7585e0bb8789075c43bbb3e352fbc4a8f765797fded509f86a098b29b
  ZIG_TARGET   := aarch64-macos.11.0
  OS := macos
  SO := .dylib
else ifeq ($(TARGET),x86_64-windows)
  WHEEL        := fe/63/c9172142521fc334fa891be9ef6259a3790502041b395127d63755cb3f0b/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-win_amd64.whl
  WHEEL_SHA256 := 438d98977a4e1b0f88070ad16537a328912f847ce9debf236da047b0b483cbfd
  ZIG_TARGET   := x86_64-windows-gnu
  OS  := windows
  SO  := .dll
  EXE := .exe
else
  $(error MediaPipe $(MEDIAPIPE_VERSION) has no build for $(TARGET); supported: x86_64-linux, aarch64-macos, x86_64-windows)
endif

# --- Tools --------------------------------------------------------------------

# Use zig from PATH when it is the pinned version, else a private copy.
LOCAL_ZIG := .toolchain/zig-$(HOST)-$(ZIG_VERSION)/zig$(if $(filter windows,$(HOST_OS)),.exe)
ifeq ($(shell zig version 2>/dev/null),$(ZIG_VERSION))
  ZIG ?= zig
else
  ZIG ?= $(LOCAL_ZIG)
endif

CMAKE ?= cmake
JOBS  ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# OpenCV is built from source as static libraries and linked into the shim, so
# dist/ needs no OpenCV at run time. Only camera capture and colour conversion
# are built: no FFmpeg or GStreamer, no image formats except JPEG (many
# webcams deliver MJPEG), and nothing that CMake would download. The two
# bundled libraries this leaves, libjpeg-turbo and zlib, are in the SBOM.
OPENCV_SRC   := .deps/opencv-$(OPENCV_VERSION)
OPENCV_BUILD := .deps/opencv-$(OPENCV_VERSION)-build-$(TARGET)
OPENCV_OFF   := 1394 ADE AVIF CAROTENE DIRECTML DIRECTX EIGEN FASTCV FFMPEG FLATBUFFERS GSTREAMER GTK \
                IMGCODEC_GIF IMGCODEC_HDR IMGCODEC_PFM IMGCODEC_PXM IMGCODEC_SUNRASTER IPP ITT JASPER \
                JPEGXL KLEIDICV LAPACK MSMF OBSENSOR OPENCL OPENEXR OPENJPEG PNG PROTOBUF QUIRC TIFF \
                VA VA_INTEL VTK WEBP WIN32UI
CMAKE_FLAGS  := -DCMAKE_BUILD_TYPE=Release

# The C and C++ compiler for OpenCV and the shim:
#   - Zig, through the wrappers in .deps/zigcc-$(TARGET), for Linux and for
#     Windows built elsewhere. No other compiler is needed, the result does
#     not depend on what the build machine has installed, and Zig's libc++ is
#     linked into the shim statically.
#   - The platform's own compiler on macOS, whose camera API needs Apple's
#     SDK, and for Windows built on Windows.
ifeq ($(OS),macos)
  ifeq ($(HOST_OS),macos)
    CMAKE_FLAGS += -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
  else
    SHIM_PREBUILT := 1
  endif
else ifneq ($(OS),$(HOST_OS))
  ifeq ($(HOST_OS),windows)
    $(error Building for $(TARGET) on Windows is not supported; build on Linux or macOS)
  endif
  USE_ZIGCC := 1
  CMAKE_FLAGS += -DCMAKE_SYSTEM_NAME=$(if $(filter windows,$(OS)),Windows,Linux) \
                 -DCMAKE_SYSTEM_PROCESSOR=$(if $(filter windows,$(OS)),AMD64,x86_64)
else ifeq ($(OS),linux)
  USE_ZIGCC := 1
endif
ifdef USE_ZIGCC
  ZIGCC       := $(abspath .deps/zigcc-$(TARGET))
  ZIGCC_TOOLS := $(addprefix .deps/zigcc-$(TARGET)/,cc c++ ar ranlib rc)
  CMAKE_FLAGS += -DCMAKE_C_COMPILER=$(ZIGCC)/cc -DCMAKE_CXX_COMPILER=$(ZIGCC)/c++ \
                 -DCMAKE_AR=$(ZIGCC)/ar -DCMAKE_RANLIB=$(ZIGCC)/ranlib -DCMAKE_RC_COMPILER=$(ZIGCC)/rc
endif
OPENCV_FLAGS := $(CMAKE_FLAGS) -DBUILD_LIST=core,imgproc,imgcodecs,videoio -DBUILD_SHARED_LIBS=OFF \
                -DBUILD_ZLIB=ON -DBUILD_JPEG=ON -DWITH_JPEG=ON -DWITH_V4L=ON -DWITH_DSHOW=ON -DWITH_AVFOUNDATION=ON \
                $(foreach x,$(OPENCV_OFF),-DWITH_$(x)=OFF) \
                $(foreach x,TESTS PERF_TESTS EXAMPLES DOCS JAVA ITT opencv_apps,-DBUILD_$(x)=OFF) \
                -DCV_TRACE=OFF -DENABLE_CCACHE=OFF -DOPENCV_GENERATE_SETUPVARS=OFF

SHA256 := $(if $(shell command -v sha256sum 2>/dev/null),sha256sum,shasum -a 256)
# $(call download,URL,SHA256,FILE)
define download
	@mkdir -p $(dir $(3))
	curl -fL --retry 3 -o $(3).part $(1)
	@echo "$(2)  $(3).part" | $(SHA256) -c - >/dev/null || { echo "Checksum mismatch for $(1)"; rm -f $(3).part; exit 1; }
	@mv $(3).part $(3)
endef

# --- Build --------------------------------------------------------------------

DIST    := $(if $(filter $(HOST),$(TARGET)),dist,dist-$(TARGET))
SHIM    := $(DIST)/libzimt_cv$(SO)
OUTPUTS := $(DIST)/zimt$(EXE) $(SHIM) $(DIST)/libmediapipe$(SO) $(DIST)/face_landmarker.task
SBOM    := $(DIST)/zimt.cdx.json
SOURCES := build.zig build.zig.zon $(wildcard src/*.zig src/*/*.zig)

.PHONY: all shim run test package clean distclean
all: $(OUTPUTS) $(SBOM) $(DIST)/licenses $(DIST)/settings.ini
shim: $(SHIM)

$(DIST)/zimt$(EXE): $(SOURCES) | $(ZIG)
	$(ZIG) build -Doptimize=$(OPTIMIZE) -Dtarget=$(ZIG_TARGET) --prefix $(DIST) --prefix-exe-dir .
	@touch $@

ifdef SHIM_PREBUILT
$(SHIM):
	@echo "$@ can only be built on macOS: run 'make shim' there and copy dist/libzimt_cv$(SO) to $@."; exit 1
else
$(SHIM): shim/zimt_cv.cpp shim/zimt_cv.h shim/zimt_cv.map shim/CMakeLists.txt $(OPENCV_BUILD)/.built $(ZIGCC_TOOLS)
	@mkdir -p $(DIST)
	$(CMAKE) -S shim -B zig-out/shim-$(TARGET) $(CMAKE_FLAGS) -DOPENCV_BUILD=$(OPENCV_BUILD)
	$(CMAKE) --build zig-out/shim-$(TARGET)
	cp zig-out/shim-$(TARGET)/libzimt_cv$(SO) $@
endif

$(OPENCV_BUILD)/.built: $(OPENCV_SRC)/CMakeLists.txt $(ZIGCC_TOOLS)
	$(CMAKE) -S $(OPENCV_SRC) -B $(OPENCV_BUILD) $(OPENCV_FLAGS)
	$(CMAKE) --build $(OPENCV_BUILD) --parallel $(JOBS)
	@touch $@

# zig cc, zig c++ and so on as single commands, which is what CMake wants.
$(ZIGCC_TOOLS): | $(ZIG)
	@mkdir -p $(dir $@)
	printf '#!/bin/sh\nexec "%s" %s %s "$$@"\n' '$(if $(findstring /,$(ZIG)),$(abspath $(ZIG)),$(ZIG))' \
		'$(notdir $@)' '$(if $(filter cc c++,$(notdir $@)),-target $(ZIG_TARGET))' > $@
	@chmod +x $@

$(OPENCV_SRC)/CMakeLists.txt: .deps/opencv-$(OPENCV_VERSION).tar.gz
	tar -xzf $< -C .deps
	@touch $@

$(DIST)/libmediapipe$(SO): .deps/$(notdir $(WHEEL))
	@mkdir -p $(DIST)
	unzip -q -j -o $< 'mediapipe/tasks/c/libmediapipe$(SO)' -d $(DIST)
	@touch $@

$(DIST)/face_landmarker.task: .deps/face_landmarker.task
	@mkdir -p $(DIST)
	cp $< $@

# Licences of what is shipped. OpenCV's licence file is the Apache 2.0 text,
# which is also the licence of MediaPipe and the model.
$(DIST)/licenses: $(OPENCV_SRC)/CMakeLists.txt
	@mkdir -p $@
	cp $(OPENCV_SRC)/LICENSE $@/opencv.txt
	cp $(OPENCV_SRC)/LICENSE $@/mediapipe.txt
	cp $(OPENCV_SRC)/3rdparty/libjpeg-turbo/LICENSE.md $@/libjpeg-turbo.md
	cp $(OPENCV_SRC)/3rdparty/zlib/LICENSE $@/zlib.txt
	@touch $@

$(SBOM): sbom.sh build.zig.zon Makefile $(OUTPUTS) $(OPENCV_SRC)/CMakeLists.txt
	OS='$(OS)' PLATFORM='$(TARGET)' ZIGCC='$(USE_ZIGCC)' DIST='$(DIST)' EXE='$(EXE)' SO='$(SO)' SUPPLIER='$(SUPPLIER)' \
	ZIG_VERSION='$(ZIG_VERSION)' ZIG_URL='$(ZIG_URL)' ZIG_SHA256='$(ZIG_SHA256)' \
	OPENCV_VERSION='$(OPENCV_VERSION)' OPENCV_URL='$(OPENCV_URL)' OPENCV_SHA256='$(OPENCV_SHA256)' OPENCV_SRC='$(OPENCV_SRC)' \
	MEDIAPIPE_VERSION='$(MEDIAPIPE_VERSION)' WHEEL_URL='$(PYPI)/$(WHEEL)' WHEEL_SHA256='$(WHEEL_SHA256)' \
	MODEL_URL='$(MODEL_URL)' MODEL_SHA256='$(MODEL_SHA256)' \
	sh sbom.sh > $@.part
	@mv $@.part $@

# Yours to edit: only created when missing.
$(DIST)/settings.ini:
	@mkdir -p $(DIST)
	cp settings.ini $@

.deps/$(notdir $(WHEEL)):
	$(call download,$(PYPI)/$(WHEEL),$(WHEEL_SHA256),$@)

.deps/opencv-$(OPENCV_VERSION).tar.gz:
	$(call download,$(OPENCV_URL),$(OPENCV_SHA256),$@)

.deps/face_landmarker.task:
	$(call download,$(MODEL_URL),$(MODEL_SHA256),$@)

$(LOCAL_ZIG):
	$(call download,$(ZIG_URL),$(ZIG_SHA256),.toolchain/$(ZIG_ARCHIVE))
	cd .toolchain && $(if $(filter %.zip,$(ZIG_ARCHIVE)),unzip -q -o,tar -xf) $(ZIG_ARCHIVE)
	@rm -f .toolchain/$(ZIG_ARCHIVE)
	@touch $@

run: all
	$(DIST)/zimt$(EXE) $(ARGS)

# pkg/zimt-VERSION-TARGET.tar.gz (.zip for Windows) and, beside it, its SBOM.
PKG := zimt-$(VERSION)-$(TARGET)
package: all
	rm -rf pkg/$(PKG) && mkdir -p pkg/$(PKG)
	cp -R $(DIST)/. pkg/$(PKG)/
	rm -f pkg/$(PKG)/*.pdb
	cp LICENSE README.md pkg/$(PKG)/
	cp $(SBOM) pkg/$(PKG).cdx.json
	cd pkg && $(if $(filter windows,$(OS)),$(CMAKE) -E tar cf $(PKG).zip --format=zip $(PKG),tar -czf $(PKG).tar.gz $(PKG))
	rm -rf pkg/$(PKG)

test: | $(ZIG)
	$(ZIG) build test --summary all

clean:
	rm -rf .zig-cache zig-out pkg $(OUTPUTS) $(SBOM) $(DIST)/licenses $(DIST)/zimt.pdb

distclean: clean
	rm -rf .deps .toolchain dist dist-*

# zimt: webcam head and eye tracking for opentrack.
#
#   make            build everything into dist/
#   make run        build, then run dist/zimt (pass options with ARGS="--calibrate")
#   make test       run the unit tests
#   make clean      remove build output (keeps dist/settings.ini and downloads)
#   make distclean  also remove downloads and the local Zig toolchain
#
# Needs: make, curl, unzip, a C++ compiler and the OpenCV development files
# (pkg-config name "opencv4"). Zig is downloaded if the right version is not
# on PATH. On Windows, run this from an MSYS2 UCRT64 shell.

ZIG_VERSION       := 0.17.1
MEDIAPIPE_VERSION := 0.10.32
MODEL_URL         := https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
MODEL_SHA256      := 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
PYPI              := https://files.pythonhosted.org/packages
OPTIMIZE          ?= ReleaseSafe

# --- Platform -----------------------------------------------------------------

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ARCH    := $(patsubst arm64,aarch64,$(patsubst amd64,x86_64,$(UNAME_M)))

ifeq ($(UNAME_S),Linux)
  OS := linux
else ifeq ($(UNAME_S),Darwin)
  OS := macos
else ifneq ($(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)),)
  OS := windows
else
  $(error Unsupported OS "$(UNAME_S)")
endif
PLATFORM := $(ARCH)-$(OS)

# MediaPipe's shared library comes out of the official Python wheel for the
# platform; the wheel is only an archive here, Python is not involved.
ifeq ($(PLATFORM),x86_64-linux)
  WHEEL        := e3/98/00cd8b2dcb563f2298655633e6611a791b2c1a7df1dae064b2b96084f1bf/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-manylinux_2_28_x86_64.whl
  WHEEL_SHA256 := 4b0941fbbbce41862f13cb1850c4878c13dbc62cd5e81e74880051b7a20ce3b6
  ZIG_SHA256   := 3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
else ifeq ($(PLATFORM),aarch64-macos)
  WHEEL        := 24/d9/ca1be234911c76ccd87a9e0d8210394153cb6ad9b5da65a231aff8769d6f/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-macosx_11_0_arm64.whl
  WHEEL_SHA256 := b62178b7585e0bb8789075c43bbb3e352fbc4a8f765797fded509f86a098b29b
  ZIG_SHA256   := 75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d
else ifeq ($(PLATFORM),x86_64-windows)
  WHEEL        := fe/63/c9172142521fc334fa891be9ef6259a3790502041b395127d63755cb3f0b/mediapipe-$(MEDIAPIPE_VERSION)-py3-none-win_amd64.whl
  WHEEL_SHA256 := 438d98977a4e1b0f88070ad16537a328912f847ce9debf236da047b0b483cbfd
  ZIG_SHA256   := b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e
else
  $(error MediaPipe $(MEDIAPIPE_VERSION) has no build for $(PLATFORM); supported: x86_64-linux, aarch64-macos, x86_64-windows)
endif

ifeq ($(OS),windows)
  EXE := .exe
  SO  := .dll
  ZIG_ARCHIVE := zig-$(PLATFORM)-$(ZIG_VERSION).zip
else ifeq ($(OS),macos)
  EXE :=
  SO  := .dylib
  ZIG_ARCHIVE := zig-$(PLATFORM)-$(ZIG_VERSION).tar.xz
else
  EXE :=
  SO  := .so
  ZIG_ARCHIVE := zig-$(PLATFORM)-$(ZIG_VERSION).tar.xz
endif

# --- Tools --------------------------------------------------------------------

# Use zig from PATH when it is the pinned version, else a private copy.
LOCAL_ZIG := .toolchain/zig-$(PLATFORM)-$(ZIG_VERSION)/zig$(EXE)
ifeq ($(shell zig version 2>/dev/null),$(ZIG_VERSION))
  ZIG ?= zig
else
  ZIG ?= $(LOCAL_ZIG)
endif

CXX        ?= c++
PKG_CONFIG ?= pkg-config
OPENCV_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags opencv4)
# Only the modules the shim uses, not everything pkg-config lists.
OPENCV_LIBS   ?= $(shell $(PKG_CONFIG) --libs-only-L opencv4) -lopencv_videoio -lopencv_imgproc -lopencv_core

SHA256 := $(if $(shell command -v sha256sum 2>/dev/null),sha256sum,shasum -a 256)
# $(call download,URL,SHA256,FILE)
define download
	@mkdir -p $(dir $(3))
	curl -fL --retry 3 -o $(3).part $(1)
	@echo "$(2)  $(3).part" | $(SHA256) -c - >/dev/null || { echo "Checksum mismatch for $(1)"; rm -f $(3).part; exit 1; }
	@mv $(3).part $(3)
endef

# --- Build --------------------------------------------------------------------

DIST    := dist
OUTPUTS := $(DIST)/zimt$(EXE) $(DIST)/libzimt_cv$(SO) $(DIST)/libmediapipe$(SO) $(DIST)/face_landmarker.task
SOURCES := build.zig build.zig.zon $(wildcard src/*.zig src/*/*.zig)

.PHONY: all run test clean distclean
all: $(OUTPUTS) $(DIST)/settings.ini

$(DIST)/zimt$(EXE): $(SOURCES) | $(ZIG)
	$(ZIG) build -Doptimize=$(OPTIMIZE) --prefix $(DIST) --prefix-exe-dir .
	@touch $@

$(DIST)/libzimt_cv$(SO): shim/zimt_cv.cpp shim/zimt_cv.h
	@mkdir -p $(DIST)
	@$(PKG_CONFIG) --exists opencv4 || [ -n "$(OPENCV_CFLAGS)" ] || { echo "OpenCV development files not found (pkg-config opencv4). See README.md."; exit 1; }
	$(CXX) -std=c++17 -O2 -fPIC -fvisibility=hidden -shared -o $@ shim/zimt_cv.cpp $(OPENCV_CFLAGS) $(OPENCV_LIBS)

$(DIST)/libmediapipe$(SO): .deps/$(notdir $(WHEEL))
	@mkdir -p $(DIST)
	unzip -q -j -o $< 'mediapipe/tasks/c/libmediapipe$(SO)' -d $(DIST)
	@touch $@

$(DIST)/face_landmarker.task: .deps/face_landmarker.task
	@mkdir -p $(DIST)
	cp $< $@

# Yours to edit: only created when missing.
$(DIST)/settings.ini:
	@mkdir -p $(DIST)
	cp settings.ini $@

.deps/$(notdir $(WHEEL)):
	$(call download,$(PYPI)/$(WHEEL),$(WHEEL_SHA256),$@)

.deps/face_landmarker.task:
	$(call download,$(MODEL_URL),$(MODEL_SHA256),$@)

$(LOCAL_ZIG):
	$(call download,https://ziglang.org/download/$(ZIG_VERSION)/$(ZIG_ARCHIVE),$(ZIG_SHA256),.toolchain/$(ZIG_ARCHIVE))
	cd .toolchain && $(if $(filter %.zip,$(ZIG_ARCHIVE)),unzip -q -o,tar -xf) $(ZIG_ARCHIVE)
	@rm -f .toolchain/$(ZIG_ARCHIVE)
	@touch $@

run: all
	$(DIST)/zimt$(EXE) $(ARGS)

test: | $(ZIG)
	$(ZIG) build test --summary all

clean:
	rm -rf .zig-cache zig-out $(OUTPUTS) $(DIST)/zimt.pdb

distclean: clean
	rm -rf .deps .toolchain $(DIST)

/* C interface to the part of OpenCV zimt uses: opening a camera and reading
 * RGB frames. Built by the Makefile into a shared library that contains OpenCV and loaded by zimt
 * at run time. */
#ifndef ZIMT_CV_H
#define ZIMT_CV_H

#include <stdint.h>

#if defined(_WIN32)
#define ZIMT_CV_EXPORT __declspec(dllexport)
#else
#define ZIMT_CV_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped whenever this interface changes; checked by src/capture.zig. */
#define ZIMT_CV_ABI 2
ZIMT_CV_EXPORT int zimt_cv_abi(void);

typedef struct zimt_cap zimt_cap;

/* Camera `index` of the OpenCV backend `opencv_api` (cv::VideoCaptureAPIs).
 * NULL if it cannot be opened. */
ZIMT_CV_EXPORT zimt_cap *zimt_cap_open_index(int index, int opencv_api);

/* Reads the next frame as tightly packed RGB (width * height * 3 bytes),
 * valid until the next call on this capture. Returns 1, or 0 when there is
 * no frame. */
ZIMT_CV_EXPORT int zimt_cap_read(zimt_cap *cap, const uint8_t **rgb, int *width, int *height);

ZIMT_CV_EXPORT void zimt_cap_close(zimt_cap *cap);

#ifdef __cplusplus
}
#endif

#endif

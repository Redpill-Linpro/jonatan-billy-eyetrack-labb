#include "zimt_cv.h"

#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>

struct zimt_cap {
    cv::VideoCapture capture;
    cv::Mat frame;
    cv::Mat rgb;
};

int zimt_cv_abi(void) { return ZIMT_CV_ABI; }

template <typename Open>
static zimt_cap *open_with(Open open) {
    zimt_cap *cap = nullptr;
    try {
        cap = new zimt_cap;
        if (open(cap->capture) && cap->capture.isOpened()) return cap;
    } catch (...) {
    }
    delete cap;
    return nullptr;
}

zimt_cap *zimt_cap_open_index(int index, int opencv_api) {
    return open_with([&](cv::VideoCapture &c) { return c.open(index, opencv_api); });
}

zimt_cap *zimt_cap_open_path(const char *path) {
    return open_with([&](cv::VideoCapture &c) { return c.open(cv::String(path), cv::CAP_ANY); });
}

int zimt_cap_read(zimt_cap *cap, const uint8_t **rgb, int *width, int *height) {
    try {
        if (!cap->capture.read(cap->frame) || cap->frame.empty()) return 0;
        switch (cap->frame.channels()) {
        case 3: cv::cvtColor(cap->frame, cap->rgb, cv::COLOR_BGR2RGB); break;
        case 4: cv::cvtColor(cap->frame, cap->rgb, cv::COLOR_BGRA2RGB); break;
        case 1: cv::cvtColor(cap->frame, cap->rgb, cv::COLOR_GRAY2RGB); break;
        default: return 0;
        }
        if (cap->rgb.depth() != CV_8U || !cap->rgb.isContinuous()) return 0;
        *rgb = cap->rgb.data;
        *width = cap->rgb.cols;
        *height = cap->rgb.rows;
        return 1;
    } catch (...) {
        return 0;
    }
}

void zimt_cap_close(zimt_cap *cap) {
    try {
        delete cap;
    } catch (...) {
    }
}

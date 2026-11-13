// stage.h — cascaded 2× halfband interpolation stage.
//
// A single polyphase kernel at 256× upsampling is far too expensive: it must be
// long enough to reject images right at the source Nyquist. Splitting the ratio
// into 2× stages fixes that, because each stage only has to suppress images
// above half its output Nyquist — a wide transition band needing ~33 taps.
//
// Both output phases are sums over the same delay line, mirroring the standard
// polyphase decomposition of zero-stuffed interpolation:
//     y[2m]   = sum_k h[2k]   * x[m-k]
//     y[2m+1] = sum_k h[2k+1] * x[m-k]
// A halfband kernel has one non-zero even tap, so phase 0 costs one multiply
// and phase 1 about sixteen.
#pragma once

#include "util.h"

#include <cmath>
#include <vector>

namespace cant {

class Halfband2x {
public:
    Halfband2x() { design(); }

    void reset() {
        z_.assign(L_, 0.0);
        pos_ = 0;
    }

    // Interpolates `n` samples into `out`, which must hold 2*n values.
    void process(const float* in, int n, std::vector<double>& out) {
        out.resize(static_cast<size_t>(n) * 2);
        for (int i = 0; i < n; ++i) run(static_cast<double>(in[i]),
                                        &out[static_cast<size_t>(i) * 2]);
    }

    void process(const double* in, int n, std::vector<double>& out) {
        out.resize(static_cast<size_t>(n) * 2);
        for (int i = 0; i < n; ++i) run(in[i], &out[static_cast<size_t>(i) * 2]);
    }

    // Group delay in input samples (half the kernel centre).
    static int latency() { return (L_ - 1) / 2 - ((L_ - 1) / 2) / 2; }

private:
    static constexpr int L_ = 65;

    void design() {
        std::vector<double> h(L_, 0.0);
        const double c = (L_ - 1) / 2.0;
        for (int i = 0; i < L_; ++i) {
            const double d = i - c;
            h[i] = 0.5 * sinc(0.5 * d) * window_at(2, d / c);   // Kaiser window
        }
        double sum = 0.0;
        for (double v : h) sum += v;
        for (double& v : h) v *= 2.0 / sum;    // unity gain through zero-stuffing

        int centreK = 0;
        double centreV = 0.0;
        for (int k = 0; k <= (L_ - 1) / 2; ++k) {
            if (std::fabs(h[2 * k]) > std::fabs(centreV)) { centreV = h[2 * k]; centreK = k; }
        }
        centreDelay_ = centreK;
        centreGain_ = centreV;

        odd_.clear();
        for (int k = 0; k <= (L_ - 1) / 2; ++k) {
            const double v = h[2 * k + 1 < L_ ? 2 * k + 1 : L_ - 1];
            if (2 * k + 1 >= L_) break;
            if (std::fabs(v) < 1e-9) continue;
            odd_.push_back({k, v});
        }
        reset();
    }

    inline void run(double x, double* out2) {
        z_[pos_] = x;
        const int newest = pos_;
        pos_ = (pos_ + 1) % L_;

        // x[m-k] lives at (newest - k) modulo L.
        int idx = newest - centreDelay_;
        if (idx < 0) idx += L_;
        out2[0] = centreGain_ * z_[idx];

        double acc = 0.0;
        for (const auto& t : odd_) {
            int j = newest - t.delay;
            if (j < 0) j += L_;
            acc += t.coeff * z_[j];
        }
        out2[1] = acc;
    }

    struct Tap { int delay; double coeff; };
    std::vector<Tap> odd_;
    std::vector<double> z_;
    int pos_ = 0;
    int centreDelay_ = 0;
    double centreGain_ = 0.5;
};

}  // namespace cant

// util.h — shared numeric helpers for the Cantus DSP core.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace cant {

inline double sinc(double x) {
    if (std::fabs(x) < 1e-12) return 1.0;
    return std::sin(M_PI * x) / (M_PI * x);
}

inline double bessel_i0(double x) {
    double sum = 1.0, term = 1.0, k = 1.0;
    const double x2 = x * x / 4.0;
    for (int i = 0; i < 256; ++i) {
        term *= x2 / (k * k);
        sum += term;
        if (term < sum * 1e-17) break;
        k += 1.0;
    }
    return sum;
}

// x is normalised to [-1, 1].
inline double window_at(int which, double x) {
    x = std::max(-1.0, std::min(1.0, x));
    switch (which) {
        case 0: return 1.0;                                  // rectangular
        case 1: {                                            // gaussian
            const double a = 2.6;
            return std::exp(-0.5 * (a * x) * (a * x));
        }
        case 2: {                                            // kaiser
            const double beta = 9.0;
            const double r = std::sqrt(std::max(0.0, 1.0 - x * x));
            return bessel_i0(beta * r) / bessel_i0(beta);
        }
        case 3: {                                            // blackman-harris
            const double y = M_PI * (x + 1.0);
            return 0.35875 - 0.48829 * std::cos(y) + 0.14128 * std::cos(2.0 * y) -
                   0.01168 * std::cos(3.0 * y);
        }
        case 4: return sinc(x);                               // lanczos
        default: return 1.0;
    }
}

inline void fft_radix2(std::vector<double>& re, std::vector<double>& im, bool inverse) {
    const std::size_t n = re.size();
    if (n < 2) return;
    for (std::size_t i = 1, j = 0; i < n; ++i) {
        std::size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (std::size_t len = 2; len <= n; len <<= 1) {
        const double ang = 2.0 * M_PI / static_cast<double>(len) * (inverse ? 1.0 : -1.0);
        const double wr = std::cos(ang), wi = std::sin(ang);
        for (std::size_t i = 0; i < n; i += len) {
            double cr = 1.0, ci = 0.0;
            for (std::size_t k = 0; k < len / 2; ++k) {
                const double ur = re[i + k], ui = im[i + k];
                const double vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
                const double vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
                re[i + k] = ur + vr;
                im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr;
                im[i + k + len / 2] = ui - vi;
                const double ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
    if (inverse) {
        for (std::size_t i = 0; i < n; ++i) { re[i] /= static_cast<double>(n); im[i] /= static_cast<double>(n); }
    }
}

inline std::size_t next_pow2(std::size_t n) {
    std::size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

}  // namespace cant

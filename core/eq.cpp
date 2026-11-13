// eq.cpp — parametric biquad equaliser (RBJ cookbook coefficients).
#include "cantus_core.h"
#include "util.h"

#include <cmath>
#include <vector>

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;   // transposed direct form II, per channel
};

struct EqBand {
    int type = 0;
    double freq = 1000, gain = 0, q = 1.0;
    int enabled = 0;
};

struct CEq {
    int channels = 2, bands = 0, enabled = 1;
    std::vector<EqBand> band;
    std::vector<Biquad> coeff;   // [band][channel]
};

extern "C" CEq* eq_new(int channels, int bands) {
    CEq* e = new CEq();
    e->channels = channels < 1 ? 1 : channels;
    e->bands = bands < 0 ? 0 : bands;
    e->band.resize(e->bands);
    e->coeff.assign(static_cast<size_t>(e->bands) * e->channels, Biquad());
    return e;
}

extern "C" void eq_free(CEq* e) { delete e; }

extern "C" void eq_reset(CEq* e) {
    if (!e) return;
    for (auto& b : e->coeff) { b.z1 = b.z2 = 0.0; }
}

extern "C" void eq_set_eq_enabled(CEq* e, int enabled) { if (e) e->enabled = enabled; }
extern "C" int eq_get_band_count(CEq* e) { return e ? e->bands : 0; }

static void design(Biquad& bq, int type, double f, double gain_db, double q, double fs) {
    const double A = std::pow(10.0, gain_db / 40.0);
    const double w0 = 2.0 * M_PI * std::min(f, fs * 0.49) / fs;
    const double cs = std::cos(w0), sn = std::sin(w0);
    const double alpha = sn / (2.0 * (q < 0.05 ? 0.05 : q));

    double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (type) {
        case 0:  // peaking
            b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A;
            a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A;
            break;
        case 1: {  // low shelf
            const double s = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) - (A - 1) * cs + s);
            b1 = 2 * A * ((A - 1) - (A + 1) * cs);
            b2 = A * ((A + 1) - (A - 1) * cs - s);
            a0 = (A + 1) + (A - 1) * cs + s;
            a1 = -2 * ((A - 1) + (A + 1) * cs);
            a2 = (A + 1) + (A - 1) * cs - s;
            break;
        }
        case 2: {  // high shelf
            const double s = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) + (A - 1) * cs + s);
            b1 = -2 * A * ((A - 1) + (A + 1) * cs);
            b2 = A * ((A + 1) + (A - 1) * cs - s);
            a0 = (A + 1) - (A - 1) * cs + s;
            a1 = 2 * ((A - 1) - (A + 1) * cs);
            a2 = (A + 1) - (A - 1) * cs - s;
            break;
        }
        case 3:  // lowpass
            b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case 4:  // highpass
            b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case 5:  // notch
            b0 = 1; b1 = -2 * cs; b2 = 1;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case 6:  // allpass
            b0 = 1 - alpha; b1 = -2 * cs; b2 = 1 + alpha;
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha;
            break;
        case 7:  // tilt: shelf pair around the band frequency
            b0 = A; b1 = 0; b2 = 0;
            a0 = 1.0 / A; a1 = 0; a2 = 0;
            break;
        default:
            b0 = 1; a0 = 1;
    }
    bq.b0 = b0 / a0; bq.b1 = b1 / a0; bq.b2 = b2 / a0;
    bq.a1 = a1 / a0; bq.a2 = a2 / a0;
}

extern "C" void eq_set_band(CEq* e, int band, int type, double freq, double gain_db,
                            double q, int enabled) {
    if (!e || band < 0 || band >= e->bands) return;
    e->band[band].type = type;
    e->band[band].freq = freq;
    e->band[band].gain = gain_db;
    e->band[band].q = q;
    e->band[band].enabled = enabled;
}

extern "C" void eq_process(CEq* e, float* buf, int frames, int in_rate) {
    if (!e || !e->enabled || !buf || frames <= 0) return;
    const int ch = e->channels;
    // Re-design coefficients only when something changed materially. The Swift
    // layer calls eq_set_band sparingly; re-designing here is cheap enough that
    // we do it every call and keep state separate from coefficients.
    for (int b = 0; b < e->bands; ++b) {
        const EqBand& band = e->band[b];
        for (int c = 0; c < ch; ++c) {
            design(e->coeff[static_cast<size_t>(b) * ch + c], band.type, band.freq,
                   band.gain, band.q, static_cast<double>(in_rate));
        }
    }
    for (int b = 0; b < e->bands; ++b) {
        if (!e->band[b].enabled) continue;
        for (int c = 0; c < ch; ++c) {
            Biquad& bq = e->coeff[static_cast<size_t>(b) * ch + c];
            for (int i = 0; i < frames; ++i) {
                double x = buf[static_cast<size_t>(i) * ch + c];
                const double y = bq.b0 * x + bq.z1;
                bq.z1 = bq.b1 * x - bq.a1 * y + bq.z2;
                bq.z2 = bq.b2 * x - bq.a2 * y;
                buf[static_cast<size_t>(i) * ch + c] = static_cast<float>(y);
            }
        }
    }
}

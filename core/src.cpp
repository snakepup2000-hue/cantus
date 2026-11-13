// src.cpp — arbitrary-ratio windowed-sinc sample-rate converter.
//
// Linear phase, minimum phase (cepstral) and closed-form variants share one
// fractional-delay polyphase table. The min-phase path designs the prototype on
// a dense grid, folds it through the real cepstrum, then samples that causal
// impulse response at the fractional offsets each phase needs.
#include "cantus_core.h"
#include "util.h"
#include "stage.h"

#include <cmath>
#include <cstring>
#include <vector>

using namespace cant;

struct CSrc {
    double in_rate = 0, out_rate = 0, ratio = 1.0, trim = 1.0;
    int taps = 96, half = 48, phases = 512, channels = 2, window = CWIN_GAUSS;
    int family = 0;
    std::vector<double> table;   // (phases + 1) * taps
    std::vector<float> hist;     // interleaved input history
    long long hist_start = 0;    // absolute index of hist[0]
    long long n_in = 0;          // absolute samples pushed
    double t = 0.0;              // time of the next output sample, in input samples

    // Multi-stage path for large integer-ish ratios.
    bool staged = false;
    std::vector<Halfband2x> stages;     // one per channel per stage
    CSrc* tail = nullptr;               // remaining ratio, in [1, 2)
    std::vector<double> work[2];        // ping-pong buffers while cascading
};

static void normalise_rows(CSrc* r) {
    for (int p = 0; p <= r->phases; ++p) {
        double* row = &r->table[static_cast<size_t>(p) * r->taps];
        double sum = 0.0;
        for (int i = 0; i < r->taps; ++i) sum += row[i];
        if (std::fabs(sum) > 1e-12)
            for (int i = 0; i < r->taps; ++i) row[i] /= sum;
    }
}

static void build_linear_table(CSrc* r, double fc) {
    r->table.assign(static_cast<size_t>(r->phases + 1) * r->taps, 0.0);
    for (int p = 0; p <= r->phases; ++p) {
        const double frac = static_cast<double>(p) / r->phases;
        double* row = &r->table[static_cast<size_t>(p) * r->taps];
        for (int i = 0; i < r->taps; ++i) {
            const double d = static_cast<double>(i) - r->half + 1.0 - frac;
            if (r->family == 2) {
                row[i] = 2.0 * fc * sinc(2.0 * fc * d);
            } else {
                row[i] = 2.0 * fc * sinc(2.0 * fc * d) * window_at(r->window, d / r->half);
            }
        }
    }
    normalise_rows(r);
}

static void build_minphase_table(CSrc* r, double fc) {
    const int F = 64;                       // dense samples per input sample
    const size_t dense = static_cast<size_t>(r->half * 2) * F;
    const size_t N = next_pow2(dense * 2);

    std::vector<double> re(N, 0.0), im(N, 0.0);
    for (size_t n = 0; n < dense; ++n) {
        const double d = static_cast<double>(n) / F - r->half;
        re[n] = 2.0 * fc * sinc(2.0 * fc * d) * window_at(r->window, d / r->half);
    }
    fft_radix2(re, im, false);

    std::vector<double> cr(N), ci(N, 0.0);
    for (size_t n = 0; n < N; ++n) {
        const double mag = std::sqrt(re[n] * re[n] + im[n] * im[n]);
        cr[n] = std::log(std::max(mag, 1e-12));
    }
    fft_radix2(cr, ci, true);

    std::vector<double> mr(N, 0.0), mi(N, 0.0);
    mr[0] = cr[0];
    for (size_t n = 1; n < N / 2; ++n) mr[n] = 2.0 * cr[n];
    mr[N / 2] = cr[N / 2];
    fft_radix2(mr, mi, false);
    for (size_t n = 0; n < N; ++n) {
        const double m = std::exp(mr[n]);
        mr[n] = m * std::cos(mi[n]);
        mi[n] = m * std::sin(mi[n]);
    }
    fft_radix2(mr, mi, true);

    r->table.assign(static_cast<size_t>(r->phases + 1) * r->taps, 0.0);
    for (int p = 0; p <= r->phases; ++p) {
        const double frac = static_cast<double>(p) / r->phases;
        double* row = &r->table[static_cast<size_t>(p) * r->taps];
        for (int i = 0; i < r->taps; ++i) {
            const double pos = (static_cast<double>(i) + 1.0 - frac) * F;
            const long i0 = static_cast<long>(std::floor(pos));
            const double w = pos - i0;
            const double a = (i0 >= 0 && i0 < static_cast<long>(dense)) ? mr[i0] : 0.0;
            const double b = (i0 + 1 >= 0 && i0 + 1 < static_cast<long>(dense)) ? mr[i0 + 1] : 0.0;
            row[i] = a * (1.0 - w) + b * w;
        }
    }
    normalise_rows(r);
}

extern "C" CSrc* src_new(double in_rate, double out_rate, int taps, int window,
                         int family, double rolloff, int channels) {
    if (in_rate <= 0 || out_rate <= 0 || channels < 1) return nullptr;
    CSrc* r = new CSrc();
    r->in_rate = in_rate;
    r->out_rate = out_rate;
    r->ratio = out_rate / in_rate;
    r->taps = taps < 8 ? 8 : taps;
    if (r->taps % 2) ++r->taps;                 // even tap count
    r->half = r->taps / 2;
    r->channels = channels;
    r->window = window;
    r->family = family;
    // Large ratios are cheaper as a cascade of 2x halfband stages followed by
    // one short polyphase step. Minimum-phase kernels are kept single-stage,
    // since the cepstral fold cannot be split the same way.
    if (family != 1 && r->ratio >= 4.0) {
        int k = 0;
        double rem = r->ratio;
        while (rem >= 2.0 && k < 10) { rem /= 2.0; ++k; }
        r->staged = true;
        r->stages.assign(static_cast<size_t>(k) * r->channels, Halfband2x());
        if (std::fabs(rem - 1.0) > 1e-6) {
            const double midRate = in_rate * std::pow(2.0, k);
            // The tail only performs a mild fractional step at a high rate, so
            // a short kernel is enough and keeps the cost down.
            const int tailTaps = std::min(taps, 64);
            r->tail = src_new(midRate, out_rate, tailTaps, window, family, rolloff, channels);
        }
        src_reset(r);
        return r;
    }

    double fc = 0.5 * std::min(1.0, r->ratio) * rolloff;
    if (fc > 0.4999) fc = 0.4999;
    if (family == 1) build_minphase_table(r, fc); else build_linear_table(r, fc);
    src_reset(r);
    return r;
}

extern "C" void src_free(CSrc* r) {
    if (!r) return;
    if (r->tail) src_free(r->tail);
    delete r;
}

extern "C" void src_reset(CSrc* r) {
    if (!r) return;
    if (r->staged) {
        for (auto& st : r->stages) st.reset();
        if (r->tail) src_reset(r->tail);
        r->n_in = 0;
        return;
    }
    r->hist.assign(static_cast<size_t>(r->half) * r->channels, 0.0f);
    r->hist_start = -static_cast<long long>(r->half);
    r->n_in = 0;
    r->t = 0.0;
}

extern "C" void src_set_trim(CSrc* r, double trim) {
    if (r) r->trim = (trim > 0.5 && trim < 2.0) ? trim : 1.0;
}

extern "C" int src_max_out(CSrc* r, int in_frames) {
    if (!r) return 0;
    return static_cast<int>(std::ceil(in_frames * r->ratio * r->trim)) + 16;
}

extern "C" int src_channels(CSrc* r) { return r ? r->channels : 0; }

// Interleaved passthrough of the 2x cascade for one block.
static int processStaged(CSrc* r, const float* in, int in_frames, float* out, int out_cap) {
    const int ch = r->channels;
    const int k = static_cast<int>(r->stages.size()) / ch;

    // Deinterleave, cascade, reinterleave. Channel count is 1 or 2 in practice.
    std::vector<double> cur[2];
    for (int c = 0; c < ch && c < 2; ++c) {
        cur[c].resize(static_cast<size_t>(in_frames));
        for (int i = 0; i < in_frames; ++i)
            cur[c][static_cast<size_t>(i)] = static_cast<double>(in[static_cast<size_t>(i) * ch + c]);
    }

    std::vector<double> buf;
    for (int s = 0; s < k; ++s) {
        const int n = static_cast<int>(cur[0].size());
        for (int c = 0; c < ch && c < 2; ++c) {
            r->stages[static_cast<size_t>(s) * ch + c].process(cur[c].data(), n, buf);
            cur[c].swap(buf);
        }
    }

    if (r->tail) {
        // Re-interleave at the intermediate rate and let the polyphase finish.
        const int n = static_cast<int>(cur[0].size());
        std::vector<float> mid(static_cast<size_t>(n) * ch);
        for (int i = 0; i < n; ++i)
            for (int c = 0; c < ch && c < 2; ++c)
                mid[static_cast<size_t>(i) * ch + c] = static_cast<float>(cur[c][static_cast<size_t>(i)]);
        return src_process(r->tail, mid.data(), n, out, out_cap);
    }

    const int n = static_cast<int>(cur[0].size());
    const int count = std::min(n, out_cap);
    for (int i = 0; i < count; ++i)
        for (int c = 0; c < ch && c < 2; ++c)
            out[static_cast<size_t>(i) * ch + c] = static_cast<float>(cur[c][static_cast<size_t>(i)]);
    return count;
}

extern "C" int src_process(CSrc* r, const float* in, int in_frames, float* out, int out_cap) {
    if (!r || !in || in_frames <= 0 || out_cap <= 0) return 0;
    if (r->staged) return processStaged(r, in, in_frames, out, out_cap);
    const int ch = r->channels;
    r->hist.insert(r->hist.end(), in, in + static_cast<size_t>(in_frames) * ch);
    r->n_in += in_frames;
    const long long last_abs = r->hist_start + static_cast<long long>(r->hist.size() / ch) - 1;

    int produced = 0;
    // step is input samples advanced per output sample.
    const double step = (r->in_rate / r->out_rate) / r->trim;
    const int phases = r->phases, taps = r->taps, half = r->half;

    while (produced < out_cap) {
        const double t = r->t;
        const long long center = static_cast<long long>(std::floor(t));
        if (center + half > last_abs) break;                 // more input needed
        if (center - half < r->hist_start) break;            // history already dropped
        const double frac = t - static_cast<double>(center);
        const double pid = frac * phases;
        int p0 = static_cast<int>(pid);
        if (p0 >= phases) p0 = phases - 1;
        const double w = pid - p0;
        const double* row0 = &r->table[static_cast<size_t>(p0) * taps];
        const double* row1 = &r->table[static_cast<size_t>(p0 + 1) * taps];
        const long long base = center - half + 1 - r->hist_start;
        const float* h = r->hist.data();
        float* o = out + static_cast<size_t>(produced) * ch;
        for (int c = 0; c < ch; ++c) {
            double acc = 0.0;
            for (int i = 0; i < taps; ++i) {
                const double k = row0[i] * (1.0 - w) + row1[i] * w;
                acc += k * static_cast<double>(h[static_cast<size_t>(base + i) * ch + c]);
            }
            o[c] = static_cast<float>(acc);
        }
        ++produced;
        r->t = t + step;
    }

    const long long keep_from = static_cast<long long>(std::floor(r->t)) - half - 1;
    if (keep_from > r->hist_start) {
        long long drop = std::min<long long>(keep_from - r->hist_start,
                                             static_cast<long long>(r->hist.size() / ch));
        if (drop > 0) {
            r->hist.erase(r->hist.begin(), r->hist.begin() + static_cast<size_t>(drop) * ch);
            r->hist_start += drop;
        }
    }
    return produced;
}

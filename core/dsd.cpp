// dsd.cpp — 1-bit delta-sigma modulation out, halfband decimation in.
#include "cantus_core.h"
#include "util.h"

#include <cmath>
#include <cstring>
#include <vector>

using namespace cant;

// --------------------------------------------------------- modulator (output)
// 4th-order single-bit loop. Coefficients chosen for a stable, modest
// out-of-band gain at OSR 64-256. Input is expected at the DSD *bit* rate.

static constexpr double A1 = 0.10, A2 = 0.30, A3 = 0.30, A4 = 0.30;

extern "C" void sdm_reset(CSdm* s) {
    if (!s) return;
    for (int c = 0; c < 2; ++c) {
        s->s0[c] = s->s1[c] = s->s2[c] = s->s3[c] = 0.0;
        s->last[c] = 1;
        s->run[c] = 0;
    }
}

static inline int sdm_bit(CSdm* s, int c, double input) {
    double x = input * 0.5;
    if (x > 0.5) x = 0.5;
    else if (x < -0.5) x = -0.5;

    const double yi = (s->s3[c] >= 0.0) ? 1.0 : -1.0;
    const int bit = yi > 0.0 ? 1 : 0;

    if (bit == s->last[c]) ++s->run[c];
    else { s->run[c] = 0; s->last[c] = bit; }
    if (s->run[c] > 64) {   // overload guard
        s->s0[c] = s->s1[c] = s->s2[c] = s->s3[c] = 0.0;
        s->run[c] = 0;
    }

    double prev = x - yi;
    s->s0[c] += A1 * prev; prev = s->s0[c] - yi;
    s->s1[c] += A2 * prev; prev = s->s1[c] - yi;
    s->s2[c] += A3 * prev; prev = s->s2[c] - yi;
    s->s3[c] += A4 * prev;
    return bit;
}

extern "C" void sdm_words(CSdm* s, const float* in, int frames, int ch,
                          uint32_t* out_words, double gain) {
    if (!s || !in || !out_words) return;
    size_t o = 0;
    // One modulator step per DSD-rate input frame; 32 steps make one word.
    for (int i = 0; i < frames; i += 32) {
        for (int c = 0; c < ch; ++c) {
            const int cc = c < 2 ? c : 0;
            uint32_t w = 0;
            for (int b = 0; b < 32; ++b) {
                const int idx = i + b;
                const double x = (idx < frames)
                    ? static_cast<double>(in[static_cast<size_t>(idx) * ch + c]) * gain
                    : 0.0;
                w = (w << 1) | static_cast<uint32_t>(sdm_bit(s, cc, x));
            }
            // DSD_U32_BE: big-endian byte order, oldest bit in the MSB.
            out_words[o++] = ((w & 0x000000FFu) << 24) | ((w & 0x0000FF00u) << 8) |
                             ((w & 0x00FF0000u) >> 8) | ((w & 0xFF000000u) >> 24);
        }
    }
}

// DoP v1: each 24-bit frame carries an 8-bit marker plus 16 DSD bits, so 16
// DSD-rate input frames become one output frame per channel.
extern "C" void sdm_pack_dop(CSdm* s, const float* in, int frames, int ch,
                             uint8_t* out_bytes, double gain) {
    if (!s || !in || !out_bytes) return;
    size_t o = 0;
    int marker = 0;
    for (int i = 0; i < frames; i += 16) {
        const uint8_t m = (marker++ & 1) ? 0xFA : 0x05;
        for (int c = 0; c < ch; ++c) {
            const int cc = c < 2 ? c : 0;
            uint32_t bits = 0;
            for (int b = 0; b < 16; ++b) {
                const int idx = i + b;
                const double x = (idx < frames)
                    ? static_cast<double>(in[static_cast<size_t>(idx) * ch + c]) * gain
                    : 0.0;
                bits = (bits << 1) | static_cast<uint32_t>(sdm_bit(s, cc, x));
            }
            const uint32_t sample = (static_cast<uint32_t>(m) << 16) | (bits & 0xFFFFu);
            out_bytes[o++] = static_cast<uint8_t>(sample & 0xFF);
            out_bytes[o++] = static_cast<uint8_t>((sample >> 8) & 0xFF);
            out_bytes[o++] = static_cast<uint8_t>((sample >> 16) & 0xFF);
        }
    }
}

// ------------------------------------------------------ decimator (DSD input)
//
// Cascade of halfband decimators. Each stage halves the rate; the kernel is a
// Kaiser-windowed halfband with unity DC gain. Filter state is a per-stage ring
// buffer.

static constexpr int HB_TAPS = 255;

struct HbStage {
    std::vector<double> h;      // HB_TAPS coefficients
    std::vector<double> z;      // HB_TAPS delay line, z[pos] is the newest
    int pos = 0;
    int parity = 0;
};

struct CdsdIn {
    int ch = 2, stages = 4;
    double scale = 1.0;
    std::vector<std::vector<HbStage>> st;   // [stage][channel]
    std::vector<float> outFifo;
    size_t outPos = 0;
};

static void design_halfband(std::vector<double>& h) {
    h.assign(HB_TAPS, 0.0);
    const double c = (HB_TAPS - 1) / 2.0;
    for (int i = 0; i < HB_TAPS; ++i) {
        const double d = i - c;
        h[i] = 0.5 * sinc(0.5 * d) * window_at(CWIN_KAISER, d / c);
    }
    double sum = 0.0;
    for (double v : h) sum += v;
    for (double& v : h) v /= sum;
}

extern "C" CdsdIn* dsdin_new(int channels, int decim_stages, double scale) {
    if (channels < 1 || decim_stages < 1 || decim_stages > 8) return nullptr;
    CdsdIn* d = new CdsdIn();
    d->ch = channels;
    d->stages = decim_stages;
    d->scale = scale <= 0.0 ? 1.0 : scale;
    std::vector<double> h;
    design_halfband(h);
    d->st.assign(static_cast<size_t>(decim_stages),
                 std::vector<HbStage>(static_cast<size_t>(channels)));
    for (int s = 0; s < decim_stages; ++s)
        for (int c = 0; c < channels; ++c) {
            d->st[static_cast<size_t>(s)][static_cast<size_t>(c)].h = h;
            d->st[static_cast<size_t>(s)][static_cast<size_t>(c)].z.assign(HB_TAPS, 0.0);
        }
    return d;
}

extern "C" void dsdin_free(CdsdIn* d) { delete d; }

extern "C" void dsdin_reset(CdsdIn* d) {
    if (!d) return;
    for (auto& stage : d->st)
        for (auto& s : stage) {
            std::fill(s.z.begin(), s.z.end(), 0.0);
            s.pos = 0;
            s.parity = 0;
        }
    d->outFifo.clear();
    d->outPos = 0;
}

// Push one sample into one stage. Returns true on the samples kept by the
// decimation-by-two (every second input).
static inline bool hb_push(HbStage& s, double x, double* outv) {
    s.z[s.pos] = x;
    s.pos = (s.pos + 1) % HB_TAPS;
    const bool keep = (s.parity == 1);
    s.parity ^= 1;
    if (!keep) return false;
    // Convolve newest-first: z[pos-1] is x[n], z[pos-HB_TAPS] is x[n-HB_TAPS+1].
    double y = 0.0;
    int idx = s.pos;
    for (int i = 0; i < HB_TAPS; ++i) {
        idx = (idx == 0) ? HB_TAPS - 1 : idx - 1;
        y += s.h[i] * s.z[idx];
    }
    *outv = y;
    return true;
}

extern "C" int dsdin_process(CdsdIn* d, const uint8_t* in, int words_per_ch, int ch,
                             float* out, int out_cap) {
    if (!d || !in || words_per_ch <= 0 || out_cap <= 0) return 0;
    if (ch != d->ch) return 0;

    for (int f = 0; f < words_per_ch; ++f) {
        for (int c = 0; c < d->ch; ++c) {
            const size_t off = (static_cast<size_t>(f) * ch + c) * 4;
            const uint32_t w = (static_cast<uint32_t>(in[off]) << 24) |
                               (static_cast<uint32_t>(in[off + 1]) << 16) |
                               (static_cast<uint32_t>(in[off + 2]) << 8) |
                               static_cast<uint32_t>(in[off + 3]);
            for (int b = 31; b >= 0; --b) {
                double v = ((w >> b) & 1u) ? d->scale : -d->scale;
                bool produced = true;
                for (int s = 0; s < d->stages && produced; ++s) {
                    double y = 0.0;
                    produced = hb_push(d->st[static_cast<size_t>(s)][static_cast<size_t>(c)],
                                       v, &y);
                    v = y;
                }
                if (produced) d->outFifo.push_back(static_cast<float>(v));
            }
        }
    }

    int written = 0;
    while (written < out_cap && d->outPos * d->ch + d->ch <= d->outFifo.size()) {
        for (int c = 0; c < d->ch; ++c)
            out[static_cast<size_t>(written) * d->ch + c] =
                d->outFifo[d->outPos * d->ch + c];
        ++d->outPos;
        ++written;
    }
    if (d->outPos > 65536) {
        d->outFifo.erase(d->outFifo.begin(), d->outFifo.begin() + d->outPos * d->ch);
        d->outPos = 0;
    }
    return written;
}

// ============================================================ response probe

extern "C" void probe_response(const float* ir, int n, float* mag_db, int bins, double fs) {
    if (!ir || n <= 0 || !mag_db || bins <= 0) return;
    const size_t N = next_pow2(static_cast<size_t>(n) * 2);
    std::vector<double> re(N, 0.0), im(N, 0.0);
    for (int i = 0; i < n; ++i) re[i] = ir[i];
    fft_radix2(re, im, false);
    for (int b = 0; b < bins; ++b) {
        const double frac = (bins == 1) ? 0.0 : static_cast<double>(b) / (bins - 1);
        const size_t k = static_cast<size_t>(frac * (N / 2 - 1));
        const double mag = std::sqrt(re[k] * re[k] + im[k] * im[k]);
        mag_db[b] = static_cast<float>(20.0 * std::log10(std::max(mag, 1e-9)));
    }
    (void)fs;
}

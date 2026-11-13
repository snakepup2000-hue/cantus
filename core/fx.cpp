// fx.cpp — overlap-save convolution, clip guard, PCM quantisation, metering.
#include "cantus_core.h"
#include "util.h"

#include <cmath>
#include <cstring>
#include <vector>

using namespace cant;

// ============================================================== convolution

struct CConv {
    int ch = 2, irch = 1, M = 0, N = 1024, F = 2048, hist = 0;
    std::vector<double> irRe, irIm;   // [ch][F]
    std::vector<float> inFifo;        // interleaved, keeps M-1 frames of history
    std::vector<float> outFifo;       // interleaved output frames awaiting delivery
    size_t outPos = 0;                // frames already delivered
};

extern "C" CConv* conv_new(int channels, const float* ir, int ir_frames, int ir_channels) {
    if (!ir || ir_frames <= 0 || channels < 1 || channels > 8) return nullptr;
    CConv* c = new CConv();
    c->ch = channels;
    c->irch = ir_channels < 1 ? 1 : ir_channels;
    c->M = ir_frames;
    c->N = 1024;
    c->hist = c->M > 1 ? c->M - 1 : 0;
    c->F = static_cast<int>(next_pow2(static_cast<size_t>(c->N) + c->hist));
    c->irRe.assign(static_cast<size_t>(c->ch) * c->F, 0.0);
    c->irIm.assign(static_cast<size_t>(c->ch) * c->F, 0.0);
    for (int k = 0; k < c->ch; ++k) {
        std::vector<double> re(c->F, 0.0), im(c->F, 0.0);
        const int src = (c->irch == 1) ? 0 : std::min(k, c->irch - 1);
        for (int i = 0; i < c->M; ++i) re[i] = ir[static_cast<size_t>(i) * c->irch + src];
        fft_radix2(re, im, false);
        std::memcpy(&c->irRe[static_cast<size_t>(k) * c->F], re.data(), sizeof(double) * c->F);
        std::memcpy(&c->irIm[static_cast<size_t>(k) * c->F], im.data(), sizeof(double) * c->F);
    }
    conv_reset(c);
    return c;
}

extern "C" void conv_free(CConv* c) { delete c; }

extern "C" void conv_reset(CConv* c) {
    if (!c) return;
    c->inFifo.assign(static_cast<size_t>(c->hist) * c->ch, 0.0f);
    c->outFifo.clear();
    c->outPos = 0;
}

extern "C" int conv_latency(CConv* c) { return 0; }

extern "C" int conv_process(CConv* c, float* buf, int frames) {
    if (!c || !buf || frames <= 0) return -1;
    const int ch = c->ch;
    c->inFifo.insert(c->inFifo.end(), buf, buf + static_cast<size_t>(frames) * ch);

    while (c->inFifo.size() >= static_cast<size_t>(c->N + c->hist) * ch) {
        // Build one FFT frame per channel: [ history | N new ] padded to F.
        std::vector<std::vector<double>> specRe(static_cast<size_t>(ch)),
                                         specIm(static_cast<size_t>(ch));
        for (int k = 0; k < ch; ++k) {
            std::vector<double> re(c->F, 0.0), im(c->F, 0.0);
            for (int i = 0; i < c->hist + c->N; ++i)
                re[i] = c->inFifo[static_cast<size_t>(i) * ch + k];
            fft_radix2(re, im, false);
            const double* irr = &c->irRe[static_cast<size_t>(k) * c->F];
            const double* iri = &c->irIm[static_cast<size_t>(k) * c->F];
            specRe[k].assign(c->F, 0.0);
            specIm[k].assign(c->F, 0.0);
            for (int i = 0; i < c->F; ++i) {
                specRe[k][i] = re[i] * irr[i] - im[i] * iri[i];
                specIm[k][i] = re[i] * iri[i] + im[i] * irr[i];
            }
            fft_radix2(specRe[k], specIm[k], true);
        }
        for (int i = 0; i < c->N; ++i)
            for (int k = 0; k < ch; ++k)
                c->outFifo.push_back(static_cast<float>(specRe[k][c->hist + i]));
        c->inFifo.erase(c->inFifo.begin(),
                        c->inFifo.begin() + static_cast<size_t>(c->N) * ch);
    }

    // Emit exactly `frames`, padding with silence while the FIFO primes.
    for (int i = 0; i < frames; ++i) {
        const size_t idx = c->outPos + static_cast<size_t>(i);
        if ((idx + 1) * ch <= c->outFifo.size()) {
            for (int k = 0; k < ch; ++k)
                buf[static_cast<size_t>(i) * ch + k] = c->outFifo[idx * ch + k];
        } else {
            for (int k = 0; k < ch; ++k) buf[static_cast<size_t>(i) * ch + k] = 0.0f;
        }
    }
    c->outPos += frames;
    if (c->outPos > 16384) {
        c->outFifo.erase(c->outFifo.begin(),
                         c->outFifo.begin() + c->outPos * ch);
        c->outPos = 0;
    }
    return 0;
}

// ================================================================== limiter

extern "C" void lim_init(CLimiter* l, int channels) {
    if (!l) return;
    if (l->ceiling_db == 0.0) l->ceiling_db = -0.3;
    if (l->release_ms <= 0.0) l->release_ms = 120.0;
    if (l->attack_ms <= 0.0) l->attack_ms = 1.5;
    l->channels = channels < 1 ? 1 : channels;
    l->gain = 1.0;
    l->env = 0.0;
    l->init = 1;
}

extern "C" void lim_reset(CLimiter* l) {
    if (!l) return;
    l->gain = 1.0;
    l->env = 0.0;
}

extern "C" void lim_process(CLimiter* l, float* buf, int frames, int rate) {
    if (!l || !buf || frames <= 0) return;
    if (!l->init) lim_init(l, l->channels);
    const int ch = l->channels;
    const double ceiling = std::pow(10.0, l->ceiling_db / 20.0);
    const double atk = std::exp(-1.0 / (std::max(0.1, l->attack_ms) * 0.001 * rate));
    const double rel = std::exp(-1.0 / (std::max(1.0, l->release_ms) * 0.001 * rate));

    (void)atk;
    for (int i = 0; i < frames; ++i) {
        double peak = 0.0;
        for (int k = 0; k < ch; ++k)
            peak = std::max(peak, std::fabs(static_cast<double>(buf[static_cast<size_t>(i) * ch + k])));
        const double target = (peak > ceiling) ? (ceiling / peak) : 1.0;
        // Attack is instantaneous so no sample can ever pass the ceiling; only
        // the release is smoothed, which is what avoids gain pumping.
        if (target < l->gain) l->gain = target;
        else                  l->gain = target + (l->gain - target) * rel;
        if (l->gain > 1.0) l->gain = 1.0;
        for (int k = 0; k < ch; ++k) {
            double v = static_cast<double>(buf[static_cast<size_t>(i) * ch + k]) * l->gain;
            if (v > 1.0) v = 1.0;
            else if (v < -1.0) v = -1.0;
            buf[static_cast<size_t>(i) * ch + k] = static_cast<float>(v);
        }
    }
    l->env = l->gain;
}

// ============================================================ PCM formatting

static inline uint32_t xorshift32(uint32_t& s) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

extern "C" int pcm_format(const float* in, int frames, int channels, int bits,
                          int dither, int shaper, uint8_t* out) {
    if (!in || !out || frames <= 0 || channels < 1) return 0;
    static thread_local uint32_t rng = 0x9E3779B9u;
    const double scale = (bits == 16) ? 32767.0 : (bits == 24 ? 8388607.0 : 2147483647.0);
    // Per-channel error feedback. The error has to be measured against the
    // signal the quantiser was fed, not the unshaped input: the latter feeds
    // the shaped error back into itself, the loop's pole sits outside the unit
    // circle (z = -1 ± sqrt(2)) and a stream of full-scale noise appears within
    // a few dozen samples. At most eight channels are in use in the core.
    double e1[8] = {0.0}, e2[8] = {0.0}, e3[8] = {0.0};
    size_t o = 0;
    for (int i = 0; i < frames; ++i) {
        for (int k = 0; k < channels; ++k) {
            const int c = k & 7;
            double x = in[static_cast<size_t>(i) * channels + k];
            if (x > 1.0) x = 1.0;
            else if (x < -1.0) x = -1.0;
            const double v = x * scale;
            double u = v;
            if (dither) {
                const double a = static_cast<double>(xorshift32(rng) & 0xFFFF) / 65535.0;
                const double b = static_cast<double>(xorshift32(rng) & 0xFFFF) / 65535.0;
                u += a + b - 1.0;
            }
            if (shaper == 1)      u += -e1[c];
            else if (shaper == 2) u += -2.0 * e1[c] + e2[c];
            else if (shaper == 3) u += -3.0 * e1[c] + 3.0 * e2[c] - e3[c];
            long q = std::lround(u);
            double qd = static_cast<double>(q);
            if (qd > scale) qd = scale;
            else if (qd < -scale) qd = -scale;
            e3[c] = e2[c]; e2[c] = e1[c]; e1[c] = qd - u;
            const long qi = static_cast<long>(qd);
            if (bits == 16) {
                const uint16_t u = static_cast<uint16_t>(static_cast<int16_t>(qi));
                out[o++] = static_cast<uint8_t>(u & 0xFF);
                out[o++] = static_cast<uint8_t>((u >> 8) & 0xFF);
            } else if (bits == 24) {
                out[o++] = static_cast<uint8_t>(qi & 0xFF);
                out[o++] = static_cast<uint8_t>((qi >> 8) & 0xFF);
                out[o++] = static_cast<uint8_t>((qi >> 16) & 0xFF);
            } else {
                const uint32_t u = static_cast<uint32_t>(static_cast<int32_t>(qi));
                out[o++] = static_cast<uint8_t>(u & 0xFF);
                out[o++] = static_cast<uint8_t>((u >> 8) & 0xFF);
                out[o++] = static_cast<uint8_t>((u >> 16) & 0xFF);
                out[o++] = static_cast<uint8_t>((u >> 24) & 0xFF);
            }
        }
    }
    return static_cast<int>(o);
}

// ================================================================== metering

struct CMeter {
    double peak[2] = {0, 0}, sum[2] = {0, 0};
    long long count[2] = {0, 0};
};

extern "C" CMeter* meter_new(void) { return new CMeter(); }
extern "C" void meter_free(CMeter* m) { delete m; }

extern "C" void meter_reset(CMeter* m) {
    if (!m) return;
    m->peak[0] = m->peak[1] = 0.0;
    m->sum[0] = m->sum[1] = 0.0;
    m->count[0] = m->count[1] = 0;
}

extern "C" void meter_process(CMeter* m, const float* buf, int frames, int channels) {
    if (!m || !buf) return;
    for (int i = 0; i < frames; ++i) {
        for (int k = 0; k < channels && k < 2; ++k) {
            const double v = std::fabs(static_cast<double>(buf[static_cast<size_t>(i) * channels + k]));
            m->peak[k] = std::max(m->peak[k], v);
            m->sum[k] += v * v;
            m->count[k] += 1;
        }
    }
}

extern "C" void meter_get(CMeter* m, double* peak_l, double* peak_r,
                          double* rms_l, double* rms_r) {
    if (!m) return;
    if (peak_l) *peak_l = m->peak[0];
    if (peak_r) *peak_r = m->peak[1];
    if (rms_l) *rms_l = m->count[0] ? std::sqrt(m->sum[0] / static_cast<double>(m->count[0])) : 0.0;
    if (rms_r) *rms_r = m->count[1] ? std::sqrt(m->sum[1] / static_cast<double>(m->count[1])) : 0.0;
}

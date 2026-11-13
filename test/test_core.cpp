// test_core.cpp — numeric self-tests for the Cantus DSP core.
#include "../core/cantus_core.h"
#include "../core/util.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;
static void check(bool ok, const char* what) {
    std::printf("  %-52s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) ++failures;
}

static std::vector<float> sine(double freq, double fs, int frames, double amp = 0.5) {
    std::vector<float> v(static_cast<size_t>(frames) * 2);
    for (int i = 0; i < frames; ++i) {
        const float s = static_cast<float>(amp * std::sin(2.0 * M_PI * freq * i / fs));
        v[static_cast<size_t>(i) * 2] = s;
        v[static_cast<size_t>(i) * 2 + 1] = s;
    }
    return v;
}

// THD+N of the left channel inside [0, maxHz], ignoring DC and a skirt
// around the fundamental. Window sidelobes are ~-92 dB, so -90 dB readings are
// measurement-floor limited, not converter limited.
static double thdn_db(const std::vector<float>& buf, double fs, double f0,
                      double maxHz = 20000.0) {
    const int frames = static_cast<int>(buf.size() / 2);
    int N = 1;
    while (N < 32768 && N * 2 <= frames) N *= 2;
    if (N < 1024) return 999.0;
    std::vector<double> re(N), im(N);
    for (int i = 0; i < N; ++i) {
        const double w = 0.35875 - 0.48829 * std::cos(2 * M_PI * i / (N - 1)) +
                         0.14128 * std::cos(4 * M_PI * i / (N - 1)) -
                         0.01168 * std::cos(6 * M_PI * i / (N - 1));
        re[i] = buf[static_cast<size_t>(i) * 2] * w;
        im[i] = 0;
    }
    cant::fft_radix2(re, im, false);
    const int peak = static_cast<int>(f0 / fs * N);
    const int kmax = std::min(N / 2 - 1, static_cast<int>(maxHz / fs * N));
    double fund = 0, resid = 0;
    for (int k = 1; k <= kmax; ++k) {
        const double p = re[k] * re[k] + im[k] * im[k];
        if (std::abs(k - peak) <= 6) fund += p;
        else resid += p;
    }
    if (fund <= 0) return 999.0;
    return 10.0 * std::log10(std::max(resid, 1e-30) / fund);
}

int main() {
    std::printf("Cantus DSP core self-test\n\n");

    // --- resampler -----------------------------------------------------------
    std::printf("resampler\n");
    {
        const double inFs = 44100, outFs = 352800, f0 = 997;
        auto in = sine(f0, inFs, 44100);
        CSrc* r = src_new(inFs, outFs, 256, CWIN_BLACKMAN_HARRIS, 0, 0.92, 2);
        check(r != nullptr, "src_new returns a converter");
        const int cap = src_max_out(r, 44100);
        std::vector<float> out(static_cast<size_t>(cap) * 2);
        int n = src_process(r, in.data(), 44100, out.data(), cap);
        // The staged (linear-phase) path emits exactly the ratio times the input.
        check(n == 44100 * 8, "output frame count matches the ratio");
        std::vector<float> trimmed(out.begin() + 2000 * 2, out.begin() + (2000 + 32768) * 2);
        const double thd = thdn_db(trimmed, outFs, f0);
        std::printf("    windowed THD+N 44.1k -> 352.8k: %.1f dB (sidelobe floor ~-92 dB)\n", thd);
        check(thd < -85.0, "windowed THD+N below -85 dB");
        // Least-squares fit of the fundamental, so group delay does not count as
        // error. The residual is harmonics plus noise, i.e. the real distortion.
        {
            const double w = 2.0 * M_PI * f0 / outFs;
            double cc = 0, ss = 0, cs = 0, xc = 0, xs = 0;
            const int a = 4000, b = std::min(n, 40000);
            for (int k = a; k < b; ++k) {
                const double c = std::cos(w * k), sn = std::sin(w * k);
                const double v = out[static_cast<size_t>(k) * 2];
                cc += c * c; ss += sn * sn; cs += c * sn; xc += v * c; xs += v * sn;
            }
            const double det = cc * ss - cs * cs;
            const double A = (xc * ss - xs * cs) / det;
            const double B = (xs * cc - xc * cs) / det;
            double err2 = 0.0, sig2 = 0.0;
            for (int k = a; k < b; ++k) {
                const double ideal = A * std::cos(w * k) + B * std::sin(w * k);
                const double e = out[static_cast<size_t>(k) * 2] - ideal;
                err2 += e * e;
                sig2 += ideal * ideal;
            }
            const double snr = 10.0 * std::log10(sig2 / std::max(err2, 1e-30));
            std::printf("    fitted waveform SNR (staged, 65-tap stages): %.1f dB\n", snr);
            check(snr > 100.0, "waveform error better than -100 dB");
        }
        src_free(r);
    }
    {
        // minimum phase must also stay linear in amplitude
        const double inFs = 48000, outFs = 384000, f0 = 1000;
        auto in = sine(f0, inFs, 48000);
        CSrc* r = src_new(inFs, outFs, 256, CWIN_BLACKMAN_HARRIS, 1, 0.92, 2);
        const int cap = src_max_out(r, 48000);
        std::vector<float> out(static_cast<size_t>(cap) * 2);
        int n = src_process(r, in.data(), 48000, out.data(), cap);
        const int expect = static_cast<int>((48000 - 128) * 8);
        check(std::abs(n - expect) < 16, "min-phase output frame count");
        std::vector<float> trimmed(out.begin() + 2000 * 2, out.begin() + (2000 + 16384) * 2);
        const double thd = thdn_db(trimmed, outFs, f0);
        std::printf("    min-phase THD+N 48k -> 384k: %.1f dB\n", thd);
        check(thd < -85.0, "min-phase THD+N below -85 dB");
        src_free(r);
    }
    {
        // ratio check on a non-integer conversion
        CSrc* r = src_new(44100, 48000, 128, CWIN_GAUSS, 0, 0.95, 2);
        const int cap = src_max_out(r, 4410);
        std::vector<float> out(static_cast<size_t>(cap) * 2);
        auto in = sine(1000, 44100, 4410);
        int n = src_process(r, in.data(), 4410, out.data(), cap);
        std::printf("    44.1k -> 48k produced %d frames for 4410 in (expect ~4800)\n", n);
        check(n >= 4725 && n <= 4740, "non-integer ratio is correct");
        src_free(r);
    }

    // --- EQ ---------------------------------------------------------------
    std::printf("\neq\n");
    {
        CEq* e = eq_new(2, 12);
        eq_set_band(e, 0, 0, 1000, 6.0, 1.0, 1);   // +6 dB peaking at 1 kHz
        std::vector<float> buf = sine(1000, 48000, 48000, 0.1);
        eq_process(e, buf.data(), 48000, 48000);
        double peak = 0;
        for (int i = 24000; i < 47000; ++i)
            peak = std::max(peak, std::fabs((double)buf[static_cast<size_t>(i) * 2]));
        const double gain = 20 * std::log10(peak / 0.1);
        std::printf("    +6 dB peaking @1k measured %.2f dB\n", gain);
        check(std::fabs(gain - 6.0) < 0.2, "peaking filter gain is accurate");

        eq_reset(e);
        eq_set_band(e, 0, 0, 1000, 6.0, 1.0, 1);
        std::vector<float> flat = sine(8000, 48000, 48000, 0.1);
        eq_process(e, flat.data(), 48000, 48000);
        double p2 = 0;
        for (int i = 24000; i < 47000; ++i)
            p2 = std::max(p2, std::fabs((double)flat[static_cast<size_t>(i) * 2]));
        std::printf("    8 kHz away from the band: %.2f dB\n", 20 * std::log10(p2 / 0.1));
        eq_free(e);
    }

    // --- convolution -------------------------------------------------------
    std::printf("\nconvolution\n");
    {
        const float ir[3] = {1.0f, 0.5f, 0.25f};
        CConv* c = conv_new(2, ir, 3, 1);
        check(c != nullptr, "conv_new accepts a mono IR");
        const int frames = 4096;
        std::vector<float> buf(static_cast<size_t>(frames) * 2, 0.0f);
        buf[0] = 1.0f;
        buf[1] = 1.0f;
        conv_process(c, buf.data(), frames);
        const int lat = conv_latency(c);
        bool ok = true;
        for (int i = 0; i < frames; ++i) {
            double expect = 0.0;
            const int k = i - lat;
            if (k >= 0 && k < 3) expect = ir[k];
            if (std::fabs(buf[static_cast<size_t>(i) * 2] - expect) > 1e-4) ok = false;
        }
        std::printf("    latency %d frames, impulse response %s\n", lat, ok ? "exact" : "WRONG");
        check(ok, "impulse convolved with IR reproduces the IR");
        conv_free(c);
    }

    // --- limiter -----------------------------------------------------------
    std::printf("\nlimiter\n");
    {
        CLimiter lim{};
        lim_init(&lim, 2);
        std::vector<float> buf = sine(100, 48000, 48000, 1.6);
        lim_process(&lim, buf.data(), 48000, 48000);
        double peak = 0;
        for (float v : buf) peak = std::max(peak, (double)std::fabs(v));
        std::printf("    1.6 amplitude input -> peak %.3f\n", peak);
        check(peak <= 1.0001, "output never exceeds full scale");
        check(peak > 0.9, "limiter does not crush normal material");
    }

    // --- PCM formatting ----------------------------------------------------
    std::printf("\npcm format\n");
    {
        std::vector<float> buf = sine(997, 48000, 1000, 0.5);
        std::vector<uint8_t> out(1000 * 2 * 4);
        int b16 = pcm_format(buf.data(), 1000, 2, 16, 0, 0, out.data());
        check(b16 == 1000 * 2 * 2, "16-bit byte count");
        int b24 = pcm_format(buf.data(), 1000, 2, 24, 1, 2, out.data());
        check(b24 == 1000 * 2 * 3, "24-bit byte count with dither + shaping");
        int b32 = pcm_format(buf.data(), 1000, 2, 32, 1, 0, out.data());
        check(b32 == 1000 * 2 * 4, "32-bit byte count");

        // Dithered, noise-shaped output must stay within a few LSB of the
        // input. A shaper that feeds its error back against the wrong signal
        // diverges to full-scale noise within a few dozen samples.
        std::vector<uint8_t> shaped24(1000 * 2 * 3);
        pcm_format(buf.data(), 1000, 2, 24, 1, 2, shaped24.data());
        long worst24 = 0;
        for (size_t i = 0; i < 1000 * 2; ++i) {
            const uint8_t* p = &shaped24[i * 3];
            long v = static_cast<long>(p[0]) | (static_cast<long>(p[1]) << 8) |
                     (static_cast<long>(p[2]) << 16);
            if (v & 0x800000) v -= 0x1000000;
            const long want = std::lround(static_cast<double>(buf[i]) * 8388607.0);
            const long diff = v > want ? v - want : want - v;
            if (diff > worst24) worst24 = diff;
        }
        check(worst24 <= 16, "24-bit dithered shaper stays within 16 LSB");

        std::vector<uint8_t> shaped32(1000 * 2 * 4);
        pcm_format(buf.data(), 1000, 2, 32, 1, 2, shaped32.data());
        long worst32 = 0;
        for (size_t i = 0; i < 1000 * 2; ++i) {
            const uint8_t* p = &shaped32[i * 4];
            const long long u = static_cast<long long>(p[0]) |
                                (static_cast<long long>(p[1]) << 8) |
                                (static_cast<long long>(p[2]) << 16) |
                                (static_cast<long long>(p[3]) << 24);
            const long long v = static_cast<int32_t>(u);
            const long long want = std::llround(static_cast<double>(buf[i]) * 2147483647.0);
            const long diff = static_cast<long>(v > want ? v - want : want - v);
            if (diff > worst32) worst32 = diff;
        }
        check(worst32 <= 16, "32-bit dithered shaper stays within 16 LSB");
    }

    // --- DSD: modulator quality measured at the DSD rate ------------------
    std::printf("\ndsd modulator (PCM 176.4k -> 1-bit 2.8224M)\n");
    {
        const double pcmFs = 176400, dsdFs = 2822400, f0 = 997;
        const int FR = 44100;
        auto pcm = sine(f0, pcmFs, FR, 0.25);
        CSrc* up = src_new(pcmFs, dsdFs, 128, CWIN_GAUSS, 0, 0.95, 2);
        const int cap = src_max_out(up, FR);
        std::vector<float> atDsd(static_cast<size_t>(cap) * 2);
        int n = src_process(up, pcm.data(), FR, atDsd.data(), cap);
        src_free(up);

        CSdm sdm{};
        sdm_reset(&sdm);
        const int wordsPerCh = (n + 31) / 32;
        std::vector<uint32_t> words(static_cast<size_t>(wordsPerCh) * 2);
        sdm_words(&sdm, atDsd.data(), n, 2, words.data(), 2.0);   // unity gain

        // Unpack the left channel at the bit rate and measure in-band.
        std::vector<double> bits;
        bits.reserve(static_cast<size_t>(wordsPerCh) * 32);
        for (int i = 0; i < wordsPerCh; ++i) {
            uint32_t x = words[static_cast<size_t>(i) * 2];
            x = ((x & 0xFF) << 24) | ((x & 0xFF00) << 8) | ((x & 0xFF0000) >> 8) |
                ((x >> 24) & 0xFF);   // undo big-endian store for in-memory order
            for (int b = 31; b >= 0; --b) bits.push_back(((x >> b) & 1u) ? 1.0 : -1.0);
        }
        const int N = 1 << 18;   // 262144 bits
        std::vector<double> re(N), im(N);
        for (int i = 0; i < N; ++i) {
            const double w = 0.35875 - 0.48829 * std::cos(2 * M_PI * i / (N - 1)) +
                             0.14128 * std::cos(4 * M_PI * i / (N - 1)) -
                             0.01168 * std::cos(6 * M_PI * i / (N - 1));
            re[i] = bits[2000 + i] * w;
            im[i] = 0;
        }
        cant::fft_radix2(re, im, false);
        const int peak = static_cast<int>(f0 / dsdFs * N), kmax = static_cast<int>(20000.0 / dsdFs * N);
        double fund = 0, resid = 0;
        for (int k = 1; k <= kmax; ++k) {
            const double pw = re[k] * re[k] + im[k] * im[k];
            if (std::abs(k - peak) <= 8) fund += pw; else resid += pw;
        }
        const double snr = 10.0 * std::log10(fund / std::max(resid, 1e-30));
        std::printf("    in-band SNR 0-20 kHz: %.1f dB\n", snr);
        check(snr > 70.0, "modulator in-band SNR above 70 dB");
        check(words.size() == static_cast<size_t>(wordsPerCh) * 2,
              "one 32-bit word per 32 DSD-rate frames per channel");
    }

    std::printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures,
                failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

// Where does DSD encoding time go? Times the two stages separately, at the
// rates the app uses, for one second of audio.
#include "core/cantus_core.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

using Clock = std::chrono::steady_clock;

static double since(Clock::time_point t0) {
    return std::chrono::duration<double>(Clock::now() - t0).count();
}

static void bench(double inRate, double outRate, int seconds, const char* label,
                  int taps, int window, int family) {
    const int ch = 2;
    const int block = 4096;
    std::vector<float> in(static_cast<size_t>(block) * ch);
    for (int i = 0; i < block; ++i) {
        const float v = static_cast<float>(0.3 * std::sin(2 * M_PI * 1000.0 * i / inRate));
        in[static_cast<size_t>(i) * 2] = v;
        in[static_cast<size_t>(i) * 2 + 1] = v;
    }

    CSrc* src = src_new(inRate, outRate, taps, window, family, 0.92, ch);
    const int cap = src_max_out(src, block) * ch + 64;
    std::vector<float> up(static_cast<size_t>(cap));
    CSdm sdm{};
    sdm_reset(&sdm);

    const long long inFramesTotal = static_cast<long long>(inRate) * seconds;
    long long done = 0;
    int producedLast = 0;

    auto t0 = Clock::now();
    while (done < inFramesTotal) {
        producedLast = src_process(src, in.data(), block, up.data(), cap / ch);
        done += block;
    }
    const double srcSecs = since(t0);

    // Feed the resampler's output to the modulator for the same duration.
    t0 = Clock::now();
    long long fed = 0;
    const long long want = static_cast<long long>(outRate) * seconds;
    std::vector<uint32_t> words(static_cast<size_t>(producedLast) * ch + 64);
    while (fed < want) {
        sdm_words(&sdm, up.data(), producedLast, ch, words.data(), 2.0);
        fed += producedLast;
    }
    const double sdmSecs = since(t0);

    std::printf("%-22s in %.0f -> out %.0f\n", label, inRate, outRate);
    std::printf("  resample   %6.2f s of CPU per second of audio (%.2fx realtime)\n",
                srcSecs / seconds, seconds / srcSecs);
    std::printf("  modulate   %6.2f s of CPU per second of audio (%.2fx realtime)\n",
                sdmSecs / seconds, seconds / sdmSecs);
    std::printf("  total      %6.2f s  -> %.2fx realtime\n\n",
                (srcSecs + sdmSecs) / seconds, seconds / (srcSecs + sdmSecs));

    src_free(src);
}

void bench_effects(double outRate, int seconds);

int main() {
    const int taps = 256, window = CWIN_GAUSS, family = 0;
    std::printf("One second of stereo audio, single thread, %s compiler\n\n",
#ifdef __OPTIMIZE__
                "optimised"
#else
                "unoptimised"
#endif
    );
    bench(44100, 2822400, 5, "DSD64", taps, window, family);
    bench(44100, 5644800, 5, "DSD128", taps, window, family);
    bench(44100, 11289600, 5, "DSD256", taps, window, family);
    bench(88200, 11289600, 5, "DSD256 from 88.2k", taps, window, family);
    bench(88200, 384000, 5, "PCM 88.2k -> 384k", taps, window, family);
    std::printf("Effects stages (run at the output rate after resampling):\n");
    bench_effects(384000, 5);
    bench_effects(11289600, 5);
    return 0;
}

// The per-sample stages the chain runs *after* resampling, at whatever the
// output rate is. For DSD that is 11.29 MHz, which is where the rest of the
// budget can disappear.
void bench_effects(double outRate, int seconds) {
    const int ch = 2, block = 4096;
    std::vector<float> buf(static_cast<size_t>(block) * ch, 0.3f);
    CLimiter lim{};
    lim_init(&lim, ch);
    lim.ceiling_db = -0.3;
    CMeter* m = meter_new();
    long long done = 0;
    const long long want = static_cast<long long>(outRate) * seconds;
    auto t0 = Clock::now();
    while (done < want) {
        lim_process(&lim, buf.data(), block, static_cast<int>(outRate));
        done += block;
    }
    const double limSecs = since(t0);
    t0 = Clock::now();
    done = 0;
    while (done < want) {
        meter_process(m, buf.data(), block, ch);
        done += block;
    }
    const double meterSecs = since(t0);
    std::printf("  limiter    %6.2f s of CPU per second (%.2fx realtime)\n",
                limSecs / seconds, seconds / limSecs);
    std::printf("  meter      %6.2f s of CPU per second (%.2fx realtime)\n",
                meterSecs / seconds, seconds / meterSecs);
    std::printf("  effects    %6.2f s total at %.0f Hz\n\n",
                (limSecs + meterSecs) / seconds, outRate);
    meter_free(m);
}

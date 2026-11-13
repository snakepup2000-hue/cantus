// cantus-cli — headless verification of the same engine the app uses.
//
//   cantus-cli net  <file> [--dsd] [--seconds N]   stream to the Pi over SSH
//   cantus-cli local <file> [--seconds N]          decode + process only
//   cantus-cli probe                                Pi + DAC reachability
//   cantus-cli info <file>                          metadata the library sees
#include "core/cantus_core.h"

#include <AVFoundation/AVFoundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <csignal>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

static double nowSeconds() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// ------------------------------------------------------------------ decoding
struct PcmFile {
    AVAudioFile* file = nil;
    double rate = 0;
    int channels = 0;
    long long length = 0;
};

static bool openPcm(const std::string& path, PcmFile& out, std::string& err) {
    @autoreleasepool {
        NSString* p = [NSString stringWithUTF8String:path.c_str()];
        NSError* e = nil;
        AVAudioFile* f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:p] error:&e];
        if (!f) {
            err = e ? [[e localizedDescription] UTF8String] : "cannot open file";
            return false;
        }
        out.file = f;
        out.rate = f.processingFormat.sampleRate;
        out.channels = (int)f.processingFormat.channelCount;
        out.length = (long long)f.length;
        return true;
    }
}

// Reads interleaved stereo float. Returns frames read (0 at EOF).
static int readFrames(PcmFile& f, std::vector<float>& buf, int frames) {
    @autoreleasepool {
        if (buf.size() < (size_t)frames * 2) buf.resize((size_t)frames * 2);
        AVAudioPCMBuffer* b = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:f.file.processingFormat
                 frameCapacity:(AVAudioFrameCount)frames];
        NSError* e = nil;
        if (![f.file readIntoBuffer:b error:&e]) return 0;
        AVAudioFrameCount n = b.frameLength;
        if (n == 0) return 0;
        const int ch = (int)b.format.channelCount;
        float* const* fd = b.floatChannelData;
        if (fd) {
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                buf[i * 2] = fd[0][i];
                buf[i * 2 + 1] = ch > 1 ? fd[1][i] : fd[0][i];
            }
        } else {
            int32_t* const* id = b.int32ChannelData;
            if (!id) return 0;
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                buf[i * 2] = (float)(id[0][i] / 2147483648.0);
                buf[i * 2 + 1] = ch > 1 ? (float)(id[1][i] / 2147483648.0) : buf[i * 2];
            }
        }
        return (int)n;
    }
}

// ------------------------------------------------------------------- the sink
struct SshSink {
    pid_t pid = -1;
    int toChild = -1;
    std::string err;
    long long bytes = 0;

    bool start(const std::string& user, const std::string& host, const std::string& device,
               const char* fmt, int rate, int bufferMs, const std::string& key) {
        std::string remote = "aplay -D " + device + " -t raw -f " + fmt + " -r " +
                             std::to_string(rate) + " -c 2 --buffer-time=" +
                             std::to_string(bufferMs * 1000) + " -";
        int inPipe[2], errPipe[2];
        if (pipe(inPipe) != 0 || pipe(errPipe) != 0) return false;
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0);
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2);
        posix_spawn_file_actions_addclose(&fa, inPipe[0]);
        posix_spawn_file_actions_addclose(&fa, errPipe[1]);

        std::vector<std::string> args = {
            "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "Compression=no",
            "-o", "IdentitiesOnly=yes", "-i", key,
            user + "@" + host, remote};
        std::vector<char*> argv;
        for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
        int rc = posix_spawn(&pid, "/usr/bin/ssh", &fa, nullptr, argv.data(), environ);
        posix_spawn_file_actions_destroy(&fa);
        ::close(inPipe[0]);
        ::close(errPipe[1]);
        if (rc != 0) { err = "could not start ssh"; return false; }
        toChild = inPipe[1];
        // Keep stderr readable but non-blocking.
        fcntl(errPipe[0], F_SETFL, O_NONBLOCK);
        errFd_ = errPipe[0];
        return true;
    }

    void drainErrors() {
        if (errFd_ < 0) return;
        char buf[4096];
        ssize_t n;
        while ((n = ::read(errFd_, buf, sizeof buf)) > 0) {
            err.append(buf, (size_t)n);
            if (err.size() > 8000) err = err.substr(err.size() - 4000);
        }
    }

    bool writeBytes(const uint8_t* p, size_t n) {
        size_t off = 0;
        while (off < n) {
            ssize_t w = ::write(toChild, p + off, n - off);
            if (w <= 0) { drainErrors(); return false; }
            off += (size_t)w;
        }
        bytes += (long long)n;
        drainErrors();
        return true;
    }

    void stop() {
        if (toChild >= 0) { ::close(toChild); toChild = -1; }
        if (pid > 0) {
            int status = 0;
            for (int i = 0; i < 60; ++i) {
                pid_t r = waitpid(pid, &status, WNOHANG);
                if (r == pid) { pid = -1; break; }
                usleep(50000);
            }
            if (pid > 0) { kill(pid, SIGTERM); waitpid(pid, &status, 0); pid = -1; }
        }
        if (errFd_ >= 0) { ::close(errFd_); errFd_ = -1; }
    }

    int errFd_ = -1;
};

// --------------------------------------------------------------- the pipeline
struct Chain {
    CSrc* src = nullptr;
    CEq* eq = nullptr;
    CLimiter lim{};
    CSdm sdm{};
    double outRate = 0;
    int taps = 256, window = CWIN_GAUSS, family = 0;
    bool dsd = false;
    /// True when the source rate already equals the output rate: copy, don't
    /// filter. A ratio-1 sinc still low-passes and delays.
    bool passthrough = false;
    std::vector<float> out;

    void setup(double inRate) {
        if (src) { src_free(src); src = nullptr; }
        // outRate must already be the exact rate the modulator consumes.
        passthrough = !dsd && std::fabs(inRate - outRate) < 0.5;
        if (!passthrough) src = src_new(inRate, outRate, taps, window, family, 0.92, 2);
        if (eq) eq_free(eq);
        eq = eq_new(2, 12);
        lim_init(&lim, 2);
        sdm_reset(&sdm);
    }

    int process(const float* in, int frames) {
        if (passthrough) {
            if ((int)out.size() < frames * 2) out.resize((size_t)frames * 2);
            std::memcpy(out.data(), in, (size_t)frames * 2 * sizeof(float));
            return frames;
        }
        int cap = src_max_out(src, frames);
        if ((int)out.size() < cap * 2) out.resize((size_t)cap * 2);
        int n = src_process(src, in, frames, out.data(), cap);
        return n;
    }
};

// ----------------------------------------------------------------------- main
static void usage() {
    std::printf(
        "cantus-cli — audio path verifier\n\n"
        "  cantus-cli probe                        Pi + DAC reachability\n"
        "  cantus-cli info <file>                  metadata and format\n"
        "  cantus-cli local <file> [--seconds N]   decode + DSP, report levels\n"
        "  cantus-cli net <file> [--seconds N] [--dsd N] [--native] [--host H] [--device D]\n"
        "  cantus-cli selftest                     DSP assertions\n");
}

static int probe(const std::string& user, const std::string& host, const std::string& key) {
    std::string cmd = "ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "
                      "-o IdentitiesOnly=yes -i " + key + " " +
                      user + "@" + host +
                      " \"echo ===PLAYBACK===; aplay -l 2>&1; echo ===DAC===; "
                      "cat /proc/asound/card0/stream0 2>/dev/null\"";
    std::printf("running: %s\n\n", cmd.c_str());
    int rc = std::system(cmd.c_str());
    std::printf("\nexit status %d\n", rc);
    return rc == 0 ? 0 : 1;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 2; }
        std::string mode = argv[1];

        // Same defaults as app/Cantus/Sinks.swift (PiRig); keep in step.
        // Override with --host/--user/--key/--device or the PIBRIDGE_* env vars.
        auto envOr = [](const char* n, const char* d) {
            const char* v = std::getenv(n); return (v && *v) ? v : d;
        };
        std::string host = envOr("PIBRIDGE_HOST", "raspberrypi.local");
        std::string user = envOr("PIBRIDGE_USER", "pi");
        std::string key = envOr("PIBRIDGE_KEY", "~/.ssh/id_ed25519");
        std::string device = envOr("PIBRIDGE_DEVICE", "hw:0,0");
        double seconds = 10.0;
        int dsdMult = 0;
        bool native = false;
        std::string path;

        for (int i = 2; i < argc; ++i) {
            std::string a = argv[i];
            if (a == "--seconds" && i + 1 < argc) seconds = std::atof(argv[++i]);
            else if (a == "--dsd" && i + 1 < argc) dsdMult = std::atoi(argv[++i]);
            else if (a == "--native") native = true;
            else if (a == "--host" && i + 1 < argc) host = argv[++i];
            else if (a == "--user" && i + 1 < argc) user = argv[++i];
            else if (a == "--device" && i + 1 < argc) device = argv[++i];
            else if (a == "--key" && i + 1 < argc) key = argv[++i];
            else if (a.rfind("--", 0) != 0) path = a;
        }

        if (mode == "probe") return probe(user, host, key);
        if (mode == "help") { usage(); return 0; }

        if (mode == "info") {
            if (path.empty()) { usage(); return 2; }
            PcmFile f;
            std::string err;
            if (!openPcm(path, f, err)) { std::printf("error: %s\n", err.c_str()); return 1; }
            std::printf("file      %s\nrate      %.0f Hz\nchannels  %d\nframes    %lld\nduration  %.2f s\n",
                        path.c_str(), f.rate, f.channels, f.length,
                        f.rate > 0 ? (double)f.length / f.rate : 0);
            return 0;
        }

        if (mode != "local" && mode != "net") { usage(); return 2; }
        if (path.empty()) { usage(); return 2; }

        PcmFile in;
        std::string err;
        if (!openPcm(path, in, err)) { std::printf("error: %s\n", err.c_str()); return 1; }

        Chain chain;
        chain.dsd = dsdMult > 0;
        // --native keeps the file's own rate and skips the resampler entirely.
        chain.outRate = chain.dsd ? 2822400.0 * dsdMult / 64.0
                                  : (native ? in.rate : 384000.0);
        chain.setup(in.rate);

        SshSink sink;
        const char* wire = chain.dsd ? "DSD_U32_BE" : "S32_LE";
        int transportRate = chain.dsd ? (int)(chain.outRate / 32) : (int)chain.outRate;
        if (mode == "net") {
            if (!sink.start(user, host, device, wire, transportRate, 80, key)) {
                std::printf("error: %s\n", sink.err.c_str());
                return 1;
            }
            std::printf("streaming %s -> %s@%s %s %d Hz\n", path.c_str(), user.c_str(),
                        host.c_str(), wire, transportRate);
        } else {
            std::printf("processing %s locally: %.0f -> %.0f Hz%s\n", path.c_str(), in.rate,
                        chain.outRate, chain.dsd ? " (DSD)" : "");
        }

        std::vector<float> inBuf(4096 * 2);
        // Output frame count is the input count times the resampling ratio, so
        // the encoded buffer is sized from the converter, not the input block.
        const int maxOut = chain.passthrough ? 4096 : src_max_out(chain.src, 4096);
        std::vector<uint8_t> bytes((size_t)maxOut * 2 * 4 + 4096);
        double t0 = nowSeconds();
        long long framesIn = 0, framesOut = 0;
        double peak = 0, sumsq = 0;
        long long measured = 0;
        int blocks = 0;

        while (nowSeconds() - t0 < seconds) {
            int n = readFrames(in, inBuf, 4096);
            if (n <= 0) break;
            framesIn += n;
            int m = chain.process(inBuf.data(), n);
            if (m <= 0) continue;
            framesOut += m;
            for (int i = 0; i < m * 2; ++i) {
                double v = std::fabs(chain.out[i]);
                if (v > peak) peak = v;
                sumsq += v * v;
                ++measured;
            }
            if (mode == "net") {
                int nb = 0;
                if (chain.dsd) {
                    int words = (m + 31) / 32;
                    nb = words * 2 * 4;
                    sdm_words(&chain.sdm, chain.out.data(), m, 2,
                              (uint32_t*)bytes.data(), 2.0);
                } else {
                    nb = pcm_format(chain.out.data(), m, 2, 32, 1, 2, bytes.data());
                }
                if (!sink.writeBytes(bytes.data(), (size_t)nb)) {
                    std::printf("stream failed: %s\n", sink.err.c_str());
                    break;
                }
            }
            ++blocks;
        }
        double wall = nowSeconds() - t0;
        if (mode == "net") sink.stop();

        std::printf("\nframes in   %lld\nframes out  %lld (%.2f s of audio)\nwall        %.2f s\n"
                    "ratio       %.1fx realtime\npeak        %.4f\nrms         %.4f\n",
                    framesIn, framesOut, (double)framesOut / chain.outRate, wall,
                    ((double)framesOut / chain.outRate) / (wall > 0 ? wall : 1), peak,
                    measured ? std::sqrt(sumsq / measured) : 0.0);
        if (mode == "net") {
            std::printf("bytes sent  %lld\n", sink.bytes);
            if (!sink.err.empty()) std::printf("receiver:\n%s\n", sink.err.c_str());
        }
        if (chain.src) src_free(chain.src);
        if (chain.eq) eq_free(chain.eq);
        return 0;
    }
}

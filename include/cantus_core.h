// cantus_core.h — DSP primitives for Cantus.
//
// Everything works on interleaved float32 blocks. The Swift layer owns
// decoding, transport and the UI; this layer owns sample-rate conversion,
// equalisation, convolution, channel routing, limiting, PCM quantisation and
// delta-sigma modulation.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CSrc CSrc;
typedef struct CEq CEq;
typedef struct CConv CConv;
typedef struct CMeter CMeter;

enum {
    CWIN_RECT = 0, CWIN_GAUSS, CWIN_KAISER, CWIN_BLACKMAN_HARRIS, CWIN_LANCZOS
};

// ---------------------------------------------------------------- resampler
// Arbitrary-ratio windowed-sinc converter. `taps` is per-phase, `family` 0 =
// linear phase, 1 = minimum phase (cepstral), 2 = closed-form (no window).
CSrc* src_new(double in_rate, double out_rate, int taps, int window, int family,
              double rolloff, int channels);
void  src_free(CSrc* r);
void  src_reset(CSrc* r);
void  src_set_trim(CSrc* r, double trim);   // micro rate trim, 1.0 = nominal
// Upper bound on output frames for a given input block.
int   src_max_out(CSrc* r, int in_frames);
// out_cap must be >= src_max_out(). Returns frames written.
int   src_process(CSrc* r, const float* in, int in_frames, float* out, int out_cap);
int   src_channels(CSrc* r);

// ------------------------------------------------------------------------ EQ
// 12 biquad bands; type: 0 peaking, 1 lowshelf, 2 highshelf, 3 lowpass,
// 4 highpass, 5 notch, 6 allpass, 7 tilt.
CEq*   eq_new(int channels, int bands);
void   eq_free(CEq* e);
void   eq_reset(CEq* e);
void   eq_set_band(CEq* e, int band, int type, double freq, double gain_db,
                   double q, int enabled);
void   eq_set_eq_enabled(CEq* e, int enabled);
void   eq_process(CEq* e, float* buf, int frames, int in_rate);
int    eq_get_band_count(CEq* e);

// ---------------------------------------------------------------- convolution
// Overlap-save FIR convolution using a partitioned FFT. `ir` is interleaved
// with `channels` channels (1 = mono IR applied to all channels).
CConv* conv_new(int channels, const float* ir, int ir_frames, int ir_channels);
void   conv_free(CConv* c);
void   conv_reset(CConv* c);
// Processes in place. Returns 0 on success.
int    conv_process(CConv* c, float* buf, int frames);
// Latency in frames introduced by the block structure.
int    conv_latency(CConv* c);

// -------------------------------------------------------------------- matrix
// 2x2 gain matrix. For mono input use gLL=gLR. Unused taps are zero.
typedef struct { double gLL, gLR, gRL, gRR; } CMatrix;

// ------------------------------------------------------------------- limiter
// Look-ahead brickwall limiter / clip guard.
typedef struct {
    double ceiling_db;   // e.g. -0.1
    double release_ms;   // e.g. 120
    double attack_ms;    // e.g. 1.5
    double gain, env;
    int    init;
    int    channels;
} CLimiter;
void   lim_init(CLimiter* l, int channels);
void   lim_process(CLimiter* l, float* buf, int frames, int rate);
void   lim_reset(CLimiter* l);

// ------------------------------------------------------------- PCM formatting
// float32 -> interleaved integer PCM with TPDF dither and optional 2nd-order
// noise shaping. bits: 16, 24 (packed 3-byte) or 32. Returns bytes written.
int    pcm_format(const float* in, int frames, int channels, int bits,
                  int dither, int shaper, uint8_t* out);

// ---------------------------------------------------------------- metering
CMeter* meter_new(void);
void    meter_free(CMeter* m);
void    meter_reset(CMeter* m);
void    meter_process(CMeter* m, const float* buf, int frames, int channels);
void    meter_get(CMeter* m, double* peak_l, double* peak_r,
                  double* rms_l, double* rms_r);

// ------------------------------------------------------- delta-sigma (DSD out)
// 4th-order 1-bit modulator. Input must already be at the DSD bit rate.
// State is per channel (two channels are enough for everything here).
typedef struct {
    double s0[2], s1[2], s2[2], s3[2];
    int    last[2], run[2];
} CSdm;
void    sdm_reset(CSdm* s);
// 1-bit modulators keep 6 dB of headroom internally, so a normalised input of
// +-1.0 maps to a reconstructed level of +-0.5. Pass gain = 2.0 for unity.
// Produces one 32-bit word per 32 DSD-rate input frames, oldest bit in the MSB.
void    sdm_words(CSdm* s, const float* stereo, int frames, int ch,
                  uint32_t* out_words, double gain);
void    sdm_pack_dop(CSdm* s, const float* stereo, int frames, int ch,
                     uint8_t* out_bytes, double gain);

// --------------------------------------------------------------- DSD input
// Multi-stage halfband decimation: DSD bit rate -> PCM at bitrate/2^stages.
typedef struct CdsdIn CdsdIn;
CdsdIn* dsdin_new(int channels, int decim_stages, double scale);
void     dsdin_free(CdsdIn* d);
void     dsdin_reset(CdsdIn* d);
// in: interleaved DSD_U32_BE words, `ch` words per frame, 32 DSD bits each,
// oldest bit in the MSB. This is exactly the layout ALSA uses for DSD_U32_BE.
// out: float at bitrate / 2^stages. Returns frames written.
int      dsdin_process(CdsdIn* d, const uint8_t* in, int words_per_ch, int channels,
                       float* out, int out_cap);

// ------------------------------------------------------------------- helpers
// Average magnitude response probe used by the self-test / UI curve.
void   probe_response(const float* ir, int n, float* mag_db, int bins, double fs);

#ifdef __cplusplus
}
#endif

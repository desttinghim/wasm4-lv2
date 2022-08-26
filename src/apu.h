#pragma once

#include <stdint.h>
#include <stddef.h>

#define W4_SAMPLE_RATE 44100
#define W4_MAX_VOLUME 0x1333 // ~15% of INT16_MAX
#define W4_MAX_VOLUME_TRIANGLE 0x2000 // ~25% of INT16_MAX

typedef struct {
    /** Starting frequency. */
    uint16_t freq1;

    /** Ending frequency, or zero for no frequency transition. */
    uint16_t freq2;

    /** Time the tone was started. */
    unsigned long long startTime;

    /** Time at the end of the attack period. */
    unsigned long long attackTime;

    /** Time at the end of the decay period. */
    unsigned long long decayTime;

    /** Time at the end of the sustain period. */
    unsigned long long sustainTime;

    /** Time the tone should end. */
    unsigned long long releaseTime;

    /** Sustain volume level. */
    int16_t sustainVolume;

     /** Peak volume level at the end of the attack phase. */
    int16_t peakVolume;

    /** Used for time tracking. */
    float phase;

    /** Tone panning. 0 = center, 1 = only left, 2 = only right. */
    uint8_t pan;

    union {
        struct {
            /** Duty cycle for pulse channels. */
            float dutyCycle;
        } pulse;

        struct {
            /** Noise generation state. */
            uint16_t seed;

            /** The last generated random number, either -1 or 1. */
            int16_t lastRandom;
        } noise;
    };
} WASM4_Channel;

typedef struct {
    /** The state of each channel  */
    WASM4_Channel channels[4];

    /** The current time, in samples. */
    unsigned long long time;
} WASM4_APU;

void w4_apuInit (WASM4_APU* apu);

void w4_apuTone (WASM4_APU* apu, int frequency, int duration, int volume, int flags);

void w4_apuWriteSamples (WASM4_APU* apu, int16_t* output, unsigned long frames);

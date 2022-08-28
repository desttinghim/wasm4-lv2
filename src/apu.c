#include "apu.h"

#include <stdlib.h>
#include <math.h>

typedef WASM4_APU APU;
typedef WASM4_Channel Channel;

static int w4_min (int a, int b) {
    return a < b ? a : b;
}

static int lerp (int value1, int value2, float t) {
    return value1 + t * (value2 - value1);
}

static int ramp (int value1, int value2, unsigned long long time, unsigned long long time1, unsigned long long time2) {
    float t = (float)(time - time1) / (time2 - time1);
    return lerp(value1, value2, t);
}

static uint16_t getCurrentFrequency (const Channel* channel, unsigned long long time) {
    if (channel->freq2 > 0) {
        return ramp(channel->freq1, channel->freq2, time, channel->startTime, channel->releaseTime);
    } else {
        return channel->freq1;
    }
}

static int16_t getCurrentVolume (const Channel* channel, unsigned long long time) {
    if (time >= channel->sustainTime) {
        // Release
        return ramp(channel->sustainVolume, 0, time, channel->sustainTime, channel->releaseTime);
    } else if (time >= channel->decayTime) {
        // Sustain
        return channel->sustainVolume;
    } else if (time >= channel->attackTime) {
        // Decay
        return ramp(channel->peakVolume, channel->sustainVolume, time, channel->attackTime, channel->decayTime);
    } else {
        // Attack
        return ramp(0, channel->peakVolume, time, channel->startTime, channel->attackTime);
    }
}

static float polyblep (float phase, float phaseInc) {
    if (phase < phaseInc) {
        float t = phase / phaseInc;
        return t+t - t*t;
    } else if (phase > 1.f - phaseInc) {
        float t = (phase - (1.f - phaseInc)) / phaseInc;
        return 1.f - (t+t - t*t);
    } else {
        return 1.f;
    }
}

void w4_apuInit (APU *apu, uint32_t sample_rate) {
    apu->channels[3].noise.seed = 0x0001;
    apu->time = 0;
    apu->sample_rate = sample_rate;
    apu->max_volume = 0x1333; // ~15% of INT16_MAX
    apu->max_volume_triangle = 0x2000; // ~25% of INT16_MAX
    for (int channelIdx = 0; channelIdx < 4; ++channelIdx) {
        Channel* channel = &apu->channels[channelIdx];
        channel->freq1 = 0;
        channel->freq2 = 0;
        channel->startTime = 0;
        channel->attackTime = 0;
        channel->decayTime = 0;
        channel->sustainTime = 0;
        channel->releaseTime = 0;
        channel->sustainVolume = 0;
        channel->peakVolume = 0;
        channel->phase = 0;
        channel->pan = 0;
    }
}

void w4_apuTone (WASM4_APU* apu, uint32_t frequency, uint32_t duration, uint32_t volume, uint32_t flags) {
    int freq1 = frequency & 0xffff;
    int freq2 = (frequency >> 16) & 0xffff;

    int sustain = duration & 0xff;
    int release = (duration >> 8) & 0xff;
    int decay = (duration >> 16) & 0xff;
    int attack = (duration >> 24) & 0xff;

    int sustainVolume = w4_min(volume & 0xff, 100);
    int peakVolume = w4_min((volume >> 8) & 0xff, 100);

    int channelIdx = flags & 0x03;
    int mode = (flags >> 2) & 0x3;
    int pan = (flags >> 4) & 0x3;

    // TODO(2022-01-08): Thread safety
    Channel* channel = &apu->channels[channelIdx];

    // Restart the phase if this channel wasn't already playing
    if (apu->time > channel->releaseTime) {
        channel->phase = (channelIdx == 2) ? 0.25 : 0;
    }

    channel->freq1 = freq1;
    channel->freq2 = freq2;
    channel->startTime = apu->time;
    channel->attackTime = channel->startTime + apu->sample_rate*attack/60;
    channel->decayTime = channel->attackTime + apu->sample_rate*decay/60;
    channel->sustainTime = channel->decayTime + apu->sample_rate*sustain/60;
    channel->releaseTime = channel->sustainTime + apu->sample_rate*release/60;
    int16_t maxVolume = (channelIdx == 2) ? apu->max_volume_triangle : apu->max_volume;
    channel->sustainVolume = maxVolume * sustainVolume/100;
    channel->peakVolume = peakVolume ? maxVolume * peakVolume/100 : maxVolume;
    channel->pan = pan;

    if (channelIdx == 0 || channelIdx == 1) {
        switch (mode) {
        case 0:
            channel->pulse.dutyCycle = 0.125f;
            break;
        case 1: case 3: default:
            channel->pulse.dutyCycle = 0.25f;
            break;
        case 2:
            channel->pulse.dutyCycle = 0.5f;
            break;
        }

    } else if (channelIdx == 2) {
        // For the triangle channel, prevent popping on hard stops by adding a 1 ms release
        if (release == 0) {
            channel->releaseTime += W4_SAMPLE_RATE/1000;
        }
    }
}

void w4_apuWriteSamples (APU *apu, int16_t* output, unsigned long frames) {
    for (int ii = 0; ii < frames; ++apu->time) {
        int16_t mix_left = 0, mix_right = 0;

        for (int channelIdx = 0; channelIdx < 4; ++channelIdx) {
            Channel* channel = &apu->channels[channelIdx];

            if (apu->time < channel->releaseTime) {
                uint16_t freq = getCurrentFrequency(channel, apu->time);
                int16_t volume = getCurrentVolume(channel, apu->time);
                int16_t sample;

                if (channelIdx == 3) {
                    // Noise channel
                    channel->phase += freq * freq / (1000000.f/44100 * W4_SAMPLE_RATE);
                    while (channel->phase > 0) {
                        channel->phase--;
                        channel->noise.seed ^= channel->noise.seed >> 7;
                        channel->noise.seed ^= channel->noise.seed << 9;
                        channel->noise.seed ^= channel->noise.seed >> 13;
                        channel->noise.lastRandom = 2 * (channel->noise.seed & 0x1) - 1;
                    }
                    sample = volume * channel->noise.lastRandom;

                } else {
                    float phaseInc = (float)freq / W4_SAMPLE_RATE;
                    channel->phase += phaseInc;

                    if (channel->phase >= 1) {
                        channel->phase--;
                    }

                    if (channelIdx == 2) {
                        // Triangle channel
                        sample = volume * (2*fabs(2*channel->phase - 1) - 1);

                    } else {
                        // Pulse channel
                        float dutyPhase, dutyPhaseInc;
                        int16_t multiplier;

                        // Map duty to 0->1
                        if (channel->phase < channel->pulse.dutyCycle) {
                            dutyPhase = channel->phase / channel->pulse.dutyCycle;
                            dutyPhaseInc = phaseInc / channel->pulse.dutyCycle;
                            multiplier = volume;
                        } else {
                            dutyPhase = (channel->phase - channel->pulse.dutyCycle) / (1.f - channel->pulse.dutyCycle);
                            dutyPhaseInc = phaseInc / (1.f - channel->pulse.dutyCycle);
                            multiplier = -volume;
                        }
                        sample = multiplier * polyblep(dutyPhase, dutyPhaseInc);
                    }
                }

                if (channel->pan != 1) {
                    mix_right += sample;
                }
                if (channel->pan != 2) {
                    mix_left += sample;
                }
            }
        }

        output[ii] = mix_left;
        ii += 1;
        output[ii] = mix_right;
        ii += 1;
    }
}

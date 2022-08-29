# WASM4 LV2 Instrument

This is an [LV2](https://lv2plug.in/) instrument plugin for the [WASM4
APU](https://wasm4.org/). The main purpose is to make writing music for WASM4
easier by providing a more accurate representation of the final result.

## Dependencies

### Must be installed
- git
- zig 0.10.0-dev.3685+dae7aeb33 (latest master branch at time of writing)

## Submodules
- lv2

## Building

Depends on zig

``` shellsession
git clone --recursive https://github.com/desttinghim/wasm4-lv2
zig build bundle
```

## Installing

Assuming you have already run the commands in [Building](#Building) and you are
on a linux host.

``` shellsession
cp -r zig-out/wasm4.lv2/ ~/.lv2/
```

## Using

After installing, the plugin should now be available in any lv2 host, such as
[Ardour](https://ardour.org/).

### Parameters

- Channel: which channel the notes will play back on (Pulse 1, Pulse 2,
  Triangle, Noise)
- Attack: controls attack duration, measured in seconds
- Decay: controls decay duration, measured in seconds
- Sustain: controls sustain duration, measured in seconds. Only used if sustain
  mode is off.
- Release: controls release duration, measured in seconds. When sustain mode is
  on, release is activated only when the note off event is sent.
- Peak: highest volume reached by attack duration
- Pan: center, left, or right
- Volume: sustain volume of note
- Mode: used only by pulse channels. Controls pulse width of wave
- Start Frequency: the start frequency of each note. Only used if End Frequency
  is not 0
- End Frequency: the end frequency of each note. Ignored if the value is 0
- Sustain Mode: controls how the plugin sends notes to the WASM4 APU. When on,
  notes are sustained until note off. When off, notes use the parameters as set.

### MIDI Notes

Notes are currently played with a sustain time of 255 until a note off
instruction is released - then the note is played back with just the release
duration. There is a lot of room for improvement on this.

## TODO

This plugin is a work in progress, there is still some items left to work on.

- [x] Stereo output ~~(currently only one channel is playing back)~~
- [x] Provide releases and better install instructions
- [ ] Better handling of notes
- [ ] Detect slides/handle midi pitch bend
- [x] Percussion mode (called sustain mode now)
- [ ] Drumkit
- [ ] Support multiple midi channels

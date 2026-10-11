# Test fixtures

Real FreeDV 2400B speech, used by `FixtureTests.swift`.

| File | What it is |
|-|-|
| `ve9qrp_2400b_voice_frames.bin` | All 2,810 voice frames demodulated from the VE9QRP FreeDV 2400B recording. Headerless: 7-byte packed Codec2 1300 frames, MSB first, low nibble of byte 6 zero. Copied unchanged from [dkaukov/esp32-freedv2400b `test/fixtures`](https://github.com/dkaukov/esp32-freedv2400b/tree/main/test/fixtures). SHA-256 `f2d71011d274bc6d259d16f3db53c596b03ce51c43fd3dc9562d034e6c3c3884`. |
| `ve9qrp_c2dec_rms.bin` | Per-frame RMS (UInt16 LE, one per frame) of upstream `c2dec 1300` decoding the file above. |
| `ve9qrp_c2dec_first3s.raw` | First 75 frames (3 s) of that `c2dec` output: 8 kHz mono Int16 LE. |
| `ve9qrp_c2dec_first3s_c2enc.bin` | Upstream `c2enc 1300` encoding of the 3 s clip. |

## Regenerating the goldens

Build upstream codec2 **1.2.0** (`cmake -DUNITTEST=OFF`, targets `c2enc c2dec`), then:

```bash
c2dec 1300 ve9qrp_2400b_voice_frames.bin dec.raw
head -c 48000 dec.raw > ve9qrp_c2dec_first3s.raw
c2enc 1300 ve9qrp_c2dec_first3s.raw ve9qrp_c2dec_first3s_c2enc.bin
```

`ve9qrp_c2dec_rms.bin` is the rounded RMS of each 320-sample frame of `dec.raw`.

## License

The recording comes from [drowe67/freedv-gui](https://github.com/drowe67/freedv-gui) and was packaged by Fedora as GPL-2.0-or-later. Everything here is derived from it, so it's under the same license.

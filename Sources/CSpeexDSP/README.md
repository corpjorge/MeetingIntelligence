# SpeexDSP echo cancellation subset

Vendored, unmodified upstream sources from SpeexDSP 1.2.1 (BSD-3-Clause).
Source: https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz
Archive SHA-256: 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d

Only the acoustic echo canceller and
smallft FFT backend are compiled. SwiftPM supplies FLOATING_POINT, USE_SMALLFT
and an empty EXPORT macro; no configure-generated header is required on macOS.
CSpeexDSP.h is our umbrella header. COPYING and all upstream source notices are
retained. No capture, device, gain, network, or playback APIs are involved.

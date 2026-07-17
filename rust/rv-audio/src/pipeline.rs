//! Offline-path capture pipeline (design doc §2-1):
//!
//! 48 kHz capture → RNNoise denoise (480-sample / 10 ms frames)
//! → 3:1 downsample to 16 kHz → Opus VOIP encode (320-sample / 20 ms frames).
//!
//! RNNoise and Opus use different frame cadences (10 ms vs 20 ms), so the
//! pipeline buffers input and emits one encoded packet per two denoised
//! frames.

use crate::opus_codec::{OpusCodec, FRAME_SIZE as OPUS_FRAME};
use crate::resample::Resampler;
use crate::rnnoise::RNNoiseProcessor;

/// Samples of 48 kHz input consumed per encoded packet (2 × 480 = 20 ms).
pub const INPUT_FRAME_48K: usize = 960;

/// One encoded 20 ms packet plus the voice-activity probability RNNoise
/// assigned to it. The caller applies the design-doc VAD silence skip by
/// dropping packets whose `vad` falls below its threshold (DTX inside the
/// encoder additionally shrinks silent packets).
pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub vad: f32,
}

pub struct CapturePipeline {
    denoiser: RNNoiseProcessor,
    resampler: Resampler,
    codec: OpusCodec,
    pending_48k: Vec<f32>,
}

impl CapturePipeline {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            denoiser: RNNoiseProcessor::new()?,
            resampler: Resampler::new(),
            codec: OpusCodec::new()?,
            pending_48k: Vec::new(),
        })
    }

    /// Feed captured 48 kHz mono samples (i16 range, f32 encoded, as
    /// produced by the platform DSP stage). Returns zero or more encoded
    /// 20 ms packets depending on how much audio has accumulated.
    pub fn process_capture(&mut self, input_48k: &[f32]) -> Result<Vec<EncodedFrame>, String> {
        self.pending_48k.extend_from_slice(input_48k);

        let mut out = Vec::new();
        while self.pending_48k.len() >= INPUT_FRAME_48K {
            let chunk: Vec<f32> = self.pending_48k.drain(..INPUT_FRAME_48K).collect();

            let rn_frame = RNNoiseProcessor::frame_size();
            let mut denoised = Vec::with_capacity(INPUT_FRAME_48K);
            let mut vad_max = 0.0f32;
            for frame in chunk.chunks(rn_frame) {
                let (clean, vad) = self.denoiser.process_frame(frame)?;
                vad_max = vad_max.max(vad);
                denoised.extend(clean);
            }

            let pcm_16k = self.resampler.resample_48k_to_16k(&denoised)?;
            debug_assert_eq!(pcm_16k.len(), OPUS_FRAME);
            let pcm_i16: Vec<i16> = pcm_16k
                .iter()
                .map(|s| s.round().clamp(i16::MIN as f32, i16::MAX as f32) as i16)
                .collect();

            let data = self.codec.encode(&pcm_i16)?;
            out.push(EncodedFrame { data, vad: vad_max });
        }
        Ok(out)
    }
}

/// Receive-side pipeline: Opus decode → upsample to 48 kHz for playback.
pub struct PlaybackPipeline {
    codec: OpusCodec,
    resampler: Resampler,
}

impl PlaybackPipeline {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            codec: OpusCodec::new()?,
            resampler: Resampler::new(),
        })
    }

    pub fn decode_packet(&mut self, packet: &[u8]) -> Result<Vec<f32>, String> {
        let pcm_16k = self.codec.decode(packet, false)?;
        let f32_16k: Vec<f32> = pcm_16k.iter().map(|s| *s as f32).collect();
        self.resampler.resample_16k_to_48k(&f32_16k)
    }

    /// Conceal one lost 20 ms packet (design doc §6-3 PLC).
    pub fn conceal_lost_packet(&mut self) -> Result<Vec<f32>, String> {
        let pcm_16k = self.codec.conceal_lost_frame()?;
        let f32_16k: Vec<f32> = pcm_16k.iter().map(|s| *s as f32).collect();
        self.resampler.resample_16k_to_48k(&f32_16k)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn sine_48k(freq: f32, len: usize, amplitude: f32) -> Vec<f32> {
        (0..len)
            .map(|i| (i as f32 / 48000.0 * freq * 2.0 * PI).sin() * amplitude)
            .collect()
    }

    #[test]
    fn test_frame_cadence() {
        let mut pipe = CapturePipeline::new().unwrap();

        // 100 ms of audio = 4800 samples at 48 kHz = 5 packets of 20 ms.
        let out = pipe
            .process_capture(&sine_48k(440.0, 4800, 8000.0))
            .unwrap();
        assert_eq!(out.len(), 5);

        // A partial frame stays buffered until completed.
        assert_eq!(pipe.process_capture(&[0.0; 500]).unwrap().len(), 0);
        assert_eq!(pipe.process_capture(&[0.0; 460]).unwrap().len(), 1);
    }

    #[test]
    fn test_capture_to_playback_roundtrip() {
        let mut capture = CapturePipeline::new().unwrap();
        let mut playback = PlaybackPipeline::new().unwrap();

        let input = sine_48k(440.0, 4800, 8000.0);
        let packets = capture.process_capture(&input).unwrap();
        assert!(!packets.is_empty());

        let mut samples = 0usize;
        for p in &packets {
            let pcm = playback.decode_packet(&p.data).unwrap();
            assert_eq!(pcm.len(), INPUT_FRAME_48K);
            samples += pcm.len();
        }
        assert_eq!(samples, input.len());
    }

    #[test]
    fn test_vad_distinguishes_tone_from_silence() {
        let mut pipe = CapturePipeline::new().unwrap();

        // Feed a second of silence, then a second of a loud voice-band tone.
        let mut silence_vad = 1.0f32;
        for _ in 0..50 {
            for f in pipe
                .process_capture(&vec![0.0f32; INPUT_FRAME_48K])
                .unwrap()
            {
                silence_vad = f.vad;
            }
        }
        let mut tone_vad_max = 0.0f32;
        for _ in 0..50 {
            let tone = sine_48k(300.0, INPUT_FRAME_48K, 8000.0);
            for f in pipe.process_capture(&tone).unwrap() {
                tone_vad_max = tone_vad_max.max(f.vad);
            }
        }
        assert!(
            silence_vad < tone_vad_max,
            "VAD gives silence ({}) >= tone ({})",
            silence_vad,
            tone_vad_max
        );
    }

    #[test]
    fn test_playback_conceals_loss() {
        let mut capture = CapturePipeline::new().unwrap();
        let mut playback = PlaybackPipeline::new().unwrap();

        let packets = capture
            .process_capture(&sine_48k(440.0, 4800, 8000.0))
            .unwrap();
        for p in &packets[..3] {
            playback.decode_packet(&p.data).unwrap();
        }
        let concealed = playback.conceal_lost_packet().unwrap();
        assert_eq!(concealed.len(), INPUT_FRAME_48K);
    }
}

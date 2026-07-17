use opus::{Application, Bitrate, Channels, Decoder, Encoder};

/// Samples per 20 ms frame at 16 kHz (design doc §2-3).
pub const FRAME_SIZE: usize = 320;
/// Largest decode output Opus permits: 120 ms at 16 kHz.
const MAX_DECODE_SAMPLES: usize = 1920;

pub struct OpusCodec {
    encoder: Encoder,
    decoder: Decoder,
    sample_rate: u32,
}

impl OpusCodec {
    /// Codec configured with the design-doc §2-3 values:
    /// VOIP mode, 16 kHz mono, 16 kbps, 20 ms frames, in-band FEC,
    /// DTX, complexity 5.
    pub fn new() -> Result<Self, String> {
        let sample_rate = 16000u32;
        let channels = Channels::Mono;

        let mut encoder = Encoder::new(sample_rate, channels, Application::Voip)
            .map_err(|e| format!("Opus encoder: {}", e))?;
        encoder
            .set_bitrate(Bitrate::Bits(16000))
            .map_err(|e| format!("Opus set_bitrate: {}", e))?;
        encoder
            .set_inband_fec(true)
            .map_err(|e| format!("Opus set_inband_fec: {}", e))?;
        // FEC only activates when the encoder expects loss; WiFi Direct
        // mesh loss is assumed around 10%.
        encoder
            .set_packet_loss_perc(10)
            .map_err(|e| format!("Opus set_packet_loss_perc: {}", e))?;
        encoder
            .set_dtx(true)
            .map_err(|e| format!("Opus set_dtx: {}", e))?;
        encoder
            .set_complexity(5)
            .map_err(|e| format!("Opus set_complexity: {}", e))?;

        let decoder =
            Decoder::new(sample_rate, channels).map_err(|e| format!("Opus decoder: {}", e))?;

        Ok(Self {
            encoder,
            decoder,
            sample_rate,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>, String> {
        if !pcm.len().is_multiple_of(FRAME_SIZE) {
            return Err(format!(
                "PCM must be multiples of {} samples (20ms @ 16kHz), got {}",
                FRAME_SIZE,
                pcm.len()
            ));
        }
        let max_packet_size = 4000;
        let mut output = vec![0u8; max_packet_size];
        let bytes_written = self
            .encoder
            .encode(pcm, &mut output)
            .map_err(|e| format!("Opus encode: {}", e))?;
        output.truncate(bytes_written);
        Ok(output)
    }

    pub fn decode(&mut self, packet: &[u8], fec: bool) -> Result<Vec<i16>, String> {
        // Buffer sized for the longest legal Opus frame; the decoder tells
        // us how many samples were actually produced.
        let mut output = vec![0i16; MAX_DECODE_SAMPLES];
        let samples = self
            .decoder
            .decode(packet, &mut output, fec)
            .map_err(|e| format!("Opus decode: {}", e))?;
        output.truncate(samples);
        Ok(output)
    }

    /// Recover a single lost 20 ms frame from the FEC data embedded in the
    /// *following* packet (design doc §6-3: 1-packet loss recovery).
    pub fn decode_fec_lost_frame(&mut self, next_packet: &[u8]) -> Result<Vec<i16>, String> {
        let mut output = vec![0i16; FRAME_SIZE];
        let samples = self
            .decoder
            .decode(next_packet, &mut output, true)
            .map_err(|e| format!("Opus FEC decode: {}", e))?;
        output.truncate(samples);
        Ok(output)
    }

    /// Packet-loss concealment: synthesise a plausible 20 ms frame when a
    /// packet is lost and no FEC data is available (design doc §6-3 PLC).
    pub fn conceal_lost_frame(&mut self) -> Result<Vec<i16>, String> {
        let mut output = vec![0i16; FRAME_SIZE];
        let samples = self
            .decoder
            .decode(&[], &mut output, false)
            .map_err(|e| format!("Opus PLC decode: {}", e))?;
        output.truncate(samples);
        Ok(output)
    }

    pub fn frame_size() -> usize {
        FRAME_SIZE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn sine_frame(freq: f32, frames: usize) -> Vec<i16> {
        (0..FRAME_SIZE * frames)
            .map(|i| {
                let t = i as f32 / 16000.0;
                ((t * freq * 2.0 * PI).sin() * 8000.0) as i16
            })
            .collect()
    }

    fn energy(pcm: &[i16]) -> f64 {
        pcm.iter().map(|&s| (s as f64) * (s as f64)).sum::<f64>() / pcm.len() as f64
    }

    #[test]
    fn test_codec_creation() {
        let codec = OpusCodec::new();
        assert!(codec.is_ok());
    }

    #[test]
    fn test_encode_decode_roundtrip() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = sine_frame(440.0, 1);
        let encoded = codec.encode(&pcm).unwrap();
        assert!(!encoded.is_empty());

        let decoded = codec.decode(&encoded, false).unwrap();
        assert_eq!(decoded.len(), FRAME_SIZE);
    }

    #[test]
    fn test_invalid_frame_size() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = vec![0i16; 100];
        let result = codec.encode(&pcm);
        assert!(result.is_err());
    }

    /// Communication quality: a voice-band tone must survive the codec with
    /// most of its energy intact (bitrate/complexity misconfiguration would
    /// show up as collapsed output energy).
    #[test]
    fn test_roundtrip_preserves_signal_energy() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = sine_frame(440.0, 10);

        let mut decoded_all = Vec::new();
        for frame in pcm.chunks(FRAME_SIZE) {
            let packet = codec.encode(frame).unwrap();
            decoded_all.extend(codec.decode(&packet, false).unwrap());
        }

        // Skip the first two frames (codec warm-up/lookahead).
        let in_energy = energy(&pcm[FRAME_SIZE * 2..]);
        let out_energy = energy(&decoded_all[FRAME_SIZE * 2..]);
        let ratio = out_energy / in_energy;
        assert!(
            (0.5..=2.0).contains(&ratio),
            "energy ratio {} outside tolerance; codec is mangling audio",
            ratio
        );
    }

    /// Design §2-3: average bitrate must be near the configured 16 kbps
    /// (one 20 ms packet ≈ 40 bytes).
    #[test]
    fn test_bitrate_configuration() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = sine_frame(440.0, 50);

        let total_bytes: usize = pcm
            .chunks(FRAME_SIZE)
            .map(|f| codec.encode(f).unwrap().len())
            .sum();
        let avg_bits_per_sec = (total_bytes as f64 * 8.0) / (50.0 * 0.02);
        assert!(
            avg_bits_per_sec < 24000.0,
            "average bitrate {} bps far above configured 16 kbps",
            avg_bits_per_sec
        );
    }

    /// Design §2-3 DTX: silence should shrink to tiny keep-alive packets.
    #[test]
    fn test_dtx_suppresses_silence() {
        let mut codec = OpusCodec::new().unwrap();
        let silence = vec![0i16; FRAME_SIZE];

        // Feed sustained silence; after the hangover period DTX emits
        // <= 2-byte packets.
        let sizes: Vec<usize> = (0..50)
            .map(|_| codec.encode(&silence).unwrap().len())
            .collect();
        let tail_min = *sizes[10..].iter().min().unwrap();
        assert!(
            tail_min <= 2,
            "DTX not engaging: smallest silence packet was {} bytes",
            tail_min
        );
    }

    /// Design §6-3: single packet loss must be recoverable via in-band FEC
    /// from the following packet, yielding a full 20 ms frame.
    #[test]
    fn test_fec_recovers_single_lost_packet() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = sine_frame(440.0, 10);
        let packets: Vec<Vec<u8>> = pcm
            .chunks(FRAME_SIZE)
            .map(|f| codec.encode(f).unwrap())
            .collect();

        // Decode normally until packet 5 is "lost"; recover it from
        // packet 6's FEC data, then continue.
        for p in &packets[..5] {
            codec.decode(p, false).unwrap();
        }
        let recovered = codec.decode_fec_lost_frame(&packets[6]).unwrap();
        assert_eq!(recovered.len(), FRAME_SIZE);
        assert!(
            energy(&recovered) > 0.0,
            "FEC recovery produced dead silence"
        );
        let next = codec.decode(&packets[6], false).unwrap();
        assert_eq!(next.len(), FRAME_SIZE);
    }

    /// Design §6-3 PLC: with no FEC available, concealment must still
    /// produce a full frame (not silence-gap dropout).
    #[test]
    fn test_plc_conceals_lost_packet() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = sine_frame(440.0, 5);
        for frame in pcm.chunks(FRAME_SIZE) {
            let p = codec.encode(frame).unwrap();
            codec.decode(&p, false).unwrap();
        }
        let concealed = codec.conceal_lost_frame().unwrap();
        assert_eq!(concealed.len(), FRAME_SIZE);
        assert!(
            energy(&concealed) > 0.0,
            "PLC produced dead silence after a loud tone"
        );
    }
}

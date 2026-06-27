use opus::{Decoder, Encoder, Application, Channels};

pub struct OpusCodec {
    encoder: Encoder,
    decoder: Decoder,
    sample_rate: u32,
}

impl OpusCodec {
    pub fn new() -> Result<Self, String> {
        let sample_rate = opus::SampleRate::Hz16000;
        let channels = Channels::Mono;

        let encoder = Encoder::new(sample_rate, channels, Application::Voip)
            .map_err(|e| format!("Opus encoder: {}", e))?;

        let decoder = Decoder::new(sample_rate, channels)
            .map_err(|e| format!("Opus decoder: {}", e))?;

        Ok(Self {
            encoder,
            decoder,
            sample_rate: 16000,
        })
    }

    pub fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>, String> {
        if pcm.len() % 320 != 0 {
            return Err(format!(
                "PCM must be multiples of 320 samples (20ms @ 16kHz), got {}",
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
        let frame_size = 320;
        let mut output = vec![0i16; frame_size];
        let samples = self
            .decoder
            .decode(packet, &mut output, fec)
            .map_err(|e| format!("Opus decode: {}", e))?;
        output.truncate(samples);
        Ok(output)
    }

    pub fn frame_size() -> usize {
        320
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_codec_creation() {
        let codec = OpusCodec::new();
        assert!(codec.is_ok());
    }

    #[test]
    fn test_encode_decode_roundtrip() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = vec![100i16; 320];
        let encoded = codec.encode(&pcm).unwrap();
        assert!(!encoded.is_empty());

        let decoded = codec.decode(&encoded, false).unwrap();
        assert!(!decoded.is_empty());
    }

    #[test]
    fn test_invalid_frame_size() {
        let mut codec = OpusCodec::new().unwrap();
        let pcm = vec![0i16; 100];
        let result = codec.encode(&pcm);
        assert!(result.is_err());
    }
}

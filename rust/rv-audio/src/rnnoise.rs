use nnnoiseless::DenoiseState;

const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;

pub struct RNNoiseProcessor {
    state: Box<DenoiseState<'static>>,
}

impl RNNoiseProcessor {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            state: DenoiseState::new(),
        })
    }

    pub fn process_frame(&mut self, input: &[f32]) -> Result<(Vec<f32>, f32), String> {
        if input.len() != FRAME_SIZE {
            return Err(format!(
                "Input frame must be {} samples, got {}",
                FRAME_SIZE,
                input.len()
            ));
        }
        let mut output = [0.0f32; FRAME_SIZE];
        let vad = self.state.process_frame(&mut output, input);
        Ok((output.to_vec(), vad))
    }

    pub fn frame_size() -> usize {
        FRAME_SIZE
    }
}

impl Default for RNNoiseProcessor {
    fn default() -> Self {
        Self::new().expect("RNNoise init")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_processor_creation() {
        let proc = RNNoiseProcessor::new();
        assert!(proc.is_ok());
    }

    #[test]
    fn test_process_silence() {
        let mut proc = RNNoiseProcessor::new().unwrap();
        let input = vec![0.0f32; FRAME_SIZE];
        let result = proc.process_frame(&input);
        assert!(result.is_ok());
        let (output, vad) = result.unwrap();
        assert_eq!(output.len(), FRAME_SIZE);
        assert!((0.0..=1.0).contains(&vad));
    }

    #[test]
    fn test_invalid_frame_size() {
        let mut proc = RNNoiseProcessor::new().unwrap();
        let input = vec![0.0f32; 100];
        let result = proc.process_frame(&input);
        assert!(result.is_err());
    }

    /// Noise-cancelling quality: sustained white noise (wind/engine-like,
    /// no voice) must come out attenuated and classified as non-voice.
    #[test]
    fn test_noise_attenuation() {
        let mut proc = RNNoiseProcessor::new().unwrap();

        // Deterministic pseudo-noise, roughly white, scaled to i16 range
        // (nnnoiseless expects i16-scaled f32 samples).
        let mut seed = 0x12345678u32;
        let mut rand_sample = move || {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            ((seed >> 16) as i16 as f32) * 0.25
        };

        let mut in_energy = 0.0f64;
        let mut out_energy = 0.0f64;
        // Let the RNN converge over a second of audio.
        for _ in 0..100 {
            let frame: Vec<f32> = (0..FRAME_SIZE).map(|_| rand_sample()).collect();
            let (out, _vad) = proc.process_frame(&frame).unwrap();
            in_energy += frame.iter().map(|s| (*s as f64).powi(2)).sum::<f64>();
            out_energy += out.iter().map(|s| (*s as f64).powi(2)).sum::<f64>();
        }

        assert!(
            out_energy < in_energy * 0.9,
            "RNNoise did not attenuate steady noise (in={}, out={})",
            in_energy,
            out_energy
        );
    }
}

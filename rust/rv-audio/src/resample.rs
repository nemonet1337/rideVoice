use std::f64::consts::PI;

/// Number of FIR taps for the anti-aliasing / anti-imaging low-pass.
const TAPS: usize = 63;
/// 48k <-> 16k is an exact 3:1 ratio.
const RATIO: usize = 3;

/// 3:1 resampler with a windowed-sinc low-pass.
///
/// Plain linear interpolation (the previous implementation) folds every
/// component above 8 kHz back into the voice band when downsampling;
/// the FIR low-pass removes them first.
pub struct Resampler {
    taps: Vec<f32>,
}

impl Default for Resampler {
    fn default() -> Self {
        Self::new()
    }
}

impl Resampler {
    pub fn new() -> Self {
        // Windowed-sinc low-pass, cutoff ~6.8 kHz at 48 kHz sample rate
        // (safely below the 8 kHz Nyquist of the 16 kHz stream).
        let cutoff = 6800.0 / 48000.0;
        let mid = (TAPS / 2) as isize;
        let mut taps = Vec::with_capacity(TAPS);
        let mut sum = 0.0f64;
        for i in 0..TAPS as isize {
            let n = (i - mid) as f64;
            let sinc = if n == 0.0 {
                2.0 * cutoff
            } else {
                (2.0 * PI * cutoff * n).sin() / (PI * n)
            };
            // Hamming window.
            let w = 0.54 - 0.46 * (2.0 * PI * i as f64 / (TAPS - 1) as f64).cos();
            let t = sinc * w;
            sum += t;
            taps.push(t as f32);
        }
        // Normalise for unity DC gain.
        for t in &mut taps {
            *t /= sum as f32;
        }
        Self { taps }
    }

    fn lowpass_at(&self, input: &[f32], center: isize) -> f32 {
        let mid = (TAPS / 2) as isize;
        let mut acc = 0.0f32;
        for (k, tap) in self.taps.iter().enumerate() {
            let idx = center + mid - k as isize;
            if idx >= 0 {
                if let Some(s) = input.get(idx as usize) {
                    acc += tap * s;
                }
            }
        }
        acc
    }

    pub fn resample_48k_to_16k(&self, input: &[f32]) -> Result<Vec<f32>, String> {
        let output_len = input.len() / RATIO;
        let mut output = Vec::with_capacity(output_len);
        for i in 0..output_len {
            output.push(self.lowpass_at(input, (i * RATIO) as isize));
        }
        Ok(output)
    }

    pub fn resample_16k_to_48k(&self, input: &[f32]) -> Result<Vec<f32>, String> {
        // Zero-stuff then low-pass to suppress spectral images; gain of
        // RATIO compensates the stuffed zeros.
        let stuffed_len = input.len() * RATIO;
        let mut stuffed = vec![0.0f32; stuffed_len];
        for (i, s) in input.iter().enumerate() {
            stuffed[i * RATIO] = *s;
        }
        let mut output = Vec::with_capacity(stuffed_len);
        for i in 0..stuffed_len {
            output.push(self.lowpass_at(&stuffed, i as isize) * RATIO as f32);
        }
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI as PI32;

    fn sine(freq: f32, sample_rate: f32, len: usize) -> Vec<f32> {
        (0..len)
            .map(|i| (i as f32 / sample_rate * freq * 2.0 * PI32).sin())
            .collect()
    }

    fn rms(signal: &[f32]) -> f32 {
        (signal.iter().map(|s| s * s).sum::<f32>() / signal.len() as f32).sqrt()
    }

    #[test]
    fn test_resampler_creation() {
        let _resampler = Resampler::new();
    }

    #[test]
    fn test_downsample_length() {
        let resampler = Resampler::new();
        let input = vec![0.0f32; 480];
        let output = resampler.resample_48k_to_16k(&input).unwrap();
        assert_eq!(output.len(), 160);
    }

    #[test]
    fn test_upsample_length() {
        let resampler = Resampler::new();
        let input = vec![0.0f32; 160];
        let output = resampler.resample_16k_to_48k(&input).unwrap();
        assert_eq!(output.len(), 480);
    }

    /// Communication quality: a 1 kHz voice-band tone must pass through the
    /// downsampler with its level essentially intact.
    #[test]
    fn test_downsample_preserves_voice_band() {
        let resampler = Resampler::new();
        let input = sine(1000.0, 48000.0, 4800);
        let output = resampler.resample_48k_to_16k(&input).unwrap();

        // Ignore filter edge transients.
        let in_rms = rms(&input[480..input.len() - 480]);
        let out_rms = rms(&output[160..output.len() - 160]);
        let ratio = out_rms / in_rms;
        assert!(
            (0.85..=1.15).contains(&ratio),
            "1 kHz tone level changed by factor {}",
            ratio
        );
    }

    /// Anti-aliasing: a 20 kHz component (above the 8 kHz target Nyquist)
    /// must be strongly attenuated instead of folding into the voice band.
    #[test]
    fn test_downsample_rejects_aliasing() {
        let resampler = Resampler::new();
        let input = sine(20000.0, 48000.0, 4800);
        let output = resampler.resample_48k_to_16k(&input).unwrap();

        let in_rms = rms(&input);
        let out_rms = rms(&output[160..output.len() - 160]);
        assert!(
            out_rms < in_rms * 0.1,
            "20 kHz leaked through the anti-alias filter: rms {} vs {}",
            out_rms,
            in_rms
        );
    }

    /// Round trip 16k -> 48k -> 16k should preserve a voice-band tone.
    #[test]
    fn test_roundtrip_preserves_tone() {
        let resampler = Resampler::new();
        let input = sine(1000.0, 16000.0, 1600);
        let up = resampler.resample_16k_to_48k(&input).unwrap();
        let down = resampler.resample_48k_to_16k(&up).unwrap();

        let in_rms = rms(&input[160..input.len() - 160]);
        let out_rms = rms(&down[160..down.len() - 160]);
        let ratio = out_rms / in_rms;
        assert!(
            (0.8..=1.2).contains(&ratio),
            "roundtrip level changed by factor {}",
            ratio
        );
    }
}

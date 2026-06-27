pub struct Resampler;

impl Resampler {
    pub fn new() -> Self {
        Self
    }

    pub fn resample_48k_to_16k(&self, input: &[f32]) -> Result<Vec<f32>, String> {
        let ratio = 16000.0 / 48000.0;
        let output_len = (input.len() as f64 * ratio) as usize;
        let mut output = Vec::with_capacity(output_len);

        for i in 0..output_len {
            let src_index = (i as f64 / ratio) as usize;
            let fraction = (i as f64 / ratio) - src_index as f64;

            let s0 = input.get(src_index).copied().unwrap_or(0.0);
            let s1 = input.get(src_index + 1).copied().unwrap_or(s0);

            output.push(s0 + (s1 - s0) * fraction as f32);
        }

        Ok(output)
    }

    pub fn resample_16k_to_48k(&self, input: &[f32]) -> Result<Vec<f32>, String> {
        let ratio = 48000.0 / 16000.0;
        let output_len = (input.len() as f64 * ratio) as usize;
        let mut output = Vec::with_capacity(output_len);

        for i in 0..output_len {
            let src_index = (i as f64 / ratio) as usize;
            let fraction = (i as f64 / ratio) - src_index as f64;

            let s0 = input.get(src_index).copied().unwrap_or(0.0);
            let s1 = input.get(src_index + 1).copied().unwrap_or(s0);

            output.push(s0 + (s1 - s0) * fraction as f32);
        }

        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}

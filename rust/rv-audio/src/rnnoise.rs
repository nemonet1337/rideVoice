use nnnoiseless::DenoiseState;

const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;

pub struct RNNoiseProcessor {
    state: DenoiseState<'static>,
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
        assert!(vad >= 0.0 && vad <= 1.0);
    }

    #[test]
    fn test_invalid_frame_size() {
        let mut proc = RNNoiseProcessor::new().unwrap();
        let input = vec![0.0f32; 100];
        let result = proc.process_frame(&input);
        assert!(result.is_err());
    }
}

pub mod resample;

#[cfg(feature = "opus-codec")]
pub mod opus_codec;
#[cfg(feature = "opus-codec")]
pub use opus_codec::OpusCodec;

#[cfg(feature = "rnnoise-denoise")]
pub mod rnnoise;
#[cfg(feature = "rnnoise-denoise")]
pub use rnnoise::RNNoiseProcessor;

#[cfg(all(feature = "opus-codec", feature = "rnnoise-denoise"))]
pub mod pipeline;
#[cfg(all(feature = "opus-codec", feature = "rnnoise-denoise"))]
pub use pipeline::{CapturePipeline, EncodedFrame, PlaybackPipeline};

pub use resample::Resampler;

use aes_gcm::{
    aead::{Aead, KeyInit, OsRng, Payload},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Zeroize, ZeroizeOnDrop)]
pub struct Sealer {
    key: [u8; 32],
}

impl Sealer {
    pub fn new(key: &[u8; 32]) -> Self {
        Self { key: *key }
    }

    pub fn seal(&self, plaintext: &[u8], nonce: &[u8; 12]) -> Result<Vec<u8>, String> {
        self.seal_with_aad(plaintext, nonce, &[])
    }

    pub fn open(&self, ciphertext: &[u8], nonce: &[u8; 12]) -> Result<Vec<u8>, String> {
        self.open_with_aad(ciphertext, nonce, &[])
    }

    /// Seal with associated data. The mesh layer passes the packet header
    /// (src_id, dst_id, seq_num, epoch) as AAD so a relay cannot re-attribute
    /// or re-order a voice frame without failing authentication.
    pub fn seal_with_aad(
        &self,
        plaintext: &[u8],
        nonce: &[u8; 12],
        aad: &[u8],
    ) -> Result<Vec<u8>, String> {
        let cipher =
            Aes256Gcm::new_from_slice(&self.key).map_err(|e| format!("cipher init: {}", e))?;
        let n = Nonce::from_slice(nonce);
        cipher
            .encrypt(
                n,
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|e| format!("encrypt: {}", e))
    }

    pub fn open_with_aad(
        &self,
        ciphertext: &[u8],
        nonce: &[u8; 12],
        aad: &[u8],
    ) -> Result<Vec<u8>, String> {
        let cipher =
            Aes256Gcm::new_from_slice(&self.key).map_err(|e| format!("cipher init: {}", e))?;
        let n = Nonce::from_slice(nonce);
        cipher
            .decrypt(
                n,
                Payload {
                    msg: ciphertext,
                    aad,
                },
            )
            .map_err(|e| format!("decrypt: {}", e))
    }

    pub fn generate_nonce() -> [u8; 12] {
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        nonce
    }
}

/// Deterministic 96-bit nonce sequence: 4-byte sender ID || 8-byte counter.
///
/// Voice streams push many frames per second under one group key; random
/// nonces would eventually risk collision (birthday bound at ~2^32 messages).
/// Distinct sender IDs partition the nonce space so every group member can
/// seal with the same GK without coordination.
pub struct NonceSequence {
    sender_id: u32,
    counter: u64,
}

impl NonceSequence {
    pub fn new(sender_id: u32) -> Self {
        Self {
            sender_id,
            counter: 0,
        }
    }

    /// Resume a sequence at a known counter (e.g. after process restart the
    /// caller must persist and skip ahead, never reuse).
    pub fn with_counter(sender_id: u32, counter: u64) -> Self {
        Self { sender_id, counter }
    }

    pub fn counter(&self) -> u64 {
        self.counter
    }

    /// Returns the next nonce, or an error once the counter space is
    /// exhausted (the key must be rotated long before this).
    pub fn next_nonce(&mut self) -> Result<[u8; 12], String> {
        if self.counter == u64::MAX {
            return Err("nonce counter exhausted; rotate the group key".to_string());
        }
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&self.sender_id.to_be_bytes());
        nonce[4..].copy_from_slice(&self.counter.to_be_bytes());
        self.counter += 1;
        Ok(nonce)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        key
    }

    #[test]
    fn test_seal_open_roundtrip() {
        let key = test_key();
        let sealer = Sealer::new(&key);
        let plaintext = b"hello ridevoice mobile audio";
        let nonce = Sealer::generate_nonce();

        let ciphertext = sealer.seal(plaintext, &nonce).unwrap();
        assert_ne!(ciphertext, plaintext);

        let decrypted = sealer.open(&ciphertext, &nonce).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_tamper_detection() {
        let key = test_key();
        let sealer = Sealer::new(&key);
        let nonce = Sealer::generate_nonce();

        let mut ciphertext = sealer.seal(b"test", &nonce).unwrap();
        ciphertext[0] ^= 0x01;

        let result = sealer.open(&ciphertext, &nonce);
        assert!(result.is_err());
    }

    #[test]
    fn test_truncation_detection() {
        let key = test_key();
        let sealer = Sealer::new(&key);
        let nonce = Sealer::generate_nonce();

        let ciphertext = sealer
            .seal(b"a longer voice frame payload", &nonce)
            .unwrap();
        let truncated = &ciphertext[..ciphertext.len() - 1];
        assert!(sealer.open(truncated, &nonce).is_err());
    }

    #[test]
    fn test_wrong_key_fails() {
        let sealer = Sealer::new(&test_key());
        let other = Sealer::new(&test_key());
        let nonce = Sealer::generate_nonce();
        let ciphertext = sealer.seal(b"secret", &nonce).unwrap();
        assert!(other.open(&ciphertext, &nonce).is_err());
    }

    #[test]
    fn test_wrong_nonce_fails() {
        let key = test_key();
        let sealer = Sealer::new(&key);
        let nonce = Sealer::generate_nonce();
        let ciphertext = sealer.seal(b"secret", &nonce).unwrap();
        let other_nonce = Sealer::generate_nonce();
        assert!(sealer.open(&ciphertext, &other_nonce).is_err());
    }

    #[test]
    fn test_aad_binding() {
        let key = test_key();
        let sealer = Sealer::new(&key);
        let nonce = Sealer::generate_nonce();
        let aad = b"src=1;dst=2;seq=42;epoch=0";

        let ciphertext = sealer.seal_with_aad(b"frame", &nonce, aad).unwrap();

        // Correct AAD opens.
        assert_eq!(
            sealer.open_with_aad(&ciphertext, &nonce, aad).unwrap(),
            b"frame"
        );
        // Modified AAD (re-attributed header) must fail.
        assert!(sealer
            .open_with_aad(&ciphertext, &nonce, b"src=9;dst=2;seq=42;epoch=0")
            .is_err());
        // Missing AAD must fail.
        assert!(sealer.open(&ciphertext, &nonce).is_err());
    }

    #[test]
    fn test_nonce_uniqueness() {
        let n1 = Sealer::generate_nonce();
        let n2 = Sealer::generate_nonce();
        assert_ne!(n1, n2);
    }

    #[test]
    fn test_nonce_sequence_monotonic_and_disjoint() {
        let mut seq_a = NonceSequence::new(1);
        let mut seq_b = NonceSequence::new(2);

        let mut seen = std::collections::HashSet::new();
        for _ in 0..1000 {
            assert!(seen.insert(seq_a.next_nonce().unwrap()));
            assert!(seen.insert(seq_b.next_nonce().unwrap()));
        }
        assert_eq!(seq_a.counter(), 1000);
    }

    #[test]
    fn test_nonce_sequence_exhaustion() {
        let mut seq = NonceSequence::with_counter(1, u64::MAX);
        assert!(seq.next_nonce().is_err());
    }

    /// AES-256-GCM known-answer tests (McGrew & Viega GCM spec, test cases
    /// 13 and 14): guards against a broken or misconfigured cipher backend.
    #[test]
    fn test_aes256gcm_known_answer_empty() {
        let sealer = Sealer::new(&[0u8; 32]);
        let nonce = [0u8; 12];
        let out = sealer.seal(&[], &nonce).unwrap();
        // Empty plaintext -> ciphertext is the 16-byte tag only.
        assert_eq!(hex::encode(&out), "530f8afbc74536b9a963b4f1c4cb738b");
    }

    /// Interop vector shared with the Dart implementation
    /// (app/test/crypto_test.dart): key=0x02*32, nonce=NonceSequence(sender 7,
    /// counter 5), AAD-bound. Both sides must produce identical ciphertext.
    #[test]
    fn test_cross_language_interop_vector() {
        let sealer = Sealer::new(&[0x02u8; 32]);
        let mut seq = NonceSequence::with_counter(7, 5);
        let nonce = seq.next_nonce().unwrap();
        assert_eq!(hex::encode(nonce), "000000070000000000000005");
        let ct = sealer
            .seal_with_aad(b"ridevoice-frame", &nonce, b"src=7;seq=5;epoch=1")
            .unwrap();
        assert_eq!(
            hex::encode(&ct),
            "58ba36989a570f749eb2bf6198a52ec26a087dabd216aac4f6115398955cb9"
        );
    }

    #[test]
    fn test_aes256gcm_known_answer_block() {
        let sealer = Sealer::new(&[0u8; 32]);
        let nonce = [0u8; 12];
        let out = sealer.seal(&[0u8; 16], &nonce).unwrap();
        assert_eq!(
            hex::encode(&out),
            "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919"
        );
    }
}

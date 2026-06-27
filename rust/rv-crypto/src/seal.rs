use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use rand::RngCore;

pub struct Sealer {
    key: [u8; 32],
}

impl Sealer {
    pub fn new(key: &[u8; 32]) -> Self {
        Self { key: *key }
    }

    pub fn seal(&self, plaintext: &[u8], nonce: &[u8; 12]) -> Result<Vec<u8>, String> {
        let cipher = Aes256Gcm::new_from_slice(&self.key)
            .map_err(|e| format!("cipher init: {}", e))?;
        let n = Nonce::from_slice(nonce);
        cipher
            .encrypt(n, plaintext)
            .map_err(|e| format!("encrypt: {}", e))
    }

    pub fn open(&self, ciphertext: &[u8], nonce: &[u8; 12]) -> Result<Vec<u8>, String> {
        let cipher = Aes256Gcm::new_from_slice(&self.key)
            .map_err(|e| format!("cipher init: {}", e))?;
        let n = Nonce::from_slice(nonce);
        cipher
            .decrypt(n, ciphertext)
            .map_err(|e| format!("decrypt: {}", e))
    }

    pub fn generate_nonce() -> [u8; 12] {
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        nonce
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
    fn test_nonce_uniqueness() {
        let n1 = Sealer::generate_nonce();
        let n2 = Sealer::generate_nonce();
        assert_ne!(n1, n2);
    }
}

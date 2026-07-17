//! Flat function API intended as the flutter_rust_bridge (FRB 2.x) surface.
//!
//! FRB codegen scans plain functions with owned, FFI-friendly types
//! (`Vec<u8>`, `String`, `Result`). Keep this module free of borrowed
//! parameters and non-`Send` types.

use crate::group_key::GroupKey;
use crate::key_exchange::KeyExchange;
use crate::seal::Sealer;

fn to_array32(bytes: &[u8], what: &str) -> Result<[u8; 32], String> {
    bytes
        .try_into()
        .map_err(|_| format!("{} must be 32 bytes, got {}", what, bytes.len()))
}

fn to_nonce(bytes: &[u8]) -> Result<[u8; 12], String> {
    bytes
        .try_into()
        .map_err(|_| format!("nonce must be 12 bytes, got {}", bytes.len()))
}

pub struct FfiKeyPair {
    pub private_key: Vec<u8>,
    pub public_key: Vec<u8>,
}

pub fn generate_keypair() -> FfiKeyPair {
    let kp = KeyExchange::generate_keypair();
    FfiKeyPair {
        private_key: kp.private_key.to_vec(),
        public_key: kp.public_key.to_vec(),
    }
}

pub fn ecdh(private_key: Vec<u8>, peer_public: Vec<u8>) -> Result<Vec<u8>, String> {
    let sk = to_array32(&private_key, "private key")?;
    let pk = to_array32(&peer_public, "peer public key")?;
    Ok(KeyExchange::ecdh(&sk, &pk)?.to_vec())
}

pub fn derive_session_key(shared_secret: Vec<u8>, salt: Vec<u8>) -> Result<Vec<u8>, String> {
    let ss = to_array32(&shared_secret, "shared secret")?;
    Ok(KeyExchange::derive_session_key(&ss, &salt)?.to_vec())
}

pub fn generate_group_key() -> Vec<u8> {
    GroupKey::generate().as_bytes().to_vec()
}

pub fn seal(
    key: Vec<u8>,
    nonce: Vec<u8>,
    plaintext: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let k = to_array32(&key, "key")?;
    let n = to_nonce(&nonce)?;
    Sealer::new(&k).seal_with_aad(&plaintext, &n, &aad)
}

pub fn open(
    key: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let k = to_array32(&key, "key")?;
    let n = to_nonce(&nonce)?;
    Sealer::new(&k).open_with_aad(&ciphertext, &n, &aad)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_api_roundtrip() {
        let alice = generate_keypair();
        let bob = generate_keypair();

        let ss_a = ecdh(alice.private_key.clone(), bob.public_key.clone()).unwrap();
        let ss_b = ecdh(bob.private_key.clone(), alice.public_key.clone()).unwrap();
        assert_eq!(ss_a, ss_b);

        let sk = derive_session_key(ss_a, b"salt".to_vec()).unwrap();
        let nonce = vec![0u8; 12];
        let aad = b"header".to_vec();
        let ct = seal(sk.clone(), nonce.clone(), b"gk".to_vec(), aad.clone()).unwrap();
        assert_eq!(open(sk, nonce, ct, aad).unwrap(), b"gk");
    }

    #[test]
    fn test_api_rejects_bad_lengths() {
        assert!(ecdh(vec![0u8; 31], vec![0u8; 32]).is_err());
        assert!(derive_session_key(vec![0u8; 33], vec![]).is_err());
        assert!(seal(vec![0u8; 32], vec![0u8; 11], vec![], vec![]).is_err());
    }
}

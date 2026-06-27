use hkdf::Hkdf;
use rand::rngs::OsRng;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

pub struct KeyPair {
    pub private_key: [u8; 32],
    pub public_key: [u8; 32],
}

pub struct KeyExchange;

impl KeyExchange {
    pub fn generate_keypair() -> KeyPair {
        let secret = StaticSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        let pk_bytes = *public.as_bytes();
        let sk_bytes = secret.to_bytes();
        KeyPair {
            private_key: sk_bytes,
            public_key: pk_bytes,
        }
    }

    pub fn ecdh(private_key: &[u8; 32], peer_public: &[u8; 32]) -> Result<[u8; 32], String> {
        let sk = x25519_dalek::StaticSecret::from(*private_key);
        let pk = PublicKey::from(*peer_public);
        let shared = sk.diffie_hellman(&pk);
        Ok(*shared.as_bytes())
    }

    pub fn derive_session_key(shared_secret: &[u8; 32], salt: &[u8]) -> Result<[u8; 32], String> {
        let hkdf = Hkdf::<Sha256>::new(Some(salt), shared_secret);
        let mut okm = [0u8; 32];
        hkdf.expand(b"ridevoice-session-key", &mut okm)
            .map_err(|e| format!("HKDF expand failed: {}", e))?;
        Ok(okm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keypair_generation() {
        let kp = KeyExchange::generate_keypair();
        assert_ne!(kp.private_key, [0u8; 32]);
        assert_ne!(kp.public_key, [0u8; 32]);
    }

    #[test]
    fn test_ecdh_agreement() {
        let alice = KeyExchange::generate_keypair();
        let bob = KeyExchange::generate_keypair();

        let shared_alice = KeyExchange::ecdh(&alice.private_key, &bob.public_key).unwrap();
        let shared_bob = KeyExchange::ecdh(&bob.private_key, &alice.public_key).unwrap();

        assert_eq!(shared_alice, shared_bob);
    }

    #[test]
    fn test_derive_session_key() {
        let alice = KeyExchange::generate_keypair();
        let bob = KeyExchange::generate_keypair();
        let shared = KeyExchange::ecdh(&alice.private_key, &bob.public_key).unwrap();

        let salt = b"ridevoice-salt";
        let sk1 = KeyExchange::derive_session_key(&shared, salt).unwrap();
        let sk2 = KeyExchange::derive_session_key(&shared, salt).unwrap();
        assert_eq!(sk1, sk2);

        let sk3 = KeyExchange::derive_session_key(&shared, b"different-salt").unwrap();
        assert_ne!(sk1, sk3);
    }
}

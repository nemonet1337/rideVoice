use hkdf::Hkdf;
use rand::rngs::OsRng;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Zeroize, ZeroizeOnDrop)]
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

    pub fn public_key_from_private(private_key: &[u8; 32]) -> [u8; 32] {
        let sk = StaticSecret::from(*private_key);
        *PublicKey::from(&sk).as_bytes()
    }

    pub fn ecdh(private_key: &[u8; 32], peer_public: &[u8; 32]) -> Result<[u8; 32], String> {
        let sk = StaticSecret::from(*private_key);
        let pk = PublicKey::from(*peer_public);
        let shared = sk.diffie_hellman(&pk);
        // Reject the all-zero shared secret produced by low-order points
        // (contributory behaviour check per RFC 7748 security notes).
        let bytes = *shared.as_bytes();
        if bytes == [0u8; 32] {
            return Err("ECDH produced an all-zero shared secret (low-order peer key)".into());
        }
        Ok(bytes)
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

    /// RFC 7748 §6.1 X25519 Diffie-Hellman test vector (Alice / Bob).
    #[test]
    fn test_x25519_rfc7748_vector() {
        let alice_sk: [u8; 32] =
            hex::decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
                .unwrap()
                .try_into()
                .unwrap();
        let alice_pk_expected =
            hex::decode("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
                .unwrap();
        let bob_sk: [u8; 32] =
            hex::decode("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
                .unwrap()
                .try_into()
                .unwrap();
        let bob_pk: [u8; 32] =
            hex::decode("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
                .unwrap()
                .try_into()
                .unwrap();
        let shared_expected =
            hex::decode("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
                .unwrap();

        assert_eq!(
            KeyExchange::public_key_from_private(&alice_sk).to_vec(),
            alice_pk_expected
        );
        let shared = KeyExchange::ecdh(&alice_sk, &bob_pk).unwrap();
        assert_eq!(shared.to_vec(), shared_expected);

        let shared_rev =
            KeyExchange::ecdh(&bob_sk, &KeyExchange::public_key_from_private(&alice_sk)).unwrap();
        assert_eq!(shared, shared_rev);
    }

    #[test]
    fn test_ecdh_rejects_low_order_point() {
        let kp = KeyExchange::generate_keypair();
        // The identity element (all zeros) is a low-order point; the shared
        // secret it yields is all zeros and must be rejected.
        let low_order = [0u8; 32];
        assert!(KeyExchange::ecdh(&kp.private_key, &low_order).is_err());
    }

    /// Fixed vector pinning the session-key derivation so the Dart
    /// implementation can assert byte-for-byte compatibility.
    /// (See app/test/crypto_test.dart.)
    #[test]
    fn test_derive_session_key_cross_language_vector() {
        let shared = [0x01u8; 32];
        let sk = KeyExchange::derive_session_key(&shared, b"ridevoice-salt").unwrap();
        assert_eq!(
            hex::encode(sk),
            "c20c672dcdd673cb2d6f47aceaa9e796abb40c8c593671c6109e8af622f7d736",
            "HKDF(salt=\"ridevoice-salt\", ikm=0x01*32, info=\"ridevoice-session-key\") changed"
        );
    }
}

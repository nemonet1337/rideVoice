use rand::RngCore;
use rand::rngs::OsRng;

pub struct GroupKey {
    key: [u8; 32],
}

impl GroupKey {
    pub fn generate() -> Self {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        Self { key }
    }

    pub fn from_bytes(bytes: &[u8; 32]) -> Self {
        Self { key: *bytes }
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.key
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_unique() {
        let gk1 = GroupKey::generate();
        let gk2 = GroupKey::generate();
        assert_ne!(gk1.as_bytes(), gk2.as_bytes());
    }

    #[test]
    fn test_from_bytes_roundtrip() {
        let gk = GroupKey::generate();
        let bytes = gk.as_bytes();
        let gk2 = GroupKey::from_bytes(bytes);
        assert_eq!(gk.as_bytes(), gk2.as_bytes());
    }
}

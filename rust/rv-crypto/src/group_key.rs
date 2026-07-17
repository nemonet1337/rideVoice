use rand::rngs::OsRng;
use rand::RngCore;
use zeroize::{Zeroize, ZeroizeOnDrop};

/// Group Key (GK) with an epoch counter.
///
/// The epoch increments on every rotation (member leave, 30-min periodic,
/// or manual host rotation) so receivers can tell which generation of the
/// key a packet was sealed with during the rotation grace period.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct GroupKey {
    key: [u8; 32],
    epoch: u32,
}

impl GroupKey {
    pub fn generate() -> Self {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        Self { key, epoch: 0 }
    }

    pub fn from_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            key: *bytes,
            epoch: 0,
        }
    }

    pub fn from_parts(bytes: &[u8; 32], epoch: u32) -> Self {
        Self { key: *bytes, epoch }
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.key
    }

    pub fn epoch(&self) -> u32 {
        self.epoch
    }

    /// Derive the next generation: fresh random key material, epoch + 1.
    pub fn rotate(&self) -> Self {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        Self {
            key,
            epoch: self.epoch + 1,
        }
    }
}

/// Holds the current GK plus the immediately previous one.
///
/// Per the design doc, rotation is not atomic across the mesh: while the new
/// GK propagates, packets sealed with the previous key must still open.
/// Anything older than one generation is rejected.
pub struct KeyRing {
    current: GroupKey,
    previous: Option<GroupKey>,
}

impl KeyRing {
    pub fn new(initial: GroupKey) -> Self {
        Self {
            current: initial,
            previous: None,
        }
    }

    pub fn current(&self) -> &GroupKey {
        &self.current
    }

    /// Rotate locally (host side): current becomes previous, a fresh key
    /// becomes current. Returns the new current key for distribution.
    pub fn rotate(&mut self) -> &GroupKey {
        let next = self.current.rotate();
        self.previous = Some(std::mem::replace(&mut self.current, next));
        &self.current
    }

    /// Install a GK received from the cluster head. Only keys with a newer
    /// epoch are accepted; the old current key is retained as previous.
    pub fn install(&mut self, gk: GroupKey) -> Result<(), String> {
        if gk.epoch() <= self.current.epoch() {
            return Err(format!(
                "stale group key: epoch {} <= current {}",
                gk.epoch(),
                self.current.epoch()
            ));
        }
        self.previous = Some(std::mem::replace(&mut self.current, gk));
        Ok(())
    }

    /// Look up key material for a packet's epoch. Only the current and the
    /// immediately previous generation are usable.
    pub fn key_for_epoch(&self, epoch: u32) -> Option<&GroupKey> {
        if epoch == self.current.epoch() {
            return Some(&self.current);
        }
        match &self.previous {
            Some(prev) if prev.epoch() == epoch => Some(prev),
            _ => None,
        }
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
        let bytes = *gk.as_bytes();
        let gk2 = GroupKey::from_bytes(&bytes);
        assert_eq!(gk.as_bytes(), gk2.as_bytes());
        assert_eq!(gk2.epoch(), 0);
    }

    #[test]
    fn test_rotate_increments_epoch_and_changes_key() {
        let gk = GroupKey::generate();
        let next = gk.rotate();
        assert_eq!(next.epoch(), gk.epoch() + 1);
        assert_ne!(next.as_bytes(), gk.as_bytes());
    }

    #[test]
    fn test_keyring_rotation_grace_period() {
        let initial = GroupKey::generate();
        let epoch0_key = *initial.as_bytes();
        let mut ring = KeyRing::new(initial);

        ring.rotate();
        assert_eq!(ring.current().epoch(), 1);

        // Previous generation still resolvable during grace period.
        let prev = ring.key_for_epoch(0).expect("previous key available");
        assert_eq!(prev.as_bytes(), &epoch0_key);

        // Two generations back must be rejected.
        ring.rotate();
        assert_eq!(ring.current().epoch(), 2);
        assert!(ring.key_for_epoch(0).is_none());
        assert!(ring.key_for_epoch(1).is_some());
        assert!(ring.key_for_epoch(3).is_none());
    }

    #[test]
    fn test_keyring_install_rejects_stale_epoch() {
        let mut ring = KeyRing::new(GroupKey::generate());
        ring.rotate(); // epoch 1

        let stale = GroupKey::from_parts(&[7u8; 32], 0);
        assert!(ring.install(stale).is_err());

        let same_epoch = GroupKey::from_parts(&[7u8; 32], 1);
        assert!(ring.install(same_epoch).is_err());

        let newer = GroupKey::from_parts(&[7u8; 32], 2);
        assert!(ring.install(newer).is_ok());
        assert_eq!(ring.current().epoch(), 2);
        assert!(ring.key_for_epoch(1).is_some());
    }
}

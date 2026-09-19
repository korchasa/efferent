"""Opening a sealed day, including the envelope the archive still holds.

Version 2 is RFC 9180 HPKE and lives in the wire module, which is also the
script the setup guide hands an agent. Version 1 predates that interoperability
work: the phone replaces its days with version 2 as it re-reads them, and until
the last one has been replaced a reader that refused version 1 would report a
day as unreadable rather than old. Nothing writes version 1 any more.
"""

import os

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

import efferent_hpke as wire

LEGACY_VERSION = 1
EPHEMERAL_BYTES = 32
NONCE_BYTES = 12
LEGACY_HEADER = 1 + EPHEMERAL_BYTES + NONCE_BYTES
LEGACY_INFO = b"efferent/v1 sealed box"


def associated_data(bucket: str, day: str) -> bytes:
    """Bucket and day stay bound to the ciphertext across both envelopes."""
    return f"efferent/v1\n{bucket}\n{day}".encode()


def open_legacy(private_raw: bytes, public_raw: bytes, blob: bytes, aad: bytes) -> bytes:
    if len(blob) <= LEGACY_HEADER:
        raise ValueError("sealed v1 blob is too short")
    ephemeral_public = blob[1 : 1 + EPHEMERAL_BYTES]
    nonce = blob[1 + EPHEMERAL_BYTES : LEGACY_HEADER]
    shared = X25519PrivateKey.from_private_bytes(private_raw).exchange(
        X25519PublicKey.from_public_bytes(ephemeral_public)
    )
    key = _legacy_key(shared, ephemeral_public, public_raw)
    return AESGCM(key).decrypt(nonce, blob[LEGACY_HEADER:], aad)


def _legacy_key(shared: bytes, ephemeral_public: bytes, public_raw: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=ephemeral_public + public_raw,
        info=LEGACY_INFO,
    ).derive(shared)


def open_sealed(private_raw: bytes, public_raw: bytes, blob: bytes, aad: bytes) -> bytes:
    """Whichever envelope the day is in, as plaintext."""
    if not blob:
        raise ValueError("sealed blob has no version byte")
    if blob[0] == LEGACY_VERSION:
        return open_legacy(private_raw, public_raw, blob, aad)
    if blob[0] != wire.SEALED_VERSION:
        raise ValueError(f"unsupported sealed version {blob[0]}")
    return wire.hpke_open(private_raw, wire.INFO, aad, blob[1:])


def seal_legacy(public_raw: bytes, plaintext: bytes, aad: bytes) -> bytes:
    """Test-only producer, so the compatibility decoder above is proved live
    rather than assumed. Nothing ships version 1 any more."""
    ephemeral = X25519PrivateKey.generate()
    ephemeral_public = ephemeral.public_key().public_bytes(*wire.RAW)
    key = _legacy_key(
        ephemeral.exchange(X25519PublicKey.from_public_bytes(public_raw)),
        ephemeral_public,
        public_raw,
    )
    nonce = os.urandom(NONCE_BYTES)
    return (
        bytes([LEGACY_VERSION])
        + ephemeral_public
        + nonce
        + AESGCM(key).encrypt(nonce, plaintext, aad)
    )

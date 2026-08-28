/** The immutable local-only RFC 9180 reader embedded in connect prompt v2. */
export const PYTHON_HPKE_REFERENCE = String.raw`#!/usr/bin/env python3
import argparse
import base64
from datetime import date
import hashlib
import hmac
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit, urlunsplit
from urllib.request import urlopen
import zlib

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from pyhpke import AEADId, CipherSuite, KDFId, KEMId

INFO = b"efferent/v2 hpke"
SEALED_VERSION = 2
ENC_BYTES = 32
SUITE = CipherSuite.new(
    KEMId.DHKEM_X25519_HKDF_SHA256,
    KDFId.HKDF_SHA256,
    AEADId.CHACHA20_POLY1305,
)


def base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def field(handoff: str, name: str) -> str:
    match = re.search(rf"(?:^|\n){re.escape(name)}:\s*\r?\n([^\r\n]+)", handoff)
    if not match:
        raise ValueError(f"the handoff has no {name} field")
    return match.group(1).strip()


def connection(handoff: str) -> tuple[str, str, bytes]:
    mcp = urlsplit(field(handoff, "MCP"))
    if mcp.scheme not in ("http", "https") or mcp.query or mcp.fragment:
        raise ValueError("MCP must be an HTTP URL without a query or fragment")
    match = re.fullmatch(r"(.*)/mcp/b/([a-z2-7]{26})", mcp.path)
    if not match:
        raise ValueError("MCP must end in /mcp/b/<bucket-id>")
    prefix, bucket = match.groups()

    key_parts = field(handoff, "Reading key").split(".")
    if len(key_parts) != 3 or key_parts[0] != "efferent-reading-v1":
        raise ValueError("the reading key is not an Efferent reading key version 1")
    private_raw, public_raw = map(base64url, key_parts[1:])
    if len(private_raw) != 32 or len(public_raw) != 32:
        raise ValueError("the reading key must contain two 32-byte X25519 keys")

    actual_public = X25519PrivateKey.from_private_bytes(private_raw).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    if not hmac.compare_digest(actual_public, public_raw):
        raise ValueError("the private and public halves of the reading key do not match")

    derived = base64.b32encode(hashlib.sha256(public_raw).digest()).decode().lower()[:26]
    if derived != bucket:
        raise ValueError("the reading key belongs to a different bucket than the MCP URL")

    endpoint = urlunsplit((mcp.scheme, mcp.netloc, prefix, "", "")).rstrip("/")
    return endpoint, bucket, private_raw


def read_day(handoff_path: Path, day: str) -> bytes:
    if os.name == "posix" and handoff_path.stat().st_mode & 0o077:
        raise PermissionError("the handoff file must be readable only by its owner: chmod 600")
    endpoint, bucket, private_raw = connection(handoff_path.read_text())
    aad = f"efferent/v1\n{bucket}\n{day}".encode()

    # This request contains only the bucket and date. The reading key remains local.
    with urlopen(f"{endpoint}/b/{bucket}/d/{day}", timeout=30) as response:
        blob = response.read(16 * 1024 * 1024 + 1)
    if len(blob) > 16 * 1024 * 1024:
        raise ValueError("the sealed day exceeds the 16 MiB protocol limit")
    if not blob or blob[0] != SEALED_VERSION:
        version = blob[0] if blob else "missing"
        raise ValueError(f"expected HPKE sealed version 2, got {version}")

    recipient = SUITE.kem.deserialize_private_key(private_raw)
    context = SUITE.create_recipient_context(
        blob[1 : 1 + ENC_BYTES], recipient, info=INFO
    )
    compressed = context.open(blob[1 + ENC_BYTES :], aad=aad)
    return zlib.decompress(compressed, -zlib.MAX_WBITS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handoff", required=True, type=Path)
    parser.add_argument("--day", required=True, help="YYYY-MM-DD")
    args = parser.parse_args()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.day):
        parser.error("--day must be YYYY-MM-DD")
    try:
        date.fromisoformat(args.day)
    except ValueError:
        parser.error("--day must be YYYY-MM-DD")
    sys.stdout.buffer.write(read_day(args.handoff, args.day))


if __name__ == "__main__":
    main()
`;

/**
 * The local-only reader embedded in connect prompt v3.
 *
 * Version 2 is immutable, so the Cloudflare-compatible request headers are a
 * versioned source transformation rather than an in-place edit of its prompt.
 */
export const PYTHON_HPKE_REFERENCE_V3 = PYTHON_HPKE_REFERENCE
  .replace(
    "from urllib.request import urlopen",
    "from urllib.request import Request, urlopen",
  )
  .replace(
    '    with urlopen(f"{endpoint}/b/{bucket}/d/{day}", timeout=30) as response:',
    String.raw`    request = Request(
        f"{endpoint}/b/{bucket}/d/{day}",
        headers={
            "Accept": "application/octet-stream",
            "User-Agent": "efferent-local-reader/1.0",
        },
    )
    with urlopen(request, timeout=30) as response:`,
  );

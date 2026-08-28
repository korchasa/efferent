# Connection architecture

Status: the phone-first connection with RFC 9180 HPKE is live in TestFlight build 10. The current
source prepares build 11 and `/prompts/connect/v3`, whose embedded Python reference is the complete
local connection path. The immutable `/v1` and `/v2` prompts remain available for handoffs already
shared. Build 10 introduced the HPKE migration described under [Migration state](#migration-state).

The first real build-8 handoff was verified end to end on 2026-08-27: the local importer matched the
reading key to the phone-created bucket, wrote owner-only files, and the local MCP answered
`health_overview`. The new archive was still empty at that check, pending the phone's Health export.
That check exposed one migration defect: build 8 left the old archive's fingerprints in the phone
ledger, so the empty new archive looked complete. The fix shipped in TestFlight build 9: changing
the archive resets only archive-specific delivery state, requeues every known day and preserves the
HealthKit anchors and sample-to-day index needed to rebuild the archive locally. The repair was
verified on the phone after installing build 9: the new archive reached 3,912 days covering
2015-12-12 through 2026-08-27, a fresh handoff imported locally without exposing its reading key,
and `health_overview` decrypted the archive locally. The final local mirror matched all 3,912 days.

## The boundary

The phone creates the archive. An agent arrives with no prior knowledge of Efferent and receives a
small connection handoff from the phone. Cloudflare stores and transports ciphertext; it never
receives the reading private key and never decrypts or analyses a day. Decryption and every answer
about Health data happen on the agent's own machine.

This is the whole flow:

```text
phone -> sealed days -> R2
agent -> remote MCP -> listing and sealed days
agent + local reading key -> decryption and analysis on the agent's machine
```

There is no invitation protocol, pairing session, rendezvous object or server-side copy of the
reading key.

## What the phone creates

On first setup the phone:

1. creates the X25519 reading key pair;
2. derives the bucket id from the reading public key, as the wire protocol already does;
3. creates the logical bucket on the service and claims it with its separate signing key;
4. keeps the public half for sealing days and keeps the private half in the Keychain for connection
   handoff;
5. starts sending sealed days without waiting for an agent.

The signing key and reading key stay separate. Possession of the reading private key grants read
access, not the ability to forge an upload.

## What the phone hands to an agent

The phone shares four fields as text:

```text
Instruction:
Connect Efferent. Keep the reading key local and never pass it to a remote tool.

Prompt:
https://<public-host>/prompts/connect/v3

MCP:
https://<mcp-host>/mcp/b/<bucket-id>

Reading key:
<private-reading-key>
```

The exact public hosts are deployment configuration, not protocol constants.

The concrete key value is
`efferent-reading-v1.<raw-private-base64url>.<raw-public-base64url>`. It remains one field. The public
half lets the local Python reference derive the bucket and reject a handoff whose key and MCP URL do
not belong together; the private half is the secret.

The bucket id belongs in the MCP URL; it is an address, not a decryption secret. The reading key is
a separate field. It must never appear in a URL, an HTTP header, a remote MCP tool argument, a log,
or server-side storage. The agent keeps the handoff in an owner-only local file and does not repeat
the key in output.

The prompt URL is public, immutable and versioned. Version 3 contains a runnable Python reference
for the HPKE envelope and is sufficient by itself: it does not require a repository checkout, Deno,
a local MCP server or a gateway restart. It contains no user-specific bucket, key or archive data.
Versions 1 and 2 remain byte-for-byte available for handoffs already shared; changing an immutable
prompt in place would leave different agents following different cached instructions under the same
URL.

## Responsibilities

### Phone

- Own archive creation and key generation.
- Encrypt every day to its own reading public key.
- Sign uploads with the independent device signing key.
- Produce the connection handoff whenever the owner chooses to connect an agent.

### Cloudflare service and remote MCP server

- Address an archive by bucket id.
- List sealed days and return sealed objects or links to them.
- Keep the existing upload signature boundary.
- Never accept a reading key through configuration, authorization, prompts or tool arguments.
- Never return plaintext or answer a question about the contents of a day.

The remote MCP server is discovery and ciphertext transport. It is deliberately unable to perform
the health analysis tools.

The implemented remote tools are `archive_status`, `list_sealed_days` and `get_sealed_day`. The last
returns a resource link to `application/octet-stream`, not the bytes decoded into another shape.
The current public prompt is served at `/prompts/connect/v3` with an immutable one-year cache
policy, beside the retained `/v1` and `/v2` prompts. The phone claims an empty archive with a signed
`PUT /b/<bucket-id>` before any Health day exists.

### Agent machine

- Read the public connection prompt.
- Store the complete handoff in an owner-only local file.
- Connect to the keyless remote MCP endpoint using the bucket id only.
- Use the remote tools to select dates.
- Save and run the Python reference embedded in the prompt to fetch and decrypt each selected day.
- Analyse the resulting NDJSON locally and never send plaintext to a remote tool.

An agent that cannot execute code locally cannot read an Efferent archive under this security model.
That is a capability boundary, not a reason to give the key to Cloudflare.

## Sealed format

New writes use RFC 9180 base-mode HPKE with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
ChaCha20-Poly1305. A stored day is `[0x02][32-byte encapsulated key][ciphertext and 16-byte tag]`.
The HPKE info is `efferent/v2 hpke`; the authenticated data remains
`efferent/v1\n<bucket>\n<day>` so the same bucket and date binding holds across the migration. The
payload inside is raw-deflate-compressed NDJSON.

CryptoKit implements the sender on iOS. The optional TypeScript development reader uses `hpke-js`;
the exact Python source embedded in prompt v3 uses PyHPKE 0.6.3. The three implementations are
tested against each other. PyHPKE and hpke-js report passing the RFC vectors but have not had a
formal independent audit; they are local readers and never expand what Cloudflare can see.

The TypeScript reader dispatches on the first byte. It opens both version 1 and version 2, but every
new seal is version 2. The Python reference intentionally opens only version 2 and fails clearly on
a legacy day rather than silently attempting another construction.

## Migration state

Fresh installs now start with **Create encrypted archive**. Existing build-7 installations retain
their stored destination and keep uploading to it; they do not have its reading private key on the
phone, so the new connection handoff is unavailable and the screen labels the archive as a legacy
connection. Adopting that legacy destination records its bucket without changing its ledger.

The first app build containing HPKE records the sealing version beside the archive ledger. When it
finds a ledger created by version 1, it clears the plaintext digests and requeues every known day in
one transaction. HealthKit anchors, sample-to-day rows, installation day and backfill progress stay
intact. The phone then replaces days with version 2 newest first; the local TypeScript reader can
read a mixed archive throughout this process. The reset is stored before sending and therefore runs
only once even if the migration is interrupted.

The owner can keep the existing archive, or explicitly disconnect and create a new phone-owned one.
Disconnecting forgets the old signing key. Creating the new archive binds the ledger to its bucket,
clears the previous archive's fingerprints, upload time, export progress and reconciliation time,
and queues every day the phone already knows. HealthKit anchors, sample-to-day rows and the install
day survive because they describe the phone, not an archive. This reset happens once per bucket and
starts sending immediately; **Export everything Health has** additionally discovers history that
was never present in the old ledger. Upgrading an affected build-8 phone-owned connection performs
the same one-time reset, while importing an old reader-owned private key remains outside this
implementation.

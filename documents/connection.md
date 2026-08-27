# Connection architecture

Status: **live since 2026-08-27 in TestFlight build 8 and Worker version
`9f7af515-652c-4391-917a-3aa406597f24`**. The live health check, immutable connection prompt and
keyless remote MCP tool listing were verified after deployment. Build 7 still contains the
superseded reader-first scan described under [Migration state](#migration-state).

The first real build-8 handoff was verified end to end on 2026-08-27: the local importer matched the
reading key to the phone-created bucket, wrote owner-only files, and the local MCP answered
`health_overview`. The new archive was still empty at that check, pending the phone's Health export.

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
https://<public-host>/prompts/connect/v1

MCP:
https://<mcp-host>/mcp/b/<bucket-id>

Reading key:
<private-reading-key>
```

The exact public hosts are deployment configuration, not protocol constants.

The concrete key value is
`efferent-reading-v1.<raw-private-base64url>.<raw-public-base64url>`. It remains one field. The public
half lets the local importer derive the bucket and reject a handoff whose key and MCP URL do not
belong together; the private half is the secret. The importer turns the raw private key into the
PKCS8 representation used by the existing local reader.

The bucket id belongs in the MCP URL; it is an address, not a decryption secret. The reading key is
a separate field. It must never appear in a URL, an HTTP header, a remote MCP tool argument, a log,
or server-side storage. Once received, the agent moves it into the local reader's secret storage and
does not repeat it in model-visible output.

The prompt URL is public, immutable and versioned. It contains only stable instructions for an agent
that knows nothing about Efferent: how to connect the remote MCP server, install or invoke the local
reader, store the key locally and use the health tools correctly. It contains no user-specific
bucket, key or archive data.

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
The public prompt is served at `/prompts/connect/v1` with an immutable one-year cache policy. The
phone claims an empty archive with a signed `PUT /b/<bucket-id>` before any Health day exists.

### Agent machine

- Read the public connection prompt.
- Store the reading private key locally.
- Connect to the keyless remote MCP endpoint using the bucket id only.
- Fetch ciphertext, decrypt it locally and run `tools/analysis.ts` locally.
- Expose the existing shaped health tools from a local process when the host supports local MCP.

An agent that cannot execute code locally cannot read an Efferent archive under this security model.
That is a capability boundary, not a reason to give the key to Cloudflare.

## Migration state

Fresh installs now start with **Create encrypted archive**. Existing build-7 installations retain
their stored destination and keep uploading to it; they do not have its reading private key on the
phone, so the new connection handoff is unavailable and the screen labels the archive as a legacy
connection. There is deliberately no automatic migration and no silent decade-long re-upload.

The owner can keep the existing archive, or explicitly disconnect and create a new phone-owned one.
Disconnecting forgets the old signing key. After creating a new archive, **Export everything Health
has** is the explicit action that moves the history. Importing an old reader-owned private key into
the phone remains outside this implementation.

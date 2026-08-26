# Connection architecture

Status: **decided on 2026-08-27, not implemented yet**. Build 7 and the current source tree still
use the superseded reader-first scan described under [Migration state](#migration-state).

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

### Agent machine

- Read the public connection prompt.
- Store the reading private key locally.
- Connect to the keyless remote MCP endpoint using the bucket id only.
- Fetch ciphertext, decrypt it locally and run `tools/analysis.ts` locally.
- Expose the existing shaped health tools from a local process when the host supports local MCP.

An agent that cannot execute code locally cannot read an Efferent archive under this security model.
That is a capability boundary, not a reason to give the key to Cloudflare.

## Migration state

The current implementation predates this decision:

- the reader creates the reading key pair;
- `efferent pair --url ...` prints a code containing the endpoint and public key;
- the phone scans that code before it can create or write its archive;
- only the local stdio MCP server exists.

Those behaviours describe build 7, but they no longer describe the intended architecture. Do not
extend the old pairing flow. Replacing it requires a phone-side reading key, an unpaired archive
creation screen, the public bootstrap prompt, a keyless remote MCP endpoint and local key import on
the reader. Migration of an existing archive is a separate implementation decision; this document
does not silently choose between importing its existing key and creating a new archive.

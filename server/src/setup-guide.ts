import { PYTHON_HPKE_REFERENCE } from "./python-reference.ts";

/** The single current setup guide returned by the remote MCP server. */
export const SETUP_GUIDE = `# Set up Efferent

You are connecting an end-to-end encrypted Apple Health archive. The phone gave you three fields:
an instruction, a remote MCP URL containing the bucket id, and a reading key.

Security boundary:

- Keep the reading key on this machine. Never put it in a URL, HTTP header, remote MCP argument,
  log, chat reply, process argument, or cloud service.
- The remote MCP server lists sealed days and returns ciphertext links. It never receives the key.
- Decryption and every health-data answer must run locally. Never send decrypted health data to a
  remote tool. If you cannot run local code, stop.

The envelope is RFC 9180 base-mode HPKE with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
ChaCha20-Poly1305. A stored day is:

    [version 0x02][32-byte encapsulated key][ciphertext and 16-byte tag]

The HPKE info is \`efferent/v2 hpke\`. The authenticated data is
\`efferent/v1\\n<bucket-id>\\n<YYYY-MM-DD>\`. The decrypted bytes are raw-deflate-compressed NDJSON.

Local reading procedure:

1. Create a private Python virtual environment and install \`pyhpke==0.6.3\`.
2. Save the code below as \`efferent_hpke.py\`. Save the complete three-field handoff as a separate
   owner-only file and set both files to mode 600 on POSIX systems.
3. Use \`archive_status\` and \`list_sealed_days\` to choose the dates needed for the question. Run
   \`python efferent_hpke.py --handoff <file> --day YYYY-MM-DD\` locally for each required date.
   Keep its NDJSON output local and analyse it with local code.
4. Delete the temporary handoff file when the local session no longer needs it.

No Efferent repository, Deno installation, local MCP server or gateway restart is required. The
script derives the ciphertext URL from the keyless MCP URL; its requests contain only the bucket id
and date.

\`\`\`python
${PYTHON_HPKE_REFERENCE}\`\`\`

The Python reference validates that the private and public key halves match and that their public
half derives the bucket id in the MCP URL before it makes a request. It deliberately accepts only
HPKE version 2 and fails clearly on any other envelope.
`;

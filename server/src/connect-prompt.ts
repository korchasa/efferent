import { PYTHON_HPKE_REFERENCE } from "./python-reference.ts";

export const CONNECT_PROMPT_V1 = `# Connect Efferent v1

You are connecting an end-to-end encrypted Apple Health archive. The phone gave you four fields:
an instruction, this public prompt URL, a remote MCP URL containing the bucket id, and a reading key.

Security boundary:

- Keep the reading key on this machine. Never put it in a URL, HTTP header, remote MCP argument,
  log, chat reply, or cloud service.
- The remote MCP server has no decryption capability. It lists sealed days and returns links to
  ciphertext only.
- Decryption and every health-data answer must run locally. If you cannot run local code, stop.

Connection procedure:

1. Connect the supplied remote MCP URL using Streamable HTTP. Do not add authentication or the key.
2. Clone https://github.com/korchasa/efferent.git on the local machine and require Deno 2.
3. Put the complete four-field handoff in a file readable only by the current user, or pass it on
   standard input. Set EFFERENT_HOME to a new private directory and run:

       deno task efferent connect --handoff <file>

   Use --handoff - for standard input. Delete the temporary handoff file after a successful import.
4. Register the local MCP process with \`deno task mcp\` and the same absolute EFFERENT_HOME. Use its
   health tools for all questions; they fetch ciphertext and decrypt it locally.
5. Call \`health_overview\` first. Its result and every health tool description carry the rules
   needed to interpret the archive correctly.

The local importer verifies that the reading key derives the bucket id embedded in the remote MCP
URL before it writes any local configuration. It refuses to overwrite an existing local reader.
`;

export const CONNECT_PROMPT_V2 = `# Connect Efferent v2

You are connecting an end-to-end encrypted Apple Health archive. The phone gave you four fields:
an instruction, this public prompt URL, a remote MCP URL containing the bucket id, and a reading key.

Security boundary:

- Keep the reading key on this machine. Never put it in a URL, HTTP header, remote MCP argument,
  log, chat reply, process argument, or cloud service.
- The remote MCP server lists sealed days and returns ciphertext links. It never receives the key.
- Decryption and every health-data answer must run locally. If you cannot run local code, stop.

The envelope is RFC 9180 base-mode HPKE with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
ChaCha20-Poly1305. A stored day is:

    [version 0x02][32-byte encapsulated key][ciphertext and 16-byte tag]

The HPKE info is \`efferent/v2 hpke\`. The authenticated data is
\`efferent/v1\\n<bucket-id>\\n<YYYY-MM-DD>\`. The decrypted bytes are raw-deflate-compressed NDJSON.

Recommended connection:

1. Connect the supplied remote MCP URL using Streamable HTTP. Do not add authentication or the key.
2. Clone https://github.com/korchasa/efferent.git locally and require Deno 2.
3. Put the complete four-field handoff in an owner-only file, set EFFERENT_HOME to a new private
   directory, and run \`deno task efferent connect --handoff <file>\`. Delete the handoff file after
   import.
4. Register \`deno task mcp\` as a local MCP process with the same absolute EFFERENT_HOME. Call
   \`health_overview\` first, then use the shaped local health tools.

Minimal Python reference:

1. Create a private virtual environment and install \`pyhpke==0.6.3\`.
2. Save the code below as \`efferent_hpke.py\` and the complete handoff as an owner-only file.
3. Run \`python efferent_hpke.py --handoff <file> --day YYYY-MM-DD\` locally. Never replace the file
   argument with the reading key itself.

\`\`\`python
${PYTHON_HPKE_REFERENCE}\`\`\`

The Python reference deliberately accepts only HPKE version 2. During migration, the repository's
local reader also opens legacy version 1 days. The local importer verifies that the reading key
derives the bucket id in the MCP URL and refuses to overwrite an existing reader.
`;

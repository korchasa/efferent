import { PYTHON_HPKE_REFERENCE } from "./python-reference.ts";

/** The single current setup guide returned by the remote MCP server. */
export const SETUP_GUIDE = `# Set up Efferent

You are connecting an end-to-end encrypted Apple Health archive. The phone gave you three fields:
an instruction, a remote MCP URL containing the bucket id, and a reading key. A phone that can write
adds a fourth, an editor key; without it the connection reads and cannot write.

Security boundary:

- Keep the reading key and the editor key on this machine. Never put either in a URL, HTTP header,
  remote MCP argument, log, chat reply, process argument, or cloud service.
- The remote MCP server lists sealed days and returns ciphertext links. It never receives a key.
- Decryption and every health-data answer must run locally. Never send decrypted health data to a
  remote tool. If you cannot run local code, stop.

The envelope is RFC 9180 base-mode HPKE with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
ChaCha20-Poly1305. A stored day is:

    [version 0x02][32-byte encapsulated key][ciphertext and 16-byte tag]

The HPKE info is \`efferent/v2 hpke\`. The authenticated data is
\`efferent/v1\\n<bucket-id>\\n<YYYY-MM-DD>\`. The decrypted bytes are a raw-deflate-compressed day: one JSON
object holding columns, where rows that share a metric, unit and source device say all of that once.
The script below unpacks it into NDJSON, one self-contained object per line, which is the shape to
analyse. Days stored before this layout are lines already and pass straight through.

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

To write into Health:

The same script writes, when the handoff carries an editor key. Put the items in a JSON file and run
\`python efferent_hpke.py --handoff <file> --write <items.json>\`. The script seals the items to the
phone's own reading key, signs them with the editor key and hands the sealed edit to the service,
which stores it unopened and answers with a name. The phone opens the edit, checks the signature
itself, writes the samples into Health and reports what it did; \`--edits\` lists every edit with
\`pending\`, \`applied\`, \`partial\` or \`failed\` and the counts. The phone looks when it is opened or
wakes to send — minutes to hours, never at once.

An item is \`{"op":"put","id":...,"metric":...,"start":...,"end":...,"value":...,"unit":...}\` for a
quantity, the same with \`"stage"\` instead of value and unit for sleep, or \`{"op":"delete","id":...}\`.
The metrics and their one unit each: dietaryEnergy in kcal, dietaryProtein, dietaryCarbohydrates and
dietaryFat in g, dietaryWater in mL, bodyMass in kg; sleep takes a stage of inBed, awake,
asleepUnspecified, asleepCore, asleepDeep or asleepREM. \`start\` and \`end\` are whole seconds since
1970 and must both be in the past. The \`id\` is your handle for one entry — a second \`put\` under the
same id replaces it and a \`delete\` removes it — so choose ids you can rebuild, such as
\`agent:meal:2026-09-07:lunch\`. Only entries written this way can be replaced or removed; what the
watch, the phone or another app recorded stays as it is. A refused item comes back with a word:
badRange for an end in the future, badUnit for the wrong unit, unauthorized when Health access to
that type was declined on the phone, notFound for a delete of an id never written, healthRefused
when Health itself said no. The days an edit touched are re-uploaded, so the written entries appear
in the archive afterwards like anything logged by hand.

\`\`\`python
${PYTHON_HPKE_REFERENCE}\`\`\`

The Python reference validates that the private and public key halves match and that their public
half derives the bucket id in the MCP URL before it makes a request. It deliberately accepts only
HPKE version 2 and fails clearly on any other envelope.
`;

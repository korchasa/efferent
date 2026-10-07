/**
 * `deno task skill` — the agent skill, assembled in `build/skill/efferent/`.
 *
 * The skill is two files: `SKILL.md`, written in `skill/efferent/`, and the
 * reading client beside it. The client is copied rather than kept twice in the
 * tree, so the skill an agent installs runs exactly the client this
 * repository tests. The copy is checked by running its own self-test.
 */

import { run, section } from "./lib.ts";
import { CLIENT, NODE, requireNode } from "./reader.ts";

const SOURCE = "skill/efferent";
const TARGET = "build/skill/efferent";

section("Assembling the agent skill");
await requireNode();
await Deno.remove(TARGET, { recursive: true }).catch((error) => {
  if (!(error instanceof Deno.errors.NotFound)) throw error;
});
await Deno.mkdir(TARGET, { recursive: true });
await Deno.copyFile(`${SOURCE}/SKILL.md`, `${TARGET}/SKILL.md`);
await Deno.copyFile(CLIENT, `${TARGET}/efferent.mjs`);
await run(NODE, { args: [`${TARGET}/efferent.mjs`, "self-test"] });
console.log(`the skill is in ${TARGET}: SKILL.md and efferent.mjs`);

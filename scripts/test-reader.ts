/** `deno task test:reader` — the Python reader's own checks: format, lint, tests. */

import { run, section } from "./lib.ts";
import { PYTHON, requireReader, RUFF } from "./reader.ts";

export async function checkReader(): Promise<void> {
  await requireReader();
  await run(RUFF, { args: ["format", "--check", "reader"] });
  await run(RUFF, { args: ["check", "reader"] });
  await run(PYTHON, { args: ["-m", "unittest", "discover", "-s", "reader/tests", "-t", "reader"] });
}

if (import.meta.main) {
  section("Checking and testing the Python reader");
  await checkReader();
}

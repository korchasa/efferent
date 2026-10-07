/**
 * `deno task test:reader` — the reading side's own checks: the Node client
 * formatted, linted and tested, then the Python reference the same way.
 */

import { run, section } from "./lib.ts";
import {
  CLIENT,
  NODE,
  NODE_TESTS,
  nodeTests,
  PYTHON,
  requireNode,
  requireReader,
  RUFF,
} from "./reader.ts";

export async function checkReader(): Promise<void> {
  await requireNode();
  await requireReader();
  await run("deno", { args: ["fmt", "--check", CLIENT, NODE_TESTS] });
  await run("deno", { args: ["lint", CLIENT, NODE_TESTS] });
  await run(NODE, { args: [CLIENT, "self-test"] });
  await run(NODE, { args: ["--test", ...await nodeTests()] });
  await run(RUFF, { args: ["format", "--check", "reader"] });
  await run(RUFF, { args: ["check", "reader"] });
  await run(PYTHON, { args: ["-m", "unittest", "discover", "-s", "reader/tests", "-t", "reader"] });
}

if (import.meta.main) {
  section("Checking and testing the reading side");
  await checkReader();
}

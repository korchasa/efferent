/**
 * Where the Python reader's interpreter is, for every task that runs it.
 *
 * `deno task reader:setup` makes `reader/.venv` from Python 3.13 and installs
 * the one run-time dependency and the formatter. `EFFERENT_PYTHON` points a
 * task at another interpreter, which is how a machine without Homebrew runs
 * the same tasks.
 */

import { exists, fail, run, section } from "./lib.ts";

const VENV = "reader/.venv";
const BOOTSTRAP = "/opt/homebrew/bin/python3.13";

export const PYTHON = Deno.env.get("EFFERENT_PYTHON") ?? `${VENV}/bin/python`;
export const RUFF = `${VENV}/bin/ruff`;

/** Fail with the one command that fixes it, rather than a missing-file trace. */
export async function requireReader(): Promise<void> {
  if (!await exists(PYTHON)) {
    fail(`no Python reader interpreter at ${PYTHON} — run \`deno task reader:setup\``);
  }
}

if (import.meta.main) {
  section("Setting up the Python reader");
  if (!await exists(BOOTSTRAP)) {
    fail(`${BOOTSTRAP} is missing — install Python 3.13 with Homebrew first`);
  }
  await run(BOOTSTRAP, { args: ["-m", "venv", VENV] });
  await run(`${VENV}/bin/pip`, { args: ["install", "--quiet", "--upgrade", "pip"] });
  await run(`${VENV}/bin/pip`, { args: ["install", "--quiet", "-e", "reader[dev]"] });
  console.log(`the reader runs with ${VENV}/bin/python`);
}

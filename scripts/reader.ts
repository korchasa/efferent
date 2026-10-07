/**
 * Where the reading client's Node is, and where the Python reference's
 * interpreter is, for every task that runs either.
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

/**
 * The reading client, and the Node that runs it. `EFFERENT_NODE` points a task
 * at another Node, the way `EFFERENT_PYTHON` does for the reference.
 */
export const NODE = Deno.env.get("EFFERENT_NODE") ?? "node";
export const CLIENT = "reader/efferent.mjs";
export const NODE_TESTS = "reader/tests/node";
const OLDEST_NODE = 22;

/**
 * The Node test files, listed here rather than left to `node --test <dir>`:
 * before Node 26 a directory argument is read as a module and the run fails
 * without a single test having started.
 */
export async function nodeTests(): Promise<string[]> {
  const found: string[] = [];
  for await (const entry of Deno.readDir(NODE_TESTS)) {
    if (entry.isFile && entry.name.endsWith(".test.mjs")) found.push(`${NODE_TESTS}/${entry.name}`);
  }
  return found.sort();
}

/** Fail with what to install when there is no Node, or one too old to run the client. */
export async function requireNode(): Promise<void> {
  let version = "";
  try {
    const { stdout } = await new Deno.Command(NODE, { args: ["--version"], stdout: "piped" })
      .output();
    version = new TextDecoder().decode(stdout).trim();
  } catch {
    fail(
      `no Node at ${NODE} — install Node ${OLDEST_NODE} or newer, or point EFFERENT_NODE at one`,
    );
  }
  const major = Number(/^v(\d+)\./.exec(version)?.[1] ?? 0);
  if (major < OLDEST_NODE) {
    fail(`${NODE} is ${version || "unknown"}; the client needs Node ${OLDEST_NODE} or newer`);
  }
}

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

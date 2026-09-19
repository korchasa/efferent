/**
 * `deno task mcp` and `deno task efferent` — the Python reader, run as a task.
 *
 * Every command in this repository is a `deno task`, and the reading side is
 * Python. This is the one line between the two: it finds the interpreter the
 * way every other task does and hands over stdin, stdout and the exit code
 * unchanged, so an MCP client speaking JSON-RPC down a pipe notices nothing.
 */

import { fail } from "./lib.ts";
import { PYTHON, requireReader } from "./reader.ts";

const [module, ...rest] = Deno.args;
if (!module) fail("usage: deno run -A scripts/reader-run.ts <python module> [arguments]");

await requireReader();

const child = new Deno.Command(PYTHON, {
  args: ["-m", module, ...rest],
  env: { PYTHONPATH: "reader" },
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
}).spawn();

Deno.exit((await child.status).code);

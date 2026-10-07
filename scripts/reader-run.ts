/**
 * `deno task mcp`, `deno task efferent` and `deno task phone` — the reading
 * side, run as a task.
 *
 * Every command in this repository is a `deno task`. This is the one line
 * between a task and the program behind it: `node` runs the reading client
 * (`reader/efferent.mjs`), `python` runs a module of the Python reference — the
 * stand-in phone that `send` and `keygen` belong to. Stdin, stdout and the exit
 * code pass through unchanged, so an MCP client speaking JSON-RPC down a pipe
 * notices nothing.
 */

import { fail } from "./lib.ts";
import { CLIENT, NODE, PYTHON, requireNode, requireReader } from "./reader.ts";

const [runtime, ...rest] = Deno.args;
let command: Deno.Command;
if (runtime === "node") {
  await requireNode();
  command = new Deno.Command(NODE, {
    args: [CLIENT, ...rest],
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
} else if (runtime === "python" && rest.length) {
  await requireReader();
  command = new Deno.Command(PYTHON, {
    args: ["-m", ...rest],
    env: { PYTHONPATH: "reader" },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
} else {
  fail("usage: deno run -A scripts/reader-run.ts node [arguments] | python <module> [arguments]");
}

Deno.exit((await command.spawn().status).code);

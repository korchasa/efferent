/**
 * `deno task interop` — do the two implementations still agree?
 *
 * The Swift under `src/Core` and the Python reader describe the same bytes
 * twice, in two languages, and nothing but a check keeps them in step. A Swift
 * test packs, seals and signs a real request of two days; the reader unpacks
 * it, opens each day with the matching private key and checks the signature.
 * The read key goes the same way: both sides make it from one reading key, and
 * the reader verifies a read the phone signed. Drift between the two shows up
 * here rather than on a phone.
 *
 * This half runs the Swift test. Everything that touches a key is in the two
 * readers' own checks: `reader/tests/node/interop.mjs` for the client agents
 * run, and `reader/efferent/interop.py` for the Python reference. The edit the
 * phone opens is sealed by the Node client, because that is what an agent
 * sends; the Python reference's own sealing is held to the Node client's by the
 * Node tests. A check written against a third implementation would prove only
 * that the third one is consistent.
 */

import { fail, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";
import { NODE, PYTHON, requireNode, requireReader } from "./reader.ts";

const STATE = "reader/.interop.json";

await requireNode();
await requireReader();
await generate();

section("Sealing and signing an edit for the phone to open");
// Writing goes the other way round from a day, so the client seals and the
// phone opens. The keys are made for this run and never leave the process.
const { stdout: fixture } = await run(NODE, {
  args: ["reader/tests/node/interop.mjs", "fixture", STATE],
  capture: true,
});

section("Producing a request from the Swift side, and opening the edit there");
const { stdout } = await run("xcodebuild", {
  args: [
    "test",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-destination",
    `platform=iOS Simulator,id=${await anyAvailableIPhone()}`,
    "-only-testing:EfferentTests/InteropTests",
    "-only-testing:EfferentTests/EditInteropTests",
    // Deliberately not `-quiet`: what the test prints is the whole point, and
    // quiet mode swallows it.
  ],
  env: { ...systemToolPath(), TEST_RUNNER_EFFERENT_EDIT_FIXTURE: fixture.trim() },
  capture: true,
});

// Written into the state file rather than piped: `run` inherits stdin, and a
// shared helper is not the place to grow an option for one caller.
const emitted = {
  frame: marker(stdout, "FRAME"),
  writer: marker(stdout, "WRITER"),
  signature: marker(stdout, "SIGNATURE"),
  timestamp: marker(stdout, "TIMESTAMP"),
  handoff: marker(stdout, "HANDOFF"),
  editItems: marker(stdout, "EDIT_ITEMS"),
  editIds: marker(stdout, "EDIT_IDS"),
  editMetrics: marker(stdout, "EDIT_METRICS"),
  reader: marker(stdout, "READER"),
  readSignature: marker(stdout, "READSIGNATURE"),
  liveTimestamp: marker(stdout, "LIVETIMESTAMP"),
  liveSignature: marker(stdout, "LIVESIGNATURE"),
};

// The bytes agree; whether a real service accepts them is a separate question,
// and the only way to answer it is to ask one. Never a bucket a real phone will
// use: the first writer owns a bucket for good.
const postTo = Deno.args.includes("--post")
  ? Deno.args[Deno.args.indexOf("--post") + 1]
  : undefined;

await Deno.writeTextFile(
  STATE,
  JSON.stringify({ ...JSON.parse(await Deno.readTextFile(STATE)), emitted }),
);
// The fixed reading key the Swift test seals its days to lives in one file,
// the one the secret scanner excuses for it; the Node check is handed it.
const { stdout: fixedKey } = await run(PYTHON, {
  args: ["-c", "from efferent.interop import READING_PRIVATE; print(READING_PRIVATE)"],
  env: { PYTHONPATH: "reader" },
  capture: true,
});
await run(NODE, {
  args: ["reader/tests/node/interop.mjs", "check", STATE],
  env: { EFFERENT_INTEROP_READING_PRIVATE: fixedKey.trim() },
});
// Last, because it removes the state file once both sides have agreed.
await run(PYTHON, {
  args: ["-m", "efferent.interop", "check", STATE, ...(postTo ? [postTo] : [])],
  env: { PYTHONPATH: "reader" },
});

function marker(output: string, name: string): string {
  const match = new RegExp(`EFFERENT_INTEROP_${name}=(\\S+)`).exec(output);
  if (!match) fail(`the Swift test did not print ${name} — did it run at all?`);
  return match[1];
}

async function anyAvailableIPhone(): Promise<string> {
  const { stdout } = await run("xcrun", {
    args: ["simctl", "list", "devices", "available", "--json"],
    capture: true,
  });
  const devices = JSON.parse(stdout).devices as Record<string, { name: string; udid: string }[]>;
  for (const list of Object.values(devices)) {
    const iPhone = list.find((device) => device.name.startsWith("iPhone"));
    if (iPhone) return iPhone.udid;
  }
  fail("no iPhone simulator is available — install one in Xcode");
}

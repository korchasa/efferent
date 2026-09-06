/** `deno task screenshots <directory>` — the store screenshots, rendered by the app.
 *
 * Builds the release app for a simulator, installs it there and launches it
 * with `--snapshot <directory>`, which makes the app draw its three screens
 * offscreen at 1290 × 2796 and quit. Signing, uploading and the store listing
 * itself happen outside this repository; this only produces the pictures. */

import { fail, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";

const BUNDLE = "dev.korchasa.efferent";

const directory = Deno.args[0];
if (!directory) fail("usage: deno task screenshots <directory>");
const output = await Deno.realPath(
  await Deno.mkdir(directory, { recursive: true }).then(() => directory),
);

/** Any iPhone will do for the build, but the pictures must come out at the
 * 6.7-inch store size, so a Pro Max is what gets booted. */
async function proMax(): Promise<string> {
  const { stdout } = await run("xcrun", {
    args: ["simctl", "list", "devices", "available", "--json"],
    capture: true,
  });
  const devices = JSON.parse(stdout).devices as Record<string, { name: string; udid: string }[]>;
  for (const list of Object.values(devices)) {
    const device = list.find((device) => /^iPhone \d+ Pro Max$/.test(device.name));
    if (device) return device.udid;
  }
  fail("no iPhone Pro Max simulator is available — install one in Xcode");
}

await generate();
const udid = await proMax();
const derived = await Deno.makeTempDir({ prefix: "efferent-screenshots-" });

section(`Building the release app for simulator ${udid}`);
await run("xcodebuild", {
  args: [
    "build",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-configuration",
    "Release",
    "-destination",
    `platform=iOS Simulator,id=${udid}`,
    "-derivedDataPath",
    derived,
    "-quiet",
  ],
  env: systemToolPath(),
});

section("Rendering the screens");
await run("xcrun", { args: ["simctl", "bootstatus", udid, "-b"] });
await run("xcrun", {
  args: [
    "simctl",
    "install",
    udid,
    `${derived}/Build/Products/Release-iphonesimulator/Efferent.app`,
  ],
});
await run("xcrun", {
  args: [
    "simctl",
    "launch",
    "--console-pty",
    "--terminate-running-process",
    udid,
    BUNDLE,
    "--snapshot",
    output,
  ],
});
for await (const entry of Deno.readDir(output)) {
  if (entry.name.endsWith(".png")) console.log(`  ${output}/${entry.name}`);
}

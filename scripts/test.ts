/** `deno task test` — unit tests on a simulator. */

import { fail, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";

/** Pick any booted-or-bootable iPhone rather than pinning a model that a future
 * Xcode drops. Pinning is what makes these scripts rot. */
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

section("Testing the protocol");
await run("deno", { args: ["test", "-A", "protocol/"] });

await generate();

const udid = await anyAvailableIPhone();
section(`Testing on simulator ${udid}`);
await run("xcodebuild", {
  args: [
    "test",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-destination",
    `platform=iOS Simulator,id=${udid}`,
    "-quiet",
  ],
  env: systemToolPath(),
});

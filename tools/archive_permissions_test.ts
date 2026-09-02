import { assertEquals } from "@std/assert";

Deno.test("the local reader keeps its directory and plaintext private", async () => {
  if (Deno.build.os === "windows") return;

  const root = await Deno.makeTempDir();
  const home = `${root}/reader`;
  const previous = Deno.env.get("EFFERENT_HOME");
  Deno.env.set("EFFERENT_HOME", home);

  try {
    const archive = await import(`./archive.ts?permissions=${crypto.randomUUID()}`);
    await archive.write("mirror.json", { endpoint: "https://efferent.example", days: {} });
    // The kept metric record goes down the same path but compactly, and it holds
    // the same kind of thing: which metrics this person records, how many
    // readings a day, and when each device arrived.
    await archive.write("metrics.json", { "2026-08-27": { v: "1:2" } }, { compact: true });
    await archive.writeDay("2026-08-27", [{ id: "sample", v: 1 }]);

    assertEquals(permission(await Deno.stat(home)), 0o700);
    assertEquals(permission(await Deno.stat(`${home}/mirror.json`)), 0o600);
    assertEquals(permission(await Deno.stat(`${home}/metrics.json`)), 0o600);
    assertEquals(permission(await Deno.stat(`${home}/days`)), 0o700);
    assertEquals(permission(await Deno.stat(`${home}/days/2026-08-27.ndjson`)), 0o600);
  } finally {
    if (previous === undefined) Deno.env.delete("EFFERENT_HOME");
    else Deno.env.set("EFFERENT_HOME", previous);
    await Deno.remove(root, { recursive: true });
  }
});

function permission(info: Deno.FileInfo): number {
  return (info.mode ?? 0) & 0o777;
}

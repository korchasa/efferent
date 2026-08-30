/**
 * The MCP server, spoken to the way an agent speaks to it.
 *
 * The fixture is a real mirror — a reading key, a `mirror.json` and day files —
 * pointed at an address nothing answers on. That is deliberate: it exercises the
 * path a laptop on a train takes, where the archive is unreachable and the
 * answer has to come out of the mirror with a warning attached rather than not
 * come out at all.
 */

import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { base64url } from "../protocol/signing.ts";

const home = await Deno.makeTempDir({ prefix: "efferent-mcp-" });
Deno.env.set("EFFERENT_HOME", home);

// Nothing listens on port 9, so every call to the archive fails at once.
const UNREACHABLE = "http://127.0.0.1:9";

await seedFixture();
// Imported after the home directory is set: the reading layer resolves it once,
// when the module is first evaluated.
const { handle } = await import("./mcp.ts");

async function seedFixture(): Promise<void> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  await Deno.writeTextFile(
    `${home}/reading-key.json`,
    JSON.stringify({
      readingPrivate: base64url(
        new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      ),
      readingPublic: base64url(
        new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
      ),
    }),
  );
  await Deno.writeTextFile(
    `${home}/mirror.json`,
    JSON.stringify({ endpoint: UNREACHABLE, days: {}, syncedAt: "" }),
  );

  await Deno.mkdir(`${home}/days`, { recursive: true });
  await day("2026-01-01", [
    total("steps", "2026-01-01", 8000),
    total("flightsClimbed", "2026-01-01", 12),
    // An hourly bucket for the same day, which must never reach a daily table.
    {
      id: "agg:steps:h",
      v: 1,
      metric: "steps",
      bucket: "hour",
      value: 400,
      unit: "count",
      start: "2026-01-01T09:00:00Z",
      end: "2026-01-01T10:00:00Z",
    },
    record("heartRate", "2026-01-01T09:00:00Z", 60, "count/min"),
    record("heartRate", "2026-01-01T10:00:00Z", 80, "count/min"),
    asleep("2026-01-01T22:00:00Z", "2026-01-02T00:00:00Z"),
    // The same stretch again from a second source: merged, never added.
    asleep("2026-01-01T22:30:00Z", "2026-01-01T23:30:00Z"),
    {
      id: "hk:workout:1",
      v: 1,
      metric: "workout",
      activity: "52",
      duration: 1800,
      start: "2026-01-01T12:00:00Z",
      end: "2026-01-01T12:30:00Z",
    },
  ]);
  await day("2026-01-02", [
    total("steps", "2026-01-02", 3000),
    asleep("2026-01-02T00:00:00Z", "2026-01-02T06:00:00Z"),
    record("heartRate", "2026-01-02T09:00:00Z", 70, "count/min"),
  ]);
}

function total(metric: string, on: string, value: number) {
  return {
    id: `agg:${metric}:${on}:d`,
    v: 1,
    metric,
    bucket: "day",
    value,
    unit: metric === "steps" ? "count" : "count",
    start: `${on}T00:00:00Z`,
    end: `${on}T23:59:59Z`,
  };
}

function record(metric: string, at: string, value: number, unit: string) {
  return { id: `hk:${metric}:${at}`, v: 1, metric, value, unit, start: at, end: at };
}

function asleep(start: string, end: string) {
  return { id: `hk:sleep:${start}`, v: 1, metric: "sleep", stage: "asleepCore", start, end };
}

async function day(name: string, events: unknown[]): Promise<void> {
  await Deno.writeTextFile(
    `${home}/days/${name}.ndjson`,
    events.map((event) => JSON.stringify(event)).join("\n") + "\n",
  );
}

// MARK: - Speaking to it

// deno-lint-ignore no-explicit-any
async function rpc(method: string, params?: Record<string, unknown>): Promise<any> {
  return await handle({ jsonrpc: "2.0", id: 1, method, params });
}

/** A tool call, with the JSON its single text block carries already parsed. */
// deno-lint-ignore no-explicit-any
async function call(name: string, args: Record<string, unknown> = {}): Promise<any> {
  const answer = await rpc("tools/call", { name, arguments: args });
  const text = answer.result.content[0].text;
  return { isError: answer.result.isError === true, text, body: parse(text) };
}

function parse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// MARK: - The handshake

Deno.test("initialize answers in the version it was asked for", async () => {
  const answer = await rpc("initialize", { protocolVersion: "2024-11-05" });

  assertEquals(answer.result.protocolVersion, "2024-11-05");
  assertEquals(answer.result.serverInfo.name, "efferent");
  assert(answer.result.capabilities.tools, "tools were not offered");
  // The instructions are what an agent gets before it has read a single day, so
  // they have to name the tool that orients it.
  assertStringIncludes(answer.result.instructions, "iphone_data_overview");
});

Deno.test("a version this server does not speak falls back to one it does", async () => {
  const answer = await rpc("initialize", { protocolVersion: "1999-01-01" });

  assertEquals(answer.result.protocolVersion, "2025-06-18");
});

Deno.test("a notification is not answered", async () => {
  // Replying to one is a protocol error, not a harmless extra, and clients
  // differ in how loudly they complain.
  const answer = await handle(
    {
      jsonrpc: "2.0",
      method: "notifications/initialized",
    } as Parameters<typeof handle>[0],
  );

  assertEquals(answer, null);
});

Deno.test("every tool arrives with a schema and a description", async () => {
  const answer = await rpc("tools/list");
  const tools: { name: string; description: string; inputSchema: unknown }[] = answer.result.tools;

  assertEquals(tools.length, 7);
  for (const tool of tools) {
    assert(tool.description.length > 100, `${tool.name} is described too thinly to use unprompted`);
    assert(tool.inputSchema, `${tool.name} has no schema`);
  }
  assertEquals(
    tools.map((tool) => tool.name).sort(),
    [
      "iphone_data_daily",
      "iphone_data_overview",
      "iphone_data_samples",
      "iphone_data_sleep",
      "iphone_data_statistics",
      "iphone_data_sync",
      "iphone_data_workouts",
    ],
  );
});

/**
 * The one test that runs the server the way a client does: as a process, over
 * its own stdin and stdout.
 *
 * Importing the module and calling `handle` cannot see this class of fault at
 * all. `serve` never returns, so anything defined below the call to it stays
 * uninitialised — the handshake succeeds and the next request dies on a
 * variable that does not exist yet. It shipped exactly once, for about ten
 * minutes, and the unit tests above were all green while it did.
 */
Deno.test("the server answers as a process, past the handshake", async () => {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", new URL("./mcp.ts", import.meta.url).pathname],
    stdin: "piped",
    stdout: "piped",
    stderr: "null",
    // Its own empty home: this test must never touch a real archive, and none
    // of what it asks for needs one.
    env: { EFFERENT_HOME: `${home}/nothing` },
  }).spawn();

  const writer = child.stdin.getWriter();
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const reader = child.stdout.getReader();
  let buffer = "";

  async function ask(method: string, id: number): Promise<Record<string, unknown>> {
    await writer.write(encoder.encode(JSON.stringify({ jsonrpc: "2.0", id, method }) + "\n"));
    while (!buffer.includes("\n")) {
      const { value, done } = await reader.read();
      if (done) throw new Error("the server closed before answering");
      buffer += decoder.decode(value, { stream: true });
    }
    const line = buffer.slice(0, buffer.indexOf("\n"));
    buffer = buffer.slice(buffer.indexOf("\n") + 1);
    return JSON.parse(line);
  }

  try {
    const hello = await ask("initialize", 1) as { result: { serverInfo: { name: string } } };
    assertEquals(hello.result.serverInfo.name, "efferent");

    // The second request is the one that matters — the first would pass either
    // way.
    const listed = await ask("tools/list", 2) as {
      result?: { tools: unknown[] };
      error?: { message: string };
    };
    assertEquals(
      listed.error,
      undefined,
      `the server broke after the handshake: ${listed.error?.message}`,
    );
    assertEquals(listed.result?.tools.length, 7);
  } finally {
    await writer.close();
    reader.releaseLock();
    child.kill();
    await child.status;
    await child.stdout.cancel();
  }
});

Deno.test("an unknown tool is a failed call, not a broken connection", async () => {
  const answer = await call("iphone_data_horoscope");

  assert(answer.isError);
  assertStringIncludes(answer.text, "no such tool");
});

// MARK: - Answers

Deno.test("a daily table takes the daily buckets and leaves the hourly ones", async () => {
  const answer = await call("iphone_data_daily", { since: "2026-01-01", until: "2026-01-02" });

  assertEquals(answer.body.columns[0], "day");
  const steps = answer.body.rows.map((row: unknown[]) => [row[0], row[1]]);
  assertEquals(steps, [["2026-01-01", 8000], ["2026-01-02", 3000]]);
});

Deno.test("a night is whole, merged, and named by the evening it began in", async () => {
  const answer = await call("iphone_data_sleep", { since: "2026-01-01", until: "2026-01-01" });

  assertEquals(answer.body.rows.length, 1);
  assertEquals(answer.body.rows[0].night, "2026-01-01");
  // 22:00 to 06:00 across two day files, with an overlapping stretch inside it.
  assertEquals(answer.body.rows[0].asleepHours, 8);
});

Deno.test("statistics describe readings without handing any of them over", async () => {
  const answer = await call("iphone_data_statistics", {
    metric: "heartRate",
    since: "2026-01-01",
    until: "2026-01-02",
    group_by: "day",
  });

  assertEquals(answer.body.rows.length, 2);
  assertEquals(answer.body.rows[0], {
    group: "2026-01-01",
    n: 2,
    min: 60,
    p10: 62,
    median: 70,
    mean: 70,
    p90: 78,
    max: 80,
    sum: 140,
  });
});

Deno.test("a workout is reported by its activity, and summed by it", async () => {
  const answer = await call("iphone_data_workouts", { since: "2026-01-01", until: "2026-01-02" });

  assertEquals(answer.body.total, 1);
  assertEquals(answer.body.byActivity, { walking: { count: 1, minutes: 30 } });
});

Deno.test("blood oxygen answers carry the warning that its unit is a fraction", async () => {
  const answer = await call("iphone_data_samples", {
    metric: "oxygenSaturation",
    since: "2026-01-01",
    until: "2026-01-02",
  });

  assertStringIncludes(answer.body.unitNote, "0.97 means 97%");
});

// MARK: - Refusals

Deno.test("a malformed day is refused with the correction in the message", async () => {
  const answer = await call("iphone_data_daily", { since: "last tuesday" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "YYYY-MM-DD");
});

Deno.test("a range too long for a daily table is refused, not truncated", async () => {
  // Truncating would answer a question about five years with one about one, and
  // nothing in the answer would say so.
  const answer = await call("iphone_data_daily", { since: "2020-01-01", until: "2026-01-01" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "iphone_data_statistics");
});

Deno.test("a range that runs backwards is refused", async () => {
  const answer = await call("iphone_data_daily", { since: "2026-02-01", until: "2026-01-01" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "after");
});

Deno.test("an unreachable archive still answers, and says that it is behind", async () => {
  // The mirror holds the days; only the check failed. An answer that came back
  // silently would be a stale answer about health data with nothing to mark it.
  const answer = await call("iphone_data_daily", { since: "2026-01-01", until: "2026-01-02" });

  assertStringIncludes(answer.body.warning, "could not be reached");
});

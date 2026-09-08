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
import { base64url, canonicalEdit, fromBase64url, verifyMessage } from "../protocol/signing.ts";
import { open, rawPrivateKey } from "../protocol/sealedbox.ts";
import { editAssociatedData, type EditItem, unpackEdits } from "../protocol/edits.ts";
import { bucketId } from "../protocol/ids.ts";

const home = await Deno.makeTempDir({ prefix: "efferent-mcp-" });
Deno.env.set("EFFERENT_HOME", home);

// Nothing listens on port 9, so every call to the archive fails at once.
const UNREACHABLE = "http://127.0.0.1:9";

/** The reading key the fixture is sealed to, kept so a test can open what the
 * write tool sealed and prove it was sealed to the right key. */
const reading: { privateRaw: Uint8Array; publicRaw: Uint8Array; bucket: string } = {
  privateRaw: new Uint8Array(),
  publicRaw: new Uint8Array(),
  bucket: "",
};

await seedFixture();
// Imported after the home directory is set: the reading layer resolves it once,
// when the module is first evaluated.
const { handle } = await import("./mcp.ts");

async function seedFixture(): Promise<void> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  reading.publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  reading.privateRaw = await rawPrivateKey(pkcs8);
  reading.bucket = await bucketId(reading.publicRaw);
  await Deno.writeTextFile(
    `${home}/reading-key.json`,
    JSON.stringify({
      readingPrivate: base64url(pkcs8),
      readingPublic: base64url(reading.publicRaw),
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
    // Two readings of one metric that do not agree on their fields: the second
    // names no device. A column list written by hand would drop it and nothing
    // would say so, which is what the table is tested against.
    {
      id: "hk:respiratoryRate:1",
      v: 1,
      metric: "respiratoryRate",
      value: 14,
      unit: "count/min",
      source: "a watch",
      start: "2026-01-02T03:00:00Z",
      end: "2026-01-02T03:00:00Z",
    },
    {
      id: "hk:respiratoryRate:2",
      v: 1,
      metric: "respiratoryRate",
      value: 16,
      unit: "count/min",
      start: "2026-01-02T04:00:00Z",
      end: "2026-01-02T04:00:00Z",
    },
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
  assertStringIncludes(answer.result.instructions, "phone_data_overview");
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

  assertEquals(tools.length, 9);
  for (const tool of tools) {
    assert(tool.description.length > 100, `${tool.name} is described too thinly to use unprompted`);
    assert(tool.inputSchema, `${tool.name} has no schema`);
  }
  assertEquals(
    tools.map((tool) => tool.name).sort(),
    [
      "phone_data_daily",
      "phone_data_edits",
      "phone_data_overview",
      "phone_data_samples",
      "phone_data_sleep",
      "phone_data_statistics",
      "phone_data_sync",
      "phone_data_workouts",
      "phone_data_write",
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
    assertEquals(listed.result?.tools.length, 9);
  } finally {
    await writer.close();
    reader.releaseLock();
    child.kill();
    await child.status;
    await child.stdout.cancel();
  }
});

Deno.test("an unknown tool is a failed call, not a broken connection", async () => {
  const answer = await call("phone_data_horoscope");

  assert(answer.isError);
  assertStringIncludes(answer.text, "no such tool");
});

// MARK: - Answers

Deno.test("a daily table takes the daily buckets and leaves the hourly ones", async () => {
  const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });

  assertEquals(answer.body.columns[0], "day");
  const steps = answer.body.rows.map((row: unknown[]) => [row[0], row[1]]);
  assertEquals(steps, [["2026-01-01", 8000], ["2026-01-02", 3000]]);
});

Deno.test("a night is whole, merged, and named by the evening it began in", async () => {
  const answer = await call("phone_data_sleep", { since: "2026-01-01", until: "2026-01-01" });

  assertEquals(answer.body.rows.length, 1);
  assertEquals(answer.body.rows[0].night, "2026-01-01");
  // 22:00 to 06:00 across two day files, with an overlapping stretch inside it.
  assertEquals(answer.body.rows[0].asleepHours, 8);
});

Deno.test("statistics describe readings without handing any of them over", async () => {
  const answer = await call("phone_data_statistics", {
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
  const answer = await call("phone_data_workouts", { since: "2026-01-01", until: "2026-01-02" });

  assertEquals(answer.body.total, 1);
  assertEquals(answer.body.byActivity, { walking: { count: 1, minutes: 30 } });
});

Deno.test("blood oxygen answers carry the warning that its unit is a fraction", async () => {
  const answer = await call("phone_data_samples", {
    metric: "oxygenSaturation",
    since: "2026-01-01",
    until: "2026-01-02",
  });

  assertStringIncludes(answer.body.unitNote, "0.97 means 97%");
});

Deno.test("a daily table answers the metrics an agent can write", async () => {
  // What was written must be readable back through the same tool, or the agent
  // has no way to see that a meal landed.
  const answer = await call("phone_data_daily", {
    metrics: ["dietaryEnergy", "dietaryProtein"],
    since: "2026-01-01",
    until: "2026-01-01",
  });

  assert(!answer.isError, answer.text);
  assertEquals(answer.body.columns, ["day", "dietaryEnergy", "dietaryProtein"]);
});

// MARK: - Writing

/** Run `body` with the archive answered by `service` instead of the network. */
async function withService(
  service: (request: Request) => Response | Promise<Response>,
  body: () => Promise<void>,
): Promise<void> {
  const real = globalThis.fetch;
  globalThis.fetch =
    ((input: RequestInfo | URL, init?: RequestInit) =>
      Promise.resolve(service(new Request(input, init)))) as typeof fetch;
  try {
    await body();
  } finally {
    globalThis.fetch = real;
  }
}

const MEAL: EditItem = {
  op: "put",
  id: "agent:meal:2026-01-01:lunch",
  metric: "dietaryEnergy",
  start: 1_767_268_800,
  end: 1_767_270_600,
  value: 640,
  unit: "kcal",
};
const NAP: EditItem = {
  op: "put",
  id: "agent:sleep:2026-01-01:nap",
  metric: "sleep",
  start: 1_767_276_000,
  end: 1_767_279_600,
  stage: "asleepCore",
};

Deno.test("the overview names what an agent may write, with the unit for each", async () => {
  const answer = await call("phone_data_overview");

  assertEquals(answer.body.writable.dietaryEnergy, { kind: "quantity", unit: "kcal" });
  assertEquals(answer.body.writable.bodyMass, { kind: "quantity", unit: "kg" });
  assertEquals(answer.body.writable.sleep.kind, "category");
  assert(answer.body.writable.sleep.stages.includes("asleepREM"));
});

Deno.test("a handoff from before writing existed cannot write, and says so", async () => {
  const answer = await call("phone_data_write", { items: [MEAL] });

  assert(answer.isError);
  assertStringIncludes(answer.text, "editor key");
});

Deno.test("an item that is wrong is refused before anything is sealed", async () => {
  await seedEditor();
  let posted = false;
  await withService(() => {
    posted = true;
    return new Response("unexpected", { status: 500 });
  }, async () => {
    const answer = await call("phone_data_write", { items: [{ ...MEAL, unit: "kJ" }] });

    assert(answer.isError);
    assertStringIncludes(answer.text, "item 0");
    assertStringIncludes(answer.text, "kcal");
  });
  assertEquals(posted, false, "a bad edit reached the service");
});

Deno.test("an edit is sealed to the reading key, signed by the editor and posted", async () => {
  await seedEditor();
  let taken: { url: URL; headers: Headers; body: Uint8Array } | null = null;
  await withService(async (request) => {
    taken = {
      url: new URL(request.url),
      headers: request.headers,
      body: new Uint8Array(await request.arrayBuffer()),
    };
    return Response.json(
      { name: "1767300000000-abcdefgh", at: "2026-01-01T20:00:00.000Z", bytes: taken.body.length },
      { status: 201 },
    );
  }, async () => {
    const answer = await call("phone_data_write", { items: [MEAL, NAP] });

    assert(!answer.isError, answer.text);
    assertEquals(answer.body.name, "1767300000000-abcdefgh");
    assertEquals(answer.body.items, 2);
    assertStringIncludes(answer.body.note, "phone");
  });

  const { url, headers, body } = taken!;
  assertEquals(url.pathname, `/b/${reading.bucket}/edits`);
  assertEquals(url.origin, UNREACHABLE);

  // Signed by the editor key from the handoff, over the canonical message the
  // service and the phone both check.
  const editor = JSON.parse(await Deno.readTextFile(`${home}/editor-key.json`));
  assertEquals(headers.get("x-efferent-editor"), editor.editorPublic);
  const timestamp = Number(headers.get("x-efferent-timestamp"));
  assert(Math.abs(timestamp - Date.now() / 1000) < 60, "the timestamp is not now");
  assert(
    await verifyMessage(
      fromBase64url(editor.editorPublic),
      fromBase64url(headers.get("x-efferent-signature")!),
      await canonicalEdit(reading.bucket, timestamp, body),
    ),
    "the signature does not verify against the editor key",
  );

  // Sealed to the reading key and bound to the bucket, so the phone and only
  // the phone can open it.
  assertEquals(body[0], 2);
  const items = await unpackEdits(
    await open(reading.privateRaw, reading.publicRaw, body, editAssociatedData(reading.bucket)),
  );
  assertEquals(items, [MEAL, NAP]);

  // And written down locally, so a later session can find the ids to replace.
  const record = JSON.parse(await Deno.readTextFile(`${home}/edits.json`));
  assertEquals(record.length, 1);
  assertEquals(record[0].name, "1767300000000-abcdefgh");
  assertEquals(record[0].items, [
    { op: "put", id: MEAL.id, metric: "dietaryEnergy", day: "2026-01-01" },
    { op: "put", id: NAP.id, metric: "sleep", day: "2026-01-01" },
  ]);
});

Deno.test("the service refusing an edit is a failed call with its sentence", async () => {
  await seedEditor();
  await withService(
    () => Response.json({ error: "no editor is registered for this bucket" }, { status: 403 }),
    async () => {
      const answer = await call("phone_data_write", { items: [MEAL] });

      assert(answer.isError);
      assertStringIncludes(answer.text, "403");
      assertStringIncludes(answer.text, "no editor is registered");
    },
  );
});

Deno.test("edits are listed with the service's status and the local record of what they held", async () => {
  await seedEditor();
  await withService((request) => {
    const url = new URL(request.url);
    // The listing carries counts; the outcome is asked for only where something
    // was refused, and it says which item and why.
    if (url.pathname === `/b/${reading.bucket}/o/1767300000000-abcdefgh`) {
      return Response.json({
        applied: 1,
        refused: [{ item: 1, code: "badRange" }],
        bytes: 300,
        at: "2026-01-01T20:00:00.000Z",
      });
    }
    assertEquals(url.pathname, `/b/${reading.bucket}/edits`);
    assertEquals(url.searchParams.get("status"), "all");
    return Response.json({
      edits: [
        {
          name: "1767300000000-abcdefgh",
          bytes: 300,
          at: "2026-01-01T20:00:00.000Z",
          status: "partial",
          applied: 1,
          refused: 1,
        },
        {
          name: "1767300001000-zzzzzzzz",
          bytes: 200,
          at: "2026-01-01T20:00:01.000Z",
          status: "pending",
        },
      ],
      next: null,
    });
  }, async () => {
    const answer = await call("phone_data_edits", { status: "all" });

    assert(!answer.isError, answer.text);
    assertEquals(answer.body.next, null);
    assertEquals(answer.body.edits.length, 2);
    const [known, unknown] = answer.body.edits;
    assertEquals(known.status, "partial");
    assertEquals(known.applied, 1);
    assertEquals(known.items.map((item: { id: string }) => item.id), [MEAL.id, NAP.id]);
    // The index the phone answered with, turned back into the id the agent used.
    assertEquals(known.refusals, [{ item: 1, code: "badRange", id: NAP.id }]);
    // An edit this profile did not submit — another machine's, or one from
    // before the record existed — is listed as the service knows it.
    assertEquals(unknown.status, "pending");
    assertEquals(unknown.items, undefined);
  });
});

/** The editor key a four-field handoff would have installed. */
async function seedEditor(): Promise<void> {
  try {
    await Deno.lstat(`${home}/editor-key.json`);
    return;
  } catch {
    // not yet
  }
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  await Deno.writeTextFile(
    `${home}/editor-key.json`,
    JSON.stringify({
      editorPrivate: base64url(
        new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      ),
      editorPublic: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
    }),
  );
}

// MARK: - Refusals

Deno.test("a malformed day is refused with the correction in the message", async () => {
  const answer = await call("phone_data_daily", { since: "last tuesday" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "YYYY-MM-DD");
});

Deno.test("a range too long for a daily table is refused, not truncated", async () => {
  // Truncating would answer a question about five years with one about one, and
  // nothing in the answer would say so.
  const answer = await call("phone_data_daily", { since: "2020-01-01", until: "2026-01-01" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "phone_data_statistics");
});

Deno.test("a range that runs backwards is refused", async () => {
  const answer = await call("phone_data_daily", { since: "2026-02-01", until: "2026-01-01" });

  assert(answer.isError);
  assertStringIncludes(answer.text, "after");
});

Deno.test("an unreachable archive still answers, and says that it is behind", async () => {
  // The mirror holds the days; only the check failed. An answer that came back
  // silently would be a stale answer about health data with nothing to mark it.
  const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });

  assertStringIncludes(answer.body.warning, "could not be reached");
});

// MARK: - The shape an answer travels in

Deno.test("readings come as a table, with what they agree on said once", async () => {
  const answer = await call("phone_data_samples", {
    metric: "heartRate",
    since: "2026-01-01",
    until: "2026-01-02",
  });

  assertEquals(answer.body.sameOnEveryRow, { unit: "count/min", v: 1 });
  assertEquals(answer.body.columns, ["start", "end", "value"]);
  assertEquals(answer.body.rows, [
    ["2026-01-01T09:00:00Z", "2026-01-01T09:00:00Z", 60],
    ["2026-01-01T10:00:00Z", "2026-01-01T10:00:00Z", 80],
    ["2026-01-02T09:00:00Z", "2026-01-02T09:00:00Z", 70],
  ]);
});

Deno.test("a field only some readings carry becomes a column, never a dropped one", async () => {
  const answer = await call("phone_data_samples", {
    metric: "respiratoryRate",
    since: "2026-01-02",
    until: "2026-01-02",
  });

  // The whole point: `source` is on one reading and not the other, so it cannot
  // be said once — and it must not vanish either. A null is the reading that
  // named no device, which is not the same as a device called nothing.
  assert(answer.body.columns.includes("source"), "a field one reading carried was dropped");
  assertEquals(answer.body.sameOnEveryRow.source, undefined);
  const source = answer.body.columns.indexOf("source");
  assertEquals(answer.body.rows.map((row: unknown[]) => row[source]), ["a watch", null]);
});

Deno.test("the derived identifier is not carried, and nothing else is lost", async () => {
  const answer = await call("phone_data_samples", {
    metric: "heartRate",
    since: "2026-01-01",
    until: "2026-01-01",
  });

  const carried = new Set([...answer.body.columns, ...Object.keys(answer.body.sameOnEveryRow)]);
  assertEquals(carried.has("id"), false, "the identifier came back after all");
  // Everything the event held apart from the id and the metric named above it.
  for (const field of ["v", "start", "end", "value", "unit"]) {
    assert(carried.has(field), `${field} left the answer with the identifier`);
  }
});

Deno.test("workouts come as a table too, and the counts are over all of them", async () => {
  const answer = await call("phone_data_workouts", { since: "2026-01-01", until: "2026-01-02" });

  // One workout is one row, and a single row keeps every field in its columns:
  // there is nothing to say once, and an answer whose only row came back empty
  // would be a worse trade than the repetition it saved.
  assertEquals(answer.body.sameOnEveryRow, {});
  const activity = answer.body.columns.indexOf("activity");
  assert(activity >= 0, "a workout no longer says what it was");
  assertEquals(answer.body.rows.length, 1);
  assertEquals(answer.body.rows[0][activity], "walking");
  assertEquals(answer.body.byActivity, { walking: { count: 1, minutes: 30 } });
});

Deno.test("an answer is written without indentation", async () => {
  const answer = await call("phone_data_daily", { since: "2026-01-01", until: "2026-01-02" });

  // Nothing but a model reads this, and it pays for every character. The spaces
  // were a fifth of every answer this server sent.
  assertEquals(answer.text.includes("\n "), false, "the answer came back laid out");
  assertEquals(answer.text.includes("\n"), false);
});

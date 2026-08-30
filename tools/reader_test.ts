/**
 * The reading side against an archive that answers.
 *
 * `mcp_test.ts` points its fixture at an address nothing listens on, which is
 * the right shape for the questions it asks and leaves half the reader untested:
 * everything that happens when the archive *does* answer — the listing walk, the
 * windowed fetch, the mirror being brought up to date, and the two tools whose
 * whole job is that. None of it had a test, and all of it is where a change goes
 * wrong quietly: a walk that returns the pages that arrived reports the rest of
 * an archive as nothing at all, a fetch that loses its order hands a stream of
 * days back shuffled, and a mirror that records a day it failed to fetch never
 * asks for it again.
 *
 * So the fixture here is a real archive: an HTTP service that seals days with
 * the reading key the way the phone does, pages its listing the way R2 forces
 * the real one to, and can be told to fail a named day or a named page. The
 * reader meets it as a subprocess — the MCP server over JSON-RPC, the command
 * line tool over stdout — because the reading layer resolves its home once, when
 * its module is first evaluated, and one process cannot hold two homes.
 */

import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { base64url } from "../protocol/signing.ts";
import { bucketId } from "../protocol/ids.ts";
import { associatedData, seal } from "../protocol/sealedbox.ts";
import { compress } from "../protocol/framing.ts";
import { pack } from "../protocol/day.ts";

/** Days per listing page. Small on purpose: the walk past a page boundary is
 * the part being tested, and the real ceiling of 1000 would never reach it. */
const PAGE = 2;
/** How long the archive holds a day open. Long enough that a window of fetches
 * overlaps in the request log, which is what makes the count of them mean
 * something. */
const DAY_DELAY_MS = 25;

// MARK: - An archive that answers

interface Fault {
  /** A day the archive refuses, however often it is asked. */
  day?: string;
  /** The listing page, counted from zero, the archive refuses. */
  page?: number;
}

class FakeArchive {
  readonly days = new Map<string, { blob: Uint8Array; uploaded: string }>();
  /** Every path asked for, in the order it was asked. */
  readonly asked: string[] = [];
  /** The most days ever open at once, which is the fetch window as observed. */
  maxInFlight = 0;
  fault: Fault = {};

  private inFlight = 0;
  private server!: Deno.HttpServer;
  private readingPublic!: Uint8Array;
  bucket!: string;
  url!: string;

  static async start(readingPublic: Uint8Array): Promise<FakeArchive> {
    const archive = new FakeArchive();
    archive.readingPublic = readingPublic;
    archive.bucket = await bucketId(readingPublic);
    archive.server = Deno.serve(
      { hostname: "127.0.0.1", port: 0, onListen: () => {} },
      (request) => archive.answer(request),
    );
    archive.url = `http://127.0.0.1:${(archive.server.addr as Deno.NetAddr).port}`;
    return archive;
  }

  /** Put a day in, or replace one. A replacement gets a later upload time, which
   * is the only thing that tells a mirror its copy is old. */
  async put(day: string, events: Record<string, unknown>[]): Promise<void> {
    const body = new TextEncoder().encode(pack(events as never));
    const blob = await seal(
      this.readingPublic,
      await compress(body),
      associatedData(this.bucket, day),
    );
    const previous = this.days.get(day);
    this.days.set(day, {
      blob,
      uploaded: previous
        ? new Date(Date.parse(previous.uploaded) + 1000).toISOString()
        : "2026-01-01T00:00:00.000Z",
    });
  }

  /** What the reader asked for, forgotten. Called between the halves of a test
   * so a count means "since then" rather than "ever". */
  forget(): void {
    this.asked.length = 0;
    this.maxInFlight = 0;
  }

  fetchedDays(): string[] {
    return this.asked
      .filter((path) => path.includes("/d/"))
      .map((path) => path.slice(path.lastIndexOf("/") + 1));
  }

  listings(): number {
    return this.asked.filter((path) => path.includes("/days")).length;
  }

  async stop(): Promise<void> {
    await this.server.shutdown();
  }

  private async answer(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.asked.push(url.pathname + url.search);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] !== "b" || parts[1] !== this.bucket) return json({ error: "unknown" }, 404);

    if (parts[2] === "stats") return json(this.stats());
    if (parts[2] === "days") return this.list(url);
    if (parts[2] === "d") return await this.day(parts[3]);
    return json({ error: "unknown" }, 405);
  }

  private stats() {
    const names = [...this.days.keys()].sort();
    let bytes = 0;
    for (const day of this.days.values()) bytes += day.blob.length;
    return {
      exists: true,
      days: names.length,
      bytes,
      firstDay: names[0] ?? null,
      lastDay: names[names.length - 1] ?? null,
      complete: true,
    };
  }

  /** Paged the way R2 forces the real one to be: `after` skips past a key, and
   * `next` is null only at the end. */
  private list(url: URL): Response {
    const after = url.searchParams.get("after");
    const from = url.searchParams.get("from");
    const to = url.searchParams.get("to");

    const start = after ?? (from ? previousDay(from) : null);
    let names = [...this.days.keys()].sort().filter((day) => !start || day > start);
    const truncated = names.length > PAGE;
    names = names.slice(0, PAGE);
    const within = to ? names.filter((day) => day <= to) : names;
    const reachedEnd = within.length < names.length;

    // The page number the reader is on, counted by how many it has already
    // walked. It cannot send one, so the fault is matched on the listing count.
    if (this.fault.page !== undefined && this.listings() - 1 === this.fault.page) {
      return json({ error: "the listing broke" }, 500);
    }

    return json({
      days: within.map((day) => ({
        day,
        bytes: this.days.get(day)!.blob.length,
        uploaded: this.days.get(day)!.uploaded,
      })),
      next: !reachedEnd && truncated && within.length > 0 ? within[within.length - 1] : null,
    });
  }

  private async day(name: string): Promise<Response> {
    this.inFlight++;
    this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
    try {
      await new Promise((resume) => setTimeout(resume, DAY_DELAY_MS));
      if (this.fault.day === name) return json({ error: `${name} is refused` }, 500);
      const stored = this.days.get(name);
      if (!stored) return json({ error: "no such day" }, 404);
      return new Response(stored.blob as BodyInit, {
        headers: { "content-type": "application/octet-stream" },
      });
    } finally {
      this.inFlight--;
    }
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function previousDay(day: string): string {
  return addDays(day, -1);
}

/** Kept local rather than imported: `analysis.ts` would drag the reading layer
 * into this process, and its home is not this test's to set. */
function addDays(day: string, count: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

// MARK: - A reader, with its own home

/** A temporary home holding the reading key and an archive to point at. */
async function readerHome(): Promise<{ home: string; readingPublic: Uint8Array }> {
  const home = await Deno.makeTempDir({ prefix: "efferent-reader-" });
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, [
    "deriveBits",
  ]) as CryptoKeyPair;
  const readingPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  await Deno.writeTextFile(
    `${home}/reading-key.json`,
    JSON.stringify({
      readingPrivate: base64url(
        new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
      ),
      readingPublic: base64url(readingPublic),
    }),
  );
  return { home, readingPublic };
}

/** Everything a test needs: a home, an archive that answers, and the days in it
 * already sealed. Torn down by `close`. */
async function fixture(
  seed: (archive: FakeArchive) => Promise<void>,
): Promise<{ home: string; archive: FakeArchive; close: () => Promise<void> }> {
  const { home, readingPublic } = await readerHome();
  const archive = await FakeArchive.start(readingPublic);
  await seed(archive);
  await Deno.writeTextFile(
    `${home}/mirror.json`,
    JSON.stringify({ endpoint: archive.url, days: {}, syncedAt: "" }),
  );
  return {
    home,
    archive,
    close: async () => {
      // A test may have stopped the archive itself, to see the reader meet one
      // that has gone away. Shutting it down twice is not an error worth having.
      await archive.stop().catch(() => {});
      await Deno.remove(home, { recursive: true });
    },
  };
}

/** The MCP server as the agent meets it: a process, spoken to over stdio. */
class Session {
  private child: Deno.ChildProcess;
  private writer: WritableStreamDefaultWriter<Uint8Array>;
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private buffer = "";
  private id = 0;

  constructor(home: string) {
    this.child = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", new URL("./mcp.ts", import.meta.url).pathname],
      stdin: "piped",
      stdout: "piped",
      stderr: "null",
      env: { EFFERENT_HOME: home },
    }).spawn();
    this.writer = this.child.stdin.getWriter();
    this.reader = this.child.stdout.getReader();
  }

  // deno-lint-ignore no-explicit-any
  async rpc(method: string, params?: Record<string, unknown>): Promise<any> {
    this.id++;
    await this.writer.write(
      new TextEncoder().encode(
        JSON.stringify({ jsonrpc: "2.0", id: this.id, method, params }) + "\n",
      ),
    );
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline >= 0) {
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        return JSON.parse(line);
      }
      const { value, done } = await this.reader.read();
      if (done) throw new Error("the server closed before answering");
      this.buffer += new TextDecoder().decode(value, { stream: true });
    }
  }

  /** A tool call, with the JSON of its single text block already parsed. */
  // deno-lint-ignore no-explicit-any
  async call(name: string, args: Record<string, unknown> = {}): Promise<any> {
    const answer = await this.rpc("tools/call", { name, arguments: args });
    const text = answer.result.content[0].text;
    return { isError: answer.result.isError === true, text, body: JSON.parse(text) };
  }

  async close(): Promise<void> {
    await this.writer.close();
    this.reader.releaseLock();
    this.child.kill();
    await this.child.status;
    await this.child.stdout.cancel();
  }
}

/** The command line tool, run to completion. */
async function cli(
  home: string,
  args: string[],
): Promise<{ code: number; out: string; err: string }> {
  const result = await new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", new URL("./efferent.ts", import.meta.url).pathname, ...args],
    env: { EFFERENT_HOME: home },
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: result.code,
    out: new TextDecoder().decode(result.stdout),
    err: new TextDecoder().decode(result.stderr),
  };
}

// MARK: - Days to put in an archive

function total(metric: string, on: string, value: number) {
  return {
    metric,
    bucket: "day",
    value,
    unit: "count",
    start: `${on}T00:00:00Z`,
    end: `${on}T23:59:59Z`,
  };
}

function record(metric: string, at: string, value: number) {
  return { metric, value, unit: "count/min", source: "a watch", start: at, end: at };
}

/** Days named from a start, one total each, so a day is identifiable by its
 * value alone. */
async function seedRun(archive: FakeArchive, from: string, count: number): Promise<string[]> {
  const days: string[] = [];
  let day = from;
  for (let index = 0; index < count; index++) {
    await archive.put(day, [total("steps", day, 1000 + index)]);
    days.push(day);
    const next = new Date(`${day}T00:00:00Z`);
    next.setUTCDate(next.getUTCDate() + 1);
    day = next.toISOString().slice(0, 10);
  }
  return days;
}

function mirroredState(home: string): { days: Record<string, string> } {
  return JSON.parse(Deno.readTextFileSync(`${home}/mirror.json`));
}

function mirroredFiles(home: string): string[] {
  try {
    return [...Deno.readDirSync(`${home}/days`)]
      .filter((entry) => entry.isFile && entry.name.endsWith(".ndjson"))
      .map((entry) => entry.name.replace(/\.ndjson$/, ""))
      .sort();
  } catch {
    return [];
  }
}

// MARK: - The listing walk

Deno.test("a listing is walked past its own page size, not stopped at the first one", async () => {
  const { home, archive, close } = await fixture((a) => seedRun(a, "2026-03-01", 7).then(() => {}));
  try {
    const run = await cli(home, ["sync", "--url", archive.url]);
    assertEquals(run.code, 0, run.err);
    // Seven days at two per page is four requests: three full and the last.
    assert(archive.listings() >= 4, `walked only ${archive.listings()} pages`);
    assertEquals(mirroredFiles(home).length, 7);
  } finally {
    await close();
  }
});

Deno.test("a listing that breaks part way through throws rather than answering short", async () => {
  const { home, archive, close } = await fixture((a) => seedRun(a, "2026-03-01", 7).then(() => {}));
  try {
    // The stats call comes first and is not a listing, so page 1 is the second
    // page of the walk — far enough in that a short answer would look plausible.
    archive.fault = { page: 1 };
    const run = await cli(home, ["sync", "--url", archive.url]);

    assert(run.code !== 0, "a broken listing was reported as a finished sync");
    assertStringIncludes(run.err, "500");
    // The whole point: nothing was recorded as mirrored on the strength of a
    // walk that never finished.
    assertEquals(mirroredState(home).days, {});
  } finally {
    await close();
  }
});

// MARK: - The windowed fetch

Deno.test("days come back in the order they were asked for", async () => {
  const { home, archive, close } = await fixture((a) =>
    seedRun(a, "2026-03-01", 20).then(() => {})
  );
  try {
    const run = await cli(home, ["read", "--url", archive.url]);
    assertEquals(run.code, 0, run.err);

    const days = run.out.trim().split("\n").map((line) => JSON.parse(line).start.slice(0, 10));
    assertEquals(days.length, 20);
    assertEquals(
      days,
      [...days].sort(),
      "the stream of days came back out of order; a reader of it cannot tell",
    );
  } finally {
    await close();
  }
});

Deno.test("a day the archive refuses stops the fetch instead of being skipped", async () => {
  const { home, archive, close } = await fixture((a) =>
    seedRun(a, "2026-03-01", 20).then(() => {})
  );
  try {
    archive.fault = { day: "2026-03-11" };
    const run = await cli(home, ["sync", "--url", archive.url]);

    assert(run.code !== 0, "a refused day was reported as a finished sync");
    assertStringIncludes(run.err, "2026-03-11");
    // A day that never arrived must not be recorded as mirrored: nothing would
    // ever ask for it again.
    assertEquals(mirroredState(home).days["2026-03-11"], undefined);
  } finally {
    await close();
  }
});

Deno.test("no more than one window of days is ever in the air at once", async () => {
  const { home, archive, close } = await fixture((a) =>
    seedRun(a, "2026-03-01", 40).then(() => {})
  );
  try {
    const run = await cli(home, ["sync", "--url", archive.url]);
    assertEquals(run.code, 0, run.err);

    assert(archive.maxInFlight > 1, "the days were fetched one at a time");
    assert(
      archive.maxInFlight <= 8,
      `${archive.maxInFlight} days were open at once, which is more than the window`,
    );
    assertEquals(mirroredFiles(home).length, 40);
  } finally {
    await close();
  }
});

// MARK: - Bringing the mirror up to date

Deno.test("a first question copies the archive down and answers from it", async () => {
  const { home, close } = await fixture(async (a) => {
    await a.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
    await a.put("2026-03-02", [total("steps", "2026-03-02", 3000)]);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    const answer = await session.call("phone_data_daily", {
      since: "2026-03-01",
      until: "2026-03-02",
    });

    assertEquals(answer.body.warning, undefined);
    assertEquals(answer.body.rows.length, 2);
    assertEquals(answer.body.rows[0][0], "2026-03-01");
    assertEquals(mirroredFiles(home), ["2026-03-01", "2026-03-02"]);
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("a rewritten day inside the fortnight is copied by an ordinary question", async () => {
  const recent = addDays(new Date().toISOString().slice(0, 10), -3);
  const { home, archive, close } = await fixture(async (a) => {
    await a.put(recent, [total("steps", recent, 1000)]);
  });
  try {
    const first = new Session(home);
    try {
      await first.rpc("initialize", { protocolVersion: "2025-06-18" });
      await first.call("phone_data_sync");
    } finally {
      await first.close();
    }

    // The ordinary case in this design: the phone re-read a day and put it up
    // again, under a later upload time. Inside the fortnight the recent listing
    // is what notices, so no sync is needed — but the freshness window is, so a
    // second process is what asks.
    await archive.put(recent, [total("steps", recent, 99_999)]);

    const later = new Session(home);
    try {
      await later.rpc("initialize", { protocolVersion: "2025-06-18" });
      const answer = await later.call("phone_data_daily", { since: recent, until: recent });
      assertEquals(answer.body.rows[0][1], 99_999);
    } finally {
      await later.close();
    }
  } finally {
    await close();
  }
});

Deno.test("a day older than the fortnight, rewritten, is still copied by a sync", async () => {
  // Neither cheap check reaches this day: the recent listing does not cover it
  // and the archive's day count has not moved. Before the forced check read the
  // whole listing, the mirror answered from its old copy for good.
  const { home, archive, close } = await fixture(async (a) => {
    await seedRun(a, "2026-03-01", 5);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    await session.call("phone_data_sync");
    assertEquals(mirroredFiles(home).length, 5);

    await archive.put("2026-03-03", [total("steps", "2026-03-03", 99_999)]);
    archive.forget();
    await session.call("phone_data_sync");

    assertEquals(
      archive.fetchedDays(),
      ["2026-03-03"],
      "a sync fetched days whose stored version had not moved",
    );
    const answer = await session.call("phone_data_daily", {
      since: "2026-03-03",
      until: "2026-03-03",
    });
    assertEquals(answer.body.rows[0][1], 99_999);
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("a mirror already level with the archive fetches nothing", async () => {
  const { home, archive, close } = await fixture(async (a) => {
    await seedRun(a, "2026-03-01", 5);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    await session.call("phone_data_sync");
    archive.forget();

    await session.call("phone_data_daily", { since: "2026-03-01", until: "2026-03-05" });
    assertEquals(archive.fetchedDays(), []);
    // Inside the freshness window a second question costs no round trip at all.
    assertEquals(archive.asked, []);
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("a sync asks the archive even inside the freshness window", async () => {
  const { home, archive, close } = await fixture(async (a) => {
    await a.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    await session.call("phone_data_sync");
    archive.forget();

    await session.call("phone_data_sync");
    assert(
      archive.asked.length > 0,
      "a sync answered from a window it exists to ignore",
    );
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("history arriving outside the recent fortnight is still noticed", async () => {
  const today = new Date().toISOString().slice(0, 10);
  const { home, archive, close } = await fixture(async (a) => {
    await a.put(today, [total("steps", today, 8000)]);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    await session.call("phone_data_sync");

    // A decade-old day the fortnight listing cannot see. Only the day count
    // says the mirror is behind, which is the fall-through being tested.
    await archive.put("2016-01-05", [total("steps", "2016-01-05", 4242)]);
    await session.call("phone_data_sync");

    assert(
      mirroredFiles(home).includes("2016-01-05"),
      "a day older than the recent listing never reached the mirror",
    );
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("a sync that breaks part way says so and records only what arrived", async () => {
  const { home, archive, close } = await fixture(async (a) => {
    await seedRun(a, "2026-03-01", 12);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    archive.fault = { day: "2026-03-07" };
    const answer = await session.call("phone_data_daily", {
      since: "2026-03-01",
      until: "2026-03-12",
    });

    assertStringIncludes(answer.body.warning, "could not be brought up to date");
    assertEquals(
      mirroredState(home).days["2026-03-07"],
      undefined,
      "a day that never arrived was recorded as mirrored, so nothing will ask for it again",
    );
  } finally {
    await session.close();
    await close();
  }
});

// MARK: - The two tools that had none

Deno.test("the overview reports the archive, the readable part, and every metric", async () => {
  const { home, close } = await fixture(async (a) => {
    await a.put("2026-03-01", [
      total("steps", "2026-03-01", 8000),
      record("heartRate", "2026-03-01T09:00:00Z", 60),
      record("heartRate", "2026-03-01T10:00:00Z", 80),
    ]);
    await a.put("2026-03-02", [total("steps", "2026-03-02", 3000)]);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    const answer = await session.call("phone_data_overview");

    assertEquals(answer.body.archive.days, 2);
    assertEquals(answer.body.archive.firstDay, "2026-03-01");
    assertEquals(answer.body.readable.days, 2);
    assertStringIncludes(answer.body.readable.note, "the whole archive is readable");

    const metrics = Object.fromEntries(
      // deno-lint-ignore no-explicit-any
      answer.body.metrics.map((entry: any) => [entry.metric, entry]),
    );
    assertEquals(metrics.steps.kind, "total");
    assertEquals(metrics.steps.daysCovered, 2);
    assertEquals(metrics.heartRate.kind, "record");
    assertEquals(metrics.heartRate.events, 2);
    assertEquals(metrics.heartRate.firstDay, "2026-03-01");
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("the overview answers from the mirror when the archive has gone away", async () => {
  const { home, archive, close } = await fixture(async (a) => {
    await a.put("2026-03-01", [total("steps", "2026-03-01", 8000)]);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    await session.call("phone_data_sync");
    await archive.stop();

    const answer = await session.call("phone_data_overview");
    assertStringIncludes(answer.body.warning, "could not be reached");
    assertEquals(answer.body.archive, "unreachable");
    assertEquals(answer.body.readable.days, 1);
    assertEquals(answer.body.metrics.length, 1);
  } finally {
    await session.close();
    await close();
  }
});

Deno.test("a sync reports what it copied and what is readable afterwards", async () => {
  const { home, close } = await fixture(async (a) => {
    await seedRun(a, "2026-03-01", 6);
  });
  const session = new Session(home);
  try {
    await session.rpc("initialize", { protocolVersion: "2025-06-18" });
    const first = await session.call("phone_data_sync");

    assertEquals(first.body.copied, 6);
    assertEquals(first.body.readable, 6);
    assertEquals(first.body.firstDay, "2026-03-01");
    assertEquals(first.body.lastDay, "2026-03-06");

    const again = await session.call("phone_data_sync");
    assertEquals(again.body.copied, 0, "a second sync copied days that had not changed");
    assertEquals(again.body.readable, 6);
  } finally {
    await session.close();
    await close();
  }
});

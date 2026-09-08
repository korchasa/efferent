/**
 * The service's R2, rate limits and writer, all in memory — shared by every
 * test file under `server/`.
 */

import type worker from "./src/index.ts";
import { signingKeyObject } from "../protocol/ids.ts";
import { base64url, fromBase64url } from "../protocol/signing.ts";

/** Made up here, and derived from no key: an id is the only thing between a
 * stranger and the ciphertext, so a real one is never written down. */
export const BUCKET = "abucketidmadeupforthistest";

export class MemoryBucket {
  readonly store = new Map<
    string,
    { body: Uint8Array; uploaded: Date; version: number; customMetadata?: Record<string, string> }
  >();
  /** Somebody else's write, slipped in just before the next conditional one.
   * It is how a race is reproduced without threads: the competing write lands
   * between the read and the write that is about to be refused for it. */
  competitor?: (key: string) => void;
  /** Distinct write times without a clock: a day written later must be
   * distinguishable from one written earlier, and a test that ran fast enough
   * would otherwise stamp both the same. */
  private writes = 0;

  private object(key: string) {
    const stored = this.store.get(key)!;
    return {
      key,
      size: stored.body.length,
      uploaded: stored.uploaded,
      etag: `${stored.version}`,
      httpEtag: `"${stored.version}"`,
      customMetadata: stored.customMetadata ?? {},
      body: new Blob([stored.body.slice().buffer]).stream(),
      // deno-lint-ignore require-await
      arrayBuffer: async () => stored.body.buffer.slice(0) as ArrayBuffer,
      // deno-lint-ignore require-await
      text: async () => new TextDecoder().decode(stored.body),
    };
  }

  // deno-lint-ignore require-await
  async head(key: string) {
    return this.store.has(key) ? this.object(key) : null;
  }

  // deno-lint-ignore require-await
  async get(key: string) {
    return this.store.has(key) ? this.object(key) : null;
  }

  // deno-lint-ignore require-await
  async put(
    key: string,
    value: ArrayBuffer | Uint8Array | string,
    options?: { onlyIf?: Headers; customMetadata?: Record<string, string> },
  ) {
    const competitor = this.competitor;
    if (competitor && options?.onlyIf) {
      this.competitor = undefined;
      competitor(key);
    }
    // Real R2 answers a failed condition with null and stores nothing, which is
    // the whole point of the retry the caller is written around.
    const only = options?.onlyIf;
    if (only) {
      const held = this.store.get(key);
      const ifMatch = only.get("if-match");
      const ifNoneMatch = only.get("if-none-match");
      if (ifNoneMatch === "*" && held) return null;
      if (ifMatch && (!held || `"${held.version}"` !== ifMatch)) return null;
    }
    this.store.set(key, {
      // Copied, and copied *within the view's bounds*: a day out of a batch is a
      // window onto the request body, and keeping the window would store the
      // whole batch under one day's name. Real R2 respects the bounds, so a
      // stand-in that did not would pass tests the service cannot.
      body: typeof value === "string"
        ? new TextEncoder().encode(value)
        : value instanceof Uint8Array
        ? value.slice()
        : new Uint8Array(value),
      uploaded: new Date(1_760_000_000_000 + this.writes++ * 1000),
      version: (this.store.get(key)?.version ?? 0) + 1,
      customMetadata: options?.customMetadata,
    });
    return this.object(key);
  }

  // deno-lint-ignore require-await
  async delete(key: string) {
    // Real R2 says nothing about a key that was not there, and so does this.
    this.store.delete(key);
  }

  /**
   * A listing, with the two behaviours the service actually leans on.
   *
   * The limit is a limit on what is *read*, not on what comes back. That is the
   * part worth copying faithfully: a rolled-up listing gathers its prefixes from
   * the objects it happened to scan, so it can answer four years out of twelve
   * and say it is truncated, and code that took that page for the whole answer
   * would lose the rest of the archive without an error. Measured against real
   * R2 on 2026-09-05: twelve years came back as two pages.
   */
  // deno-lint-ignore require-await
  async list(
    options: {
      prefix?: string;
      startAfter?: string;
      limit?: number;
      delimiter?: string;
      cursor?: string;
    },
  ) {
    const prefix = options.prefix ?? "";
    const from = options.cursor ?? options.startAfter;
    const keys = [...this.store.keys()]
      .filter((key) => key.startsWith(prefix))
      .filter((key) => !from || key > from)
      .sort();

    const limit = options.limit ?? 1000;
    const scanned = keys.slice(0, limit);
    const truncated = keys.length > scanned.length;

    // A delimiter rolls up every scanned key that holds one after the prefix
    // into the stretch ending at its first occurrence; such a key is then not an
    // object of its own.
    const objects: string[] = [];
    const delimitedPrefixes: string[] = [];
    for (const key of scanned) {
      const at = options.delimiter ? key.indexOf(options.delimiter, prefix.length) : -1;
      if (at < 0) {
        objects.push(key);
        continue;
      }
      const delimited = key.slice(0, at + options.delimiter!.length);
      if (!delimitedPrefixes.includes(delimited)) delimitedPrefixes.push(delimited);
    }

    return {
      objects: objects.map((key) => this.object(key)),
      delimitedPrefixes,
      truncated,
      cursor: truncated ? scanned[scanned.length - 1] : undefined,
    };
  }
}

export async function writerKey() {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    publicKey: base64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
  };
}

/**
 * A count that says yes, until a test says otherwise.
 *
 * Every test that is about something else has to get past it, so the default
 * answer is the permissive one; `answer = false` is how a test asks what
 * happens to a caller going too fast.
 */
export class MemoryLimiter {
  answer = true;
  readonly keys: string[] = [];

  // deno-lint-ignore require-await
  async limit({ key }: { key: string }) {
    this.keys.push(key);
    return { success: this.answer };
  }
}

export type Writer = { privateKey: CryptoKey; publicKey: string };
export type Environment = {
  BLOBS: MemoryBucket;
  CLAIMS: MemoryLimiter;
  WRITES: MemoryLimiter;
  EDITS: MemoryLimiter;
  APP_ID: string;
};

/** The worker only ever touches the parts of R2 its interface names. */
export function bindings(env: Environment): Parameters<typeof worker.fetch>[1] {
  return env as unknown as Parameters<typeof worker.fetch>[1];
}

export function environment(): Environment {
  return {
    BLOBS: new MemoryBucket(),
    CLAIMS: new MemoryLimiter(),
    WRITES: new MemoryLimiter(),
    EDITS: new MemoryLimiter(),
    APP_ID: "ABCDE12345.dev.korchasa.efferent",
  };
}

export function executionContext(): ExecutionContext {
  return {
    waitUntil() {},
    passThroughOnException() {},
    props: {},
  } as unknown as ExecutionContext;
}

/**
 * A bucket this writer has already claimed.
 *
 * The claim itself cannot be made here: it needs an attestation signed under
 * Apple's own root, which nobody outside Apple can produce. What the claim
 * leaves behind is one object, so a test about uploading writes that object
 * and starts where a real phone would be.
 */
export function owned(env: Environment, writer: Writer): void {
  env.BLOBS.store.set(signingKeyObject(BUCKET), {
    body: fromBase64url(writer.publicKey),
    uploaded: new Date(),
    version: 1,
  });
}

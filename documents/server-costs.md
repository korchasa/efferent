# Server cost per user

Estimate date: **2026-09-06**, replacing the 2026-08-27 one, which was taken before every write path
got a ceiling and therefore counted neither the two tally objects each upload now touches nor the
listing pages of the daily archive walk. Currency: US dollars. This is a marginal-cost model for the
current Cloudflare Worker and R2 design, before tax. It is not an invoice. Rates come from
Cloudflare's [R2 pricing](https://developers.cloudflare.com/r2/pricing/) and
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/): Standard R2 is
$0.015 per GB-month, Class A is $4.50 per million, Class B is $0.36 per million, Workers Paid is $5
a month with 10 million requests included, and further requests are $0.30 per million.

## Measured archive

The owner's live archive is the reference workload:

- 3,914 days, 2015-12-12 through 2026-08-29;
- 37,310,352 bytes of ciphertext, about 9.5 KB per stored day;
- 0.0373 decimal GB, so **$0.00056 per user-month** of storage.

## What one request costs in operations

A day is its own R2 object, and the ceilings are two more. So an upload of *n* days is:

- *n* + 2 Class A writes — the days, then the bucket's tally and the service's;
- 3 Class B reads — the registered signing key, then both tallies;
- 1 Worker request.

The daily archive walk is separate and cheaper than it looks in requests but not in class: an R2
`list` is a Class A operation, and the walk over this archive takes **6 pages**, so 6 Class A and 6
Worker requests once a day.

## Per user, per month

- **Sending once a day**, two days per request: 300 Class A, 90 Class B, 210 Worker requests →
  about **$0.0020 per user-month**.
- **Sending every hour**, the current day rewritten each time: 2,340 Class A, 2,160 Class B, 900
  Worker requests → about **$0.0121 per user-month**.

Class A dominates both, and the tally writes are two thirds of it in the hourly case — the price of
knowing what the service has been handed.

## One-time

The first eleven-year export is 127 requests of 31 days each: 4,168 Class A, 381 Class B →
about **$0.019 per user**, paid once. A full download into a fresh local mirror is about $0.003 per
user; R2 egress is free, so it is one Class B read and one Worker request per day.

## Where the free allowances end

- 10 GB of R2 storage holds about **268** archives of this size. This is the first ceiling reached.
- 1 million Class A a month covers about **3,300** users sending daily, or about **430** sending
  hourly.
- 100,000 Worker requests a day covers about **14,000** users sending daily, or about **3,300**
  hourly.

At 10,000 hourly users the whole bill is about **$115 a month** — $101 of it Class A, $5.45 storage,
$4.18 Class B and the $5 Workers Paid subscription — which is $0.0115 per user, the marginal figure
again.

## Two ceilings that bind before the money does

Both counters in `server/src/index.ts` count **bytes handed over**, for the life of the counter, and
never come down when data is replaced. That makes them budgets rather than sizes:

- `MAX_BUCKET_BYTES` is 512 MiB. A user sending once a day spends it in about 73 years, which is
  never. A user whose phone rewrites the current day every hour spends about 6.9 MB a month and
  reaches it about **6 years** after the first import — and is then refused every further upload
  while holding an archive of 40 MB. Whatever the service ends up charging, this is the number that
  decides how long a paying user can keep sending.
- `MAX_SERVICE_BYTES` is 100 GiB against a baseline of 153 MB already taken, which is about **2,870**
  first imports. It is a lifetime figure for the whole service, so it has to be raised long before
  that many people arrive, not when they do.

Recalculate when prices, batch size, the archive's size, the walk's page count or either ceiling
changes.

# Server cost per user

Estimate date: **2026-08-27**. Currency: US dollars. This is a marginal-cost model for the current
Cloudflare Worker and R2 design, before tax and without a paid Workers minimum. It is not an invoice.
Rates come from Cloudflare's current [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
and [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/): Standard R2 is
$0.015 per GB-month, Class A is $4.50 per million, Class B is $0.36 per million, and excess Worker
requests are $0.30 per million.

## Measured archive

The owner's live archive was used as the reference workload:

- 3,912 days, from 2015-12-12 through 2026-08-27;
- 35.5 MiB of ciphertext;
- about 9.29 KiB per stored day.

At that density one user adds about 0.276 MiB of storage per month. The full eleven-year archive is
about 0.0372 decimal GB, which costs about **$0.00056 per user-month** at the R2 storage rate of
$0.015 per GB-month. The free 10 GB storage allowance holds about **268** archives of this size.

## Operations

- Initial eleven-year export: about **$0.0183 per user**. Almost all of it is 3,912 R2 Class A
  object writes; batching reduces Worker requests but does not turn the individual R2 puts into one
  storage operation.
- Ordinary month when changed days are sent once daily: about **$0.0013 per user-month**, including
  storage, writes, Worker requests and the daily archive reconciliation.
- Conservative ordinary month when the same current day is rewritten on every hourly wake: about
  **$0.0049 per user-month**.
- Full download of all 3,912 days into a new local mirror: about **$0.0026 per user**. R2 egress is
  free; this is primarily one Worker request and one R2 Class B read per day.

These are marginal amounts. At low usage Cloudflare's free allowances can make the invoice zero;
at higher usage the account-level Worker subscription and any abuse protection dominate before an
individual archive's storage does. Recalculate when prices, retention, batch size or the number of
hourly rewrites changes.

The HPKE version 2 envelope removes the explicit 12-byte nonce from each stored day, saving about
46.9 KB across the measured 3,912-day archive. That does not change any rounded monthly figure
above. Migrating the existing archive rewrites each day once, so its one-time server cost is the
same order as the initial export: about **$0.0183** for this archive.

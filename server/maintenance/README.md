# Maintenance

Two jobs nobody can do from the outside: answer a deletion request, and look at what the archive
store actually holds. Wrangler cannot list or delete R2 objects, and the service deliberately has no
delete route — a public endpoint that removes somebody's archive is a liability, and the promise in
the privacy policy is answered by a person reading a request, not by a stranger's HTTP call.

So this Worker is **never deployed**. It runs on the machine of whoever is answering, bound to the
live bucket:

```
npx wrangler dev --remote --config server/maintenance/wrangler.jsonc --port 8799
```

`--remote` is the whole point: without it the binding is a local simulation and every answer is
about nothing. The only way in is to be the person who started it, which is why there is no key in
the config and no route.

## What it answers

- `GET /ceilings` — what the two byte ceilings have been handed. Both count bytes _ever handed over_
  and never come down, so this is the only warning there is before an upload is answered `507`.
- `GET /archives` — every archive with its own tally. `?deep` walks every object instead: days,
  bytes, first and last day, last write. A decade of days is four thousand objects per archive, so
  the deep form takes seconds, not milliseconds.
- `GET /archive/<id>` — one archive in full, including whether it is claimed, when, and whether an
  editor key is registered.
- `GET /export/<id>` — every object as JSON lines, bodies in base64, streamed. This is the backup.
  The days stay ciphertext: this tool holds no key and cannot read a single reading.
- `POST /delete/<id>` — what deleting it would remove. Deletes nothing.
- `POST /delete/<id>?confirm=<id>` — delete it, for good.

An id is 26 characters of base32 and nothing else is accepted, which is what keeps the service-wide
`taken` object and any other root name out of reach.

## Answering a deletion request

1. Start the Worker.
2. `POST /delete/<id>` and read what it says it would remove. A deletion request names an archive;
   the thing to check is that the archive named is the one that exists.
3. Take a copy first if there is any doubt: `GET /export/<id>`.
4. `POST /delete/<id>?confirm=<id>`.

The service tally does not move: it counts bytes handed over, and a deletion gives none of them
back. Freeing it means deleting the root `taken` object and letting the service start again from its
measured floor — which this tool refuses to do, on purpose.

## Taking a copy

```
curl -s http://localhost:8799/export/<id> -o <id>-$(date +%F).ndjson
```

One line per object: `key`, `size`, `uploaded`, and `body` in base64. Restoring has no route here —
the objects would go back with `wrangler r2 object put`, one at a time — and that is deliberate:
writing into a live bucket from a tool that answers deletion requests is how the wrong archive gets
overwritten.

**A copy is not the phone's copy.** The phone's ledger says which days it believes are stored, so
objects taken out of a bucket a phone is using go missing from the archive and from nothing else —
Health still has the readings, and the daily listing check puts them back a day later at the
earliest.

## Proved on the live bucket

2026-09-15: `/ceilings` answered 12 archives (service tally 172 924 754 bytes, 0.16% of the
ceiling), `?deep` counted them, a dry run named what it would remove, a 26-character id with one
character missing was refused, a `confirm` naming a different archive was refused, and a one-day
test archive left over from 2026-08-29 was exported and then deleted for real — two objects, one
pass, and `/archive/<id>` afterwards said it was gone.

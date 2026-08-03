# lex-pack-agrifood

Agri-food domain pack — lot origin declaration, transformation graph, and EUDR readiness summary.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #237](https://github.com/alpibrusl/lex-ev-fleet/issues/237)). Builds on [`lex-pack-custody`](https://github.com/alpibrusl/lex-pack-custody) at the **data** level only: a lot's field-to-shelf custody trace is read straight from the shared `events` table (`kind='custody.handoff'`, keyed by `trailer_ref`) — this pack does not import custody's code or depend on it in `lex.toml`. A deployment mounting both needs custody as its own dependency.

## Routes

```
POST /agrifood/origins                 — declare a lot's origin {lot_ref, producer, geo, harvest_date, certificates:[{kind,hash}]}
POST /agrifood/transformations         — link lots {to_lot, from_lots:[...], kind, site}
GET  /agrifood/lots/:ref/trace         — field-to-shelf trace + EUDR readiness
```

## Usage

```lex
import "lex-pack-agrifood/agrifood" as agrifood

# in your router-wiring code:
let r := agrifood.mount(router.new(), db)
```

`agrifood.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue. Note the two ref fields: a lot is addressed as `lot_ref` by this pack's own API, but its custody chain is keyed `trailer_ref` on the trail — the manifest records both.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.

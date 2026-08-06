# info.lex — the agrifood agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the agrifood-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "agrifood", title: "Agrifood", tagline: "Lot origin, transformation graph, and EUDR readiness traced end to end.", personas: [{ kind: "agrifood-ops", title: "Agrifood ops", tagline: "Declares lot origins, links transformations, and traces EUDR readiness.", suggested_prompts: ["Declare origin for lot L-100: producer farm-acme, harvested 2026-03-01, with a photo certificate.", "Link lots L-100 and L-101 into transformed lot L-200 (milling) at site mill-1.", "Trace lot L-200's full custody and origin graph.", "Is lot L-200 EUDR-ready?"] }] }
}


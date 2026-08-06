# agrifood_agent.lex — an LLM-driven agent persona that operates THIS pack's
# own REST service (agrifood.lex's /agrifood/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex.
# Agrifood has no external backend to wrap (pure SQL + trail log, no outbound
# HTTP calls) — its mount() IS the domain logic.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn agrifood_capability() -> cap.Capability {
  cap.inbound("handle", "Operate agrifood lot provenance: declare a lot's origin, link transformations that consume lots into new ones, and trace a lot's full custody/origin graph including EUDR readiness.", { title: "AgrifoodOps", description: "Inbound message for the agrifood ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn certificate_schema() -> sch.ModelSchema {
  { title: "Certificate", description: "A certification attached to a lot's origin.", fields: [sch.required_str("kind", []), sch.required_str("hash", [])] }
}

fn make_agrifood_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("declare_origin", "Declare a lot's origin: the producer, geo location, harvest date, and any certificates. Required before the lot can appear in a transformation or trace.", { title: "DeclareOrigin", description: "Origin declaration.", fields: [sch.required_str("lot_ref", []), sch.required_str("producer", []), sch.optional(sch.required_str("geo", [])), sch.optional(sch.required_str("harvest_date", [])), sch.optional(sch.required_array("certificates", KObject(certificate_schema()), []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/agrifood/origins"), jv.stringify(args), ""))
  }), t.define("link_transformation", "Record that one or more input lots were transformed into a new output lot (e.g. milling, blending, processing).", { title: "LinkTransformation", description: "Transformation linking.", fields: [sch.required_str("to_lot", []), sch.required_array("from_lots", KStr([]), []), sch.optional(sch.required_str("kind", [])), sch.optional(sch.required_str("site", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/agrifood/transformations"), jv.stringify(args), ""))
  }), t.define("trace_lot", "Get a lot's full traceability graph: custody events, origin (producer/geo/harvest/certificates) or the transformation it came from, chain integrity, and EUDR readiness.", { title: "TraceLot", description: "Lot trace lookup.", fields: [sch.required_str("lot_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/agrifood/lots/", jstr(args, "lot_ref"), "/trace"], ""), ""))
  }), t.define("check_eudr_readiness", "Quick check of just a lot's EUDR (EU deforestation regulation) readiness: whether it's ready and, if not, exactly what evidence is missing -- without the full trace dump.", { title: "CheckEudrReadiness", description: "EUDR readiness check.", fields: [sch.required_str("lot_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let j := http_get_json(str.join([self_base_url, "/agrifood/lots/", jstr(args, "lot_ref"), "/trace"], ""), "")
    match jv.get_field(j, "eudr") {
      Some(eudr) => Ok(eudr),
      None => Ok(j),
    }
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn agrifood_system_prompt(id :: Str) -> Str {
  str.join(["You are agrifood ops agent ", id, ". You track lot provenance: where a lot originated, how lots combine into new ones through transformations, and whether a lot is EUDR-compliant.", " Use declare_origin when a new lot enters the chain, link_transformation when lots are combined or processed into a new lot, trace_lot for a full custody/origin picture, and check_eudr_readiness for a quick compliance check naming exactly what's missing.", " Be precise about lot_ref and always name which lots you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_agrifood_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := agrifood_capability()
  let cfg := { id: id, kind: "agrifood-ops", system_prompt: agrifood_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_agrifood_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Agrifood ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


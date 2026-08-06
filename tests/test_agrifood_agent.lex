# tests/test_agrifood_agent.lex — pure-logic coverage for src/agrifood_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/agrifood_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_agrifood_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_four_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_agrifood_tools("http://127.0.0.1:8100")) == 4, "agrifood has 2 routes plus a derived EUDR-readiness convenience, so 4 tools")
}

fn test_declare_origin_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let cert := JObj([("kind", JStr("photo")), ("hash", JStr("deadbeef"))])
  let sample := JObj([("lot_ref", JStr("L-100")), ("producer", JStr("farm-acme")), ("geo", JStr("52.0,4.0")), ("harvest_date", JStr("2026-03-01")), ("certificates", JList([cert]))])
  match schema_of("declare_origin") {
    None => Err("declare_origin tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("declare_origin's schema must accept agrifood.lex's documented POST /agrifood/origins body"),
      Ok(_) => pass(),
    },
  }
}

fn test_link_transformation_schema_requires_from_lots() -> Result[Unit, Str] {
  let bad := JObj([("to_lot", JStr("L-200"))])
  match schema_of("link_transformation") {
    None => Err("link_transformation tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("link_transformation's schema must require from_lots"),
    },
  }
}

fn test_trace_lot_schema_requires_lot_ref() -> Result[Unit, Str] {
  match schema_of("trace_lot") {
    None => Err("trace_lot tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("trace_lot's schema must require lot_ref"),
    },
  }
}

fn test_check_eudr_readiness_schema_requires_lot_ref() -> Result[Unit, Str] {
  match schema_of("check_eudr_readiness") {
    None => Err("check_eudr_readiness tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("check_eudr_readiness's schema must require lot_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_four_tools_defined(), test_declare_origin_schema_accepts_documented_shape(), test_link_transformation_schema_requires_from_lots(), test_trace_lot_schema_requires_lot_ref(), test_check_eudr_readiness_schema_requires_lot_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}


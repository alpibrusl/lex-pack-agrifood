# tests/test_agrifood.lex — pure-logic coverage for src/agrifood.lex.
#
# has_eudr_cert is the one pure, non-trivial function here (does a cert list
# carry a deforestation-free certificate); the effectful routes (origins,
# transformations, trace, DB) need a live DB to exercise meaningfully —
# that's covered by lex-ev-fleet's own integration testing of the mounted
# deployment.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/agrifood" as agrifood

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

# ---- has_eudr_cert ------------------------------------------------------------
fn test_has_eudr_cert_true_when_present() -> Result[Unit, Str] {
  assert_true(agrifood.has_eudr_cert([("deforestation-free", "abc123")]), "a deforestation-free certificate must satisfy the EUDR check")
}

fn test_has_eudr_cert_false_when_absent() -> Result[Unit, Str] {
  assert_true(not agrifood.has_eudr_cert([("organic", "def456")]), "an unrelated certificate must not satisfy the EUDR check")
}

fn test_has_eudr_cert_false_when_empty() -> Result[Unit, Str] {
  assert_true(not agrifood.has_eudr_cert([]), "no certificates at all must not satisfy the EUDR check")
}

fn test_has_eudr_cert_true_among_several() -> Result[Unit, Str] {
  assert_true(agrifood.has_eudr_cert([("organic", "a"), ("deforestation-free", "b")]), "the EUDR check must find the certificate among several, not just as the only one")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := agrifood.manifest()
  assert_true(list.is_empty(pos.validate(m)), "agrifood's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(agrifood.manifest().route_prefix == "/agrifood", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_subject_and_custody_ref_differ() -> Result[Unit, Str] {
  let m := agrifood.manifest()
  assert_true(m.subject_ref_field == "lot_ref" and m.custody_ref_field == "trailer_ref", "a lot is addressed by lot_ref but its custody chain is keyed trailer_ref — the manifest must record both")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_has_eudr_cert_true_when_present(), test_has_eudr_cert_false_when_absent(), test_has_eudr_cert_false_when_empty(), test_has_eudr_cert_true_among_several(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_subject_and_custody_ref_differ()]
}


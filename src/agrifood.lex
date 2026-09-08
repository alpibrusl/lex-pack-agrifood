# agrifood.lex — origin traceability for food lots (agri-food pack, #124).
#
# The coffee run with regulation attached. A LOT of produce is a chained ref
# (the custody machinery is ref-agnostic — trailers, containers, lots), its
# ORIGIN is declared once (plot geolocation, producer, harvest date, and the
# HASHES of due-diligence certificates — the documents stay wherever they
# live; the chain carries their fingerprints), and a TRANSFORMATION links
# output lots to input lots (cherries -> parchment -> green), so a shelf lot
# traces back to every field it came from.
#
# The retailer-facing trace walks that graph: custody handoffs per lot with
# re-verified signatures, transformations, and the upstream origins — plus an
# EUDR summary: a lot is eudr_ready only if EVERY root lot it descends from
# has a geolocation and a deforestation-free certificate hash on the chain.
# Missing evidence is named, not hand-waved.
#
#   POST /agrifood/origins                 — declare a lot's origin {lot_ref, producer, geo, harvest_date, certificates:[{kind,hash}]}
#   POST /agrifood/transformations         — link lots {to_lot, from_lots:[...], kind, site}
#   GET  /agrifood/lots/:ref/trace         — field-to-shelf trace + EUDR readiness
#
# Domain pack over the lex-soft core + custody pack events. Zero core changes.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-trail/attest" as attest

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/evidence" as evidence

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jlist(j :: jv.Json, key :: Str) -> List[jv.Json] {
  match jv.get_field(j, key) {
    Some(JList(xs)) => xs,
    _ => [],
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / BIGINT only.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __o := sql.exec(db, "CREATE TABLE IF NOT EXISTS agrifood_origins (lot_ref TEXT PRIMARY KEY, producer TEXT NOT NULL, geo TEXT NOT NULL DEFAULT '', harvest_date TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL)", [])
  let __c := sql.exec(db, "CREATE TABLE IF NOT EXISTS agrifood_certs (lot_ref TEXT NOT NULL, kind TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY (lot_ref, kind, hash))", [])
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS agrifood_transformations (to_lot TEXT NOT NULL, from_lot TEXT NOT NULL, kind TEXT NOT NULL DEFAULT '', site TEXT NOT NULL DEFAULT '', ts_ms BIGINT NOT NULL, PRIMARY KEY (to_lot, from_lot))", [])
  ()
}

type Origin = { producer :: Str, geo :: Str, harvest_date :: Str }

fn origin_for(db :: Db, lot_ref :: Str) -> [sql] Option[Origin] {
  match sql.query(db, "SELECT producer, geo, harvest_date FROM agrifood_origins WHERE lot_ref = ?", [PStr(lot_ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ producer: row_str(row, "producer"), geo: row_str(row, "geo"), harvest_date: row_str(row, "harvest_date") }),
    },
  }
}

fn certs_for(db :: Db, lot_ref :: Str) -> [sql] List[(Str, Str)] {
  match sql.query(db, "SELECT kind, hash FROM agrifood_certs WHERE lot_ref = ? ORDER BY kind", [PStr(lot_ref)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> (Str, Str) {
      (row_str(row, "kind"), row_str(row, "hash"))
    }),
  }
}

fn inputs_for(db :: Db, to_lot :: Str) -> [sql] List[Str] {
  match sql.query(db, "SELECT from_lot FROM agrifood_transformations WHERE to_lot = ? ORDER BY from_lot", [PStr(to_lot)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> Str {
      row_str(row, "from_lot")
    }),
  }
}

fn transformation_meta(db :: Db, to_lot :: Str) -> [sql] (Str, Str) {
  match sql.query(db, "SELECT kind, site FROM agrifood_transformations WHERE to_lot = ? LIMIT 1", [PStr(to_lot)]) {
    Err(_) => ("", ""),
    Ok(rows) => match list.head(rows) {
      None => ("", ""),
      Some(row) => (row_str(row, "kind"), row_str(row, "site")),
    },
  }
}

# Custody movements of one lot, with signature counts — the same per-ref chain
# the journey/demurrage endpoints verify.
fn movements_json(db :: Db, log :: tlog.Log, lot_ref :: Str) -> [sql] (List[jv.Json], Bool) {
  let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(lot_ref)), "%"))
  let rows := match sql.query(db, "SELECT id, payload_json, ts_ms FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
    Err(_) => [],
    Ok(rs) => rs,
  }
  let items := list.map(rows, fn (row :: sql.Row) -> [sql] jv.Json {
    let payload := match jv.parse(row_str(row, "payload_json")) {
      Err(_) => JObj([]),
      Ok(v) => v,
    }
    let id := row_str(row, "id")
    let sigs := match attest.chain(log, id) {
      Err(_) => 0,
      Ok(atts) => list.len(list.filter(atts, fn (a :: attest.Attestation) -> Bool {
        a.kind == "custody.sign"
      })),
    }
    JObj([("event_id", JStr(id)), ("ts_ms", JInt(row_int(row, "ts_ms"))), ("from_agent", JStr(jstr(payload, "from_agent"))), ("to_agent", JStr(jstr(payload, "to_agent"))), ("site", JStr(jstr(payload, "site"))), ("signatures", JInt(sigs))])
  })
  let intact := match list.head(list.reverse(rows)) {
    None => true,
    Some(row) => settlement.verify(log, row_str(row, "id")),
  }
  (items, intact)
}

fn cert_json(c :: (Str, Str)) -> jv.Json {
  match c {
    (kind, hash) => JObj([("kind", JStr(kind)), ("hash", JStr(hash))]),
  }
}

fn has_eudr_cert(certs :: List[(Str, Str)]) -> Bool {
  not list.is_empty(list.filter(certs, fn (c :: (Str, Str)) -> Bool {
    match c {
      (kind, _) => str.cmp(kind, "deforestation-free") == 0,
    }
  }))
}

# Depth-first trace: a lot's own movements + origin, then the lots it was made
# from. Returns (trace json, list of root lots MISSING eudr evidence).
fn trace_lot(db :: Db, log :: tlog.Log, lot_ref :: Str, depth :: Int) -> [sql] (jv.Json, List[Str]) {
  let mv := movements_json(db, log, lot_ref)
  let moves := match mv {
    (m, _) => m,
  }
  let intact := match mv {
    (_, i) => i,
  }
  let origin := origin_for(db, lot_ref)
  let certs := certs_for(db, lot_ref)
  let inputs := inputs_for(db, lot_ref)
  let origin_json := match origin {
    None => JNull,
    Some(o) => JObj([("producer", JStr(o.producer)), ("geo", JStr(o.geo)), ("harvest_date", JStr(o.harvest_date)), ("certificates", JList(list.map(certs, cert_json)))]),
  }
  let is_root := list.is_empty(inputs)
  let own_missing := if is_root {
    let geo_ok := match origin {
      None => false,
      Some(o) => not str.is_empty(o.geo),
    }
    if geo_ok and has_eudr_cert(certs) {
      []
    } else {
      [lot_ref]
    }
  } else {
    []
  }
  if depth <= 0 {
    (JObj([("lot_ref", JStr(lot_ref)), ("error", JStr("trace depth exceeded"))]), [lot_ref])
  } else {
    let subs := list.map(inputs, fn (input :: Str) -> [sql] (jv.Json, List[Str]) {
      trace_lot(db, log, input, depth - 1)
    })
    let sub_json := list.map(subs, fn (s :: (jv.Json, List[Str])) -> jv.Json {
      match s {
        (j, _) => j,
      }
    })
    let sub_missing := list.fold(subs, [], fn (acc :: List[Str], s :: (jv.Json, List[Str])) -> List[Str] {
      match s {
        (_, m) => list.concat(acc, m),
      }
    })
    let tm := transformation_meta(db, lot_ref)
    let t_kind := match tm {
      (k, _) => k,
    }
    let t_site := match tm {
      (_, v) => v,
    }
    let produced := if is_root {
      JNull
    } else {
      JObj([("kind", JStr(t_kind)), ("site", JStr(t_site)), ("inputs", JList(sub_json))])
    }
    (JObj([("lot_ref", JStr(lot_ref)), ("custody", JList(moves)), ("chain_intact", JBool(intact)), ("origin", origin_json), ("produced_from", produced)]), list.concat(own_missing, sub_missing))
  }
}

fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_origins := router.route_effectful(r, "POST", "/agrifood/origins", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let lot_ref := jstr(j, "lot_ref")
        let producer := jstr(j, "producer")
        if str.is_empty(lot_ref) or str.is_empty(producer) {
          resp.bad_request("{\"error\":\"lot_ref and producer are required\"}")
        } else {
          let geo := jstr(j, "geo")
          let harvest := jstr(j, "harvest_date")
          let stmt := "INSERT INTO agrifood_origins (lot_ref, producer, geo, harvest_date, created_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT (lot_ref) DO UPDATE SET producer = ?, geo = ?, harvest_date = ?"
          match sql.exec(db, stmt, [PStr(lot_ref), PStr(producer), PStr(geo), PStr(harvest), PInt(time.now_ms()), PStr(producer), PStr(geo), PStr(harvest)]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let certs := jlist(j, "certificates")
              let certs_result := list.fold(certs, Ok(()), fn (acc :: Result[Unit, Str], cert :: jv.Json) -> [sql] Result[Unit, Str] {
                match acc {
                  Err(msg) => Err(msg),
                  Ok(_) => {
                    let kind := jstr(cert, "kind")
                    let hash := jstr(cert, "hash")
                    if str.is_empty(kind) or str.is_empty(hash) {
                      Ok(())
                    } else {
                      match sql.exec(db, "INSERT INTO agrifood_certs (lot_ref, kind, hash) VALUES (?, ?, ?) ON CONFLICT (lot_ref, kind, hash) DO NOTHING", [PStr(lot_ref), PStr(kind), PStr(hash)]) {
                        Err(e) => Err(e.message),
                        Ok(_) => Ok(()),
                      }
                    }
                  },
                }
              })
              match certs_result {
                Err(msg) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(msg)), "}"))),
                Ok(_) => {
                  let log := settlement.trail_on(db)
                  let __e := evidence.record(log, "agrifood.origin", producer, None, [("lot_ref", JStr(lot_ref)), ("producer", JStr(producer)), ("geo", JStr(geo)), ("harvest_date", JStr(harvest)), ("certificates", JList(list.map(certs, fn (cert :: jv.Json) -> jv.Json {
                    JObj([("kind", JStr(jstr(cert, "kind"))), ("hash", JStr(jstr(cert, "hash")))])
                  })))])
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("lot_ref", JStr(lot_ref)), ("certificates", JInt(list.len(certs)))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_transforms := router.route_effectful(with_origins, "POST", "/agrifood/transformations", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let to_lot := jstr(j, "to_lot")
        let from_lots := list.filter(list.map(jlist(j, "from_lots"), fn (x :: jv.Json) -> Str {
          match x {
            JStr(s) => s,
            _ => "",
          }
        }), fn (s :: Str) -> Bool {
          not str.is_empty(s)
        })
        if str.is_empty(to_lot) or list.is_empty(from_lots) {
          resp.bad_request("{\"error\":\"to_lot and a non-empty from_lots list are required\"}")
        } else {
          let kind := jstr(j, "kind")
          let site := jstr(j, "site")
          let now := time.now_ms()
          let xform_result := list.fold(from_lots, Ok(()), fn (acc :: Result[Unit, Str], from :: Str) -> [sql] Result[Unit, Str] {
            match acc {
              Err(msg) => Err(msg),
              Ok(_) => match sql.exec(db, "INSERT INTO agrifood_transformations (to_lot, from_lot, kind, site, ts_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT (to_lot, from_lot) DO UPDATE SET kind = ?, site = ?", [PStr(to_lot), PStr(from), PStr(kind), PStr(site), PInt(now), PStr(kind), PStr(site)]) {
                Err(e) => Err(e.message),
                Ok(_) => Ok(()),
              },
            }
          })
          match xform_result {
            Err(msg) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(msg)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("to_lot", JStr(to_lot)), ("from_lots", JList(list.map(from_lots, fn (s :: Str) -> jv.Json {
                JStr(s)
              }))), ("kind", JStr(kind)), ("site", JStr(site))]))
              let __e := tlog.append(log, "agrifood.transformation", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("to_lot", JStr(to_lot)), ("inputs", JInt(list.len(from_lots)))])))
            },
          }
        }
      },
    }
  })
  router.route_effectful(with_transforms, "GET", "/agrifood/lots/:ref/trace", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    let known := match origin_for(db, ref) {
      Some(_) => true,
      None => not list.is_empty(inputs_for(db, ref)),
    }
    if not known {
      resp.json_status(404, "{\"error\":\"unknown lot: no origin declared and no transformation produced it\"}")
    } else {
      let log := settlement.trail_on(db)
      let tr := trace_lot(db, log, ref, 12)
      let trace := match tr {
        (t, _) => t,
      }
      let missing := match tr {
        (_, m) => m,
      }
      resp.json(jv.stringify(JObj([("lot_ref", JStr(ref)), ("trace", trace), ("eudr", JObj([("ready", JBool(list.is_empty(missing))), ("missing_evidence", JList(list.map(missing, fn (m :: Str) -> jv.Json {
        JStr(m)
      })))]))])))
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). Note the two ref fields: a lot is addressed as
# lot_ref by this pack's own API, but its custody chain is keyed trailer_ref on
# the trail. The manifest records both rather than hiding the difference.
fn manifest() -> pos.PackManifest {
  { id: "agrifood", title: "Agri-food", tagline: "Every unit chains back through its transformations to a declared origin.", pattern: "provenance_trace", subject: "lot", subject_ref_field: "lot_ref", custody_ref_field: "trailer_ref", parties: [{ position: "executor", name: "producer", title: "Producer — declares the origin a root lot starts from", field: "producer", required: true }, { position: "custodian", name: "holder", title: "Holder — takes the lot on at a handoff", field: "to_agent", required: false }, { position: "attestor", name: "certifier", title: "Certifier — issues the certificates attached to a lot", field: "", required: false }, { position: "observer", name: "buyer", title: "Downstream buyer — reads the trace to support its own claim", field: "", required: false }], relationships: [{ from: "producer", to: "holder", role: "custody", label: "the lot leaves the producer into the chain" }, { from: "certifier", to: "producer", role: "attestation", label: "certificates are issued against the declared origin" }, { from: "holder", to: "buyer", role: "custody", label: "the lot reaches the downstream buyer" }], event_kinds: ["agrifood.origin", "agrifood.transformation"], evidence_kinds: ["certificate", "geolocation", "harvest_date", "custody_signature"], settles: false, route_prefix: "/agrifood" }
}


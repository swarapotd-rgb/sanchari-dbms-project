#!/usr/bin/env python3
"""
Sanchari - draws the two design diagrams from the live database.

    er_diagram.png / .svg          Chen-notation ER diagram
    relational_schema.png / .svg   crow's-foot relational schema

WHY A SCRIPT
    Hand-drawn diagrams drift away from the SQL the moment someone adds a
    column. This script reads the schema straight out of PostgreSQL, so
    the relational schema can never be out of date. The ER diagram cannot
    be read off the database (relationship names, derived and composite
    attributes are design ideas, not SQL), so it is written out below in
    ER_ENTITIES / ER_RELATIONSHIPS - but before drawing anything the
    script CHECKS that design against the database:

      * every column of every table appears in the ER diagram,
      * every one of the 24 foreign keys belongs to exactly one relationship,
      * every thick line (total participation) sits on a NOT NULL foreign key
        and every thin line on a nullable one.

    If any check fails it prints what is wrong and draws nothing.

HOW TO RUN  (needs Python 3 and Graphviz:  https://graphviz.org/download/)
    1. Build the schema first (reset.sql, then run_all.sql).
    2. From the repo root:

         Docker:
           PSQL="docker exec -i sanchari-db psql -U postgres -d sanchari" python docs/diagrams/build_diagrams.py
         Windows PowerShell:
           $env:PSQL="docker exec -i sanchari-db psql -U postgres -d sanchari"; python docs/diagrams/build_diagrams.py
         Native psql:
           python docs/diagrams/build_diagrams.py

    Output lands next to this file.
"""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent
FONT = "DejaVu Sans,Arial,Helvetica,sans-serif"

# ======================================================================
#  1. READ THE SCHEMA FROM POSTGRESQL
# ======================================================================

CATALOG_SQL = r"""
SELECT json_build_object(
  'columns', (
    SELECT json_agg(json_build_object(
             't', c.relname, 'c', a.attname, 'n', a.attnum,
             'type', format_type(a.atttypid, a.atttypmod),
             'notnull', a.attnotnull,
             'serial', coalesce(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false))
           ORDER BY c.relname, a.attnum)
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    JOIN pg_attribute a  ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
    WHERE ns.nspname = 'public' AND c.relkind = 'r'),
  'constraints', (
    SELECT json_agg(json_build_object(
             'name', co.conname, 'type', co.contype, 't', c.relname,
             'cols', (SELECT json_agg(a.attname ORDER BY k.ord)
                        FROM unnest(co.conkey) WITH ORDINALITY k(n, ord)
                        JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.n),
             'ref', fc.relname,
             'refcols', (SELECT json_agg(a.attname ORDER BY k.ord)
                           FROM unnest(co.confkey) WITH ORDINALITY k(n, ord)
                           JOIN pg_attribute a ON a.attrelid = co.confrelid AND a.attnum = k.n),
             'ondelete', co.confdeltype))
    FROM pg_constraint co
    JOIN pg_class c      ON c.oid = co.conrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_class fc ON fc.oid = co.confrelid
    WHERE ns.nspname = 'public' AND co.contype IN ('p', 'f', 'u'))
);
"""


def read_catalog():
    cmd = shlex.split(os.environ.get("PSQL", "psql -U postgres -d sanchari"))
    res = subprocess.run(cmd + ["-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1"],
                         input=CATALOG_SQL, capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        sys.exit("Could not read the schema from PostgreSQL.\n"
                 "Is the database running, and has run_all.sql been run?\n" + res.stderr)
    cat = json.loads(res.stdout.strip())
    tables = {}
    for col in cat["columns"]:
        tables.setdefault(col["t"], []).append(col)
    cons = cat["constraints"] or []
    return tables, cons


def short_type(col):
    t = col["type"]
    if col["serial"]:
        return "BIGSERIAL" if t == "bigint" else "SERIAL"
    t = (t.replace("character varying", "VARCHAR")
          .replace("character", "CHAR")
          .replace("timestamp with time zone", "TIMESTAMPTZ")
          .replace("timestamp without time zone", "TIMESTAMP")
          .replace("time without time zone", "TIME")
          .replace("integer", "INT"))
    return t.upper()


# ======================================================================
#  2. THE ER DESIGN
# ======================================================================
#
#  Attribute kinds:
#    key       primary key (solid ellipse, underlined)
#    partial   partial key of a weak entity (dashed ellipse, underlined)
#    attr      ordinary attribute
#    derived   derived attribute (dashed amber ellipse). stored=False means
#              it is calculated when needed and has no column.
#    alter     ordinary attribute added later by an ALTER demo file
#    composite ("name", [children])  - ellipse with child ellipses
#
#  Foreign key columns are NOT attributes in an ER diagram - they are
#  what the relationship lines become when mapped to tables.

GROUP = {  # (header colour for schema, light fill for ER)
    "people":   ("#1f3a5f", "#e6edf6"),
    "places":   ("#1e6b4a", "#e3f2ea"),
    "trips":    ("#8a6a1f", "#fbf1dc"),
    "checks":   ("#7a2b2b", "#f8e6e6"),
    "semantic": ("#4b3a7a", "#ece8f6"),
}

TABLE_GROUP = {
    "role": "people", "user_account": "people", "traveller_profile": "people",
    "interest_category": "people", "traveller_interest": "people",
    "destination": "places", "transport_mode": "places", "place": "places",
    "place_category": "places", "opening_rule": "places",
    "closure_window": "places", "travel_leg": "places",
    "trip": "trips", "trip_day": "trips", "itinerary_stop": "trips",
    "feasibility_run": "checks", "violation": "checks",
    "review_summary": "semantic", "place_embedding": "semantic",
}

# columns added by the ALTER demos, not by CREATE TABLE
ALTER_ADDED = {("place", "short_description"): "05a",
               ("trip", "status_note"): "05b"}

K, P, A, D, AL = "key", "partial", "attr", "derived", "alter"

ER_ENTITIES = {
    # name: (weak?, [attributes])
    "ROLE": (False, [("role_id", K), ("role_name", A), ("description", A)]),
    "USER_ACCOUNT": (False, [("user_id", K), ("email", A), ("password_hash", A),
                             ("display_name", A), ("home_city", A),
                             ("account_status", A), ("date_joined", A)]),
    "TRAVELLER_PROFILE": (False, [("profile_id", K), ("default_pace", A),
                                  ("max_daily_budget", A), ("max_travel_hours_per_day", A),
                                  (("active_window", ["day_start_time", "day_end_time"]), A),
                                  ("updated_at", A)]),
    "INTEREST_CATEGORY": (False, [("category_id", K), ("name", A), ("slug", A),
                                  ("description", A)]),
    "DESTINATION": (False, [("destination_id", K), ("name", A), ("district", A),
                            ("state", A), (("centroid", ["dest_lat", "dest_lon"]), A),
                            ("base_cost_per_day", A)]),
    "TRANSPORT_MODE": (False, [("mode_id", K), ("mode_name", A), ("avg_speed_kmph", A),
                               ("cost_per_km", A)]),
    "PLACE": (False, [("place_id", K), ("name", A), ("place_type", A),
                      (("coordinates", ["latitude", "longitude"]), A),
                      ("typical_visit_minutes", A),
                      (("entry_fee", ["fee_indian", "fee_foreign"]), A),
                      ("requires_daylight", A), ("avg_rating", D), ("review_count", D),
                      ("created_at", A), ("short_description", AL)]),
    "OPENING_RULE": (True, [("rule_no", P), ("day_of_week", A), ("opens_at", A),
                            ("closes_at", A), ("last_entry_at", A)]),
    "CLOSURE_WINDOW": (True, [("closure_no", P), ("start_date", A), ("end_date", A),
                              ("reason_code", A), ("is_annual_recurring", A),
                              ("recorded_at", A)]),
    # 1:1 weak entity: identified entirely by its owner, so no partial key
    "PLACE_EMBEDDING": (True, [("embedding", A), ("model_name", A), ("generated_at", A)]),
    "TRIP": (False, [("trip_id", K), ("title", A), ("origin_city", A), ("start_date", A),
                     ("end_date", A), ("duration_days", D, False), ("party_size", A),
                     ("budget_cap", A), ("status", A), ("feasibility_score", D),
                     ("created_at", A), ("status_note", AL)]),
    "TRIP_DAY": (True, [("day_number", P), ("calendar_date", A), ("day_start_time", A),
                        ("day_end_time", A), ("day_travel_minutes", D, False)]),
    "ITINERARY_STOP": (True, [("stop_seq", P), ("planned_arrival", A),
                              ("planned_departure", A), ("estimated_cost", A),
                              ("notes", A), ("allotted_minutes", D, False),
                              ("travel_minutes_from_prev", D, False)]),
    "FEASIBILITY_RUN": (False, [("run_id", K), ("run_at", A), ("rules_evaluated", A),
                                ("blocking_count", D), ("warning_count", D),
                                ("feasibility_score", D), ("run_status", A)]),
    "VIOLATION": (True, [("violation_no", P), ("rule_code", A), ("severity", A),
                         ("message", A), ("observed_value", A), ("expected_value", A),
                         ("detected_at", A)]),
    "REVIEW_SUMMARY": (False, [("review_id", K), ("rating", A), ("visited_on", A),
                               ("actual_duration_min", A), ("crowd_level", A),
                               ("mongo_doc_id", A), ("created_at", A)]),
}

# name: (identifying?, [(entity, cardinality, total?, role-label)], [attributes],
#        mapped-to table if the relationship became its own table, [foreign keys])
ER_RELATIONSHIPS = {
    "HAS_ROLE":      (False, [("USER_ACCOUNT", "N", True, ""), ("ROLE", "1", False, "")],
                      [], None, ["fk_user_account_role"]),
    "HAS_PROFILE":   (False, [("USER_ACCOUNT", "1", False, ""), ("TRAVELLER_PROFILE", "1", True, "")],
                      [], None, ["fk_traveller_profile_user"]),
    "PREFERS":       (False, [("TRAVELLER_PROFILE", "M", False, ""), ("INTEREST_CATEGORY", "N", False, "")],
                      [("weight", A), ("updated_at", A)], "traveller_interest",
                      ["fk_traveller_interest_profile", "fk_traveller_interest_category"]),
    "LOCATED_IN":    (False, [("DESTINATION", "1", False, ""), ("PLACE", "N", True, "")],
                      [], None, ["fk_place_destination"]),
    "TAGGED_AS":     (False, [("PLACE", "M", False, ""), ("INTEREST_CATEGORY", "N", False, "")],
                      [("relevance", A)], "place_category",
                      ["fk_place_category_place", "fk_place_category_category"]),
    "OPENS_ON":      (True, [("PLACE", "1", False, ""), ("OPENING_RULE", "N", True, "")],
                      [], None, ["fk_opening_rule_place"]),
    "CLOSED_DURING": (True, [("PLACE", "1", False, ""), ("CLOSURE_WINDOW", "N", True, "")],
                      [], None, ["fk_closure_window_place"]),
    "EMBEDS":        (True, [("PLACE", "1", False, ""), ("PLACE_EMBEDDING", "1", True, "")],
                      [], None, ["fk_place_embedding_place"]),
    "CONNECTED_BY":  (False, [("PLACE", "M", False, "origin"), ("PLACE", "N", False, "destination"),
                              ("TRANSPORT_MODE", "P", False, "")],
                      [("distance_km", A), ("typical_duration_min", A),
                       ("monsoon_duration_min", A), ("toll_cost", A), ("last_updated", A)],
                      "travel_leg",
                      ["fk_travel_leg_from_place", "fk_travel_leg_to_place", "fk_travel_leg_mode"]),
    "PLANS":         (False, [("USER_ACCOUNT", "1", False, ""), ("TRIP", "N", True, "")],
                      [], None, ["fk_trip_user_account"]),
    "USES_MODE":     (False, [("TRANSPORT_MODE", "1", False, ""), ("TRIP", "N", True, "")],
                      [], None, ["fk_trip_transport_mode"]),
    "HAS_DAY":       (True, [("TRIP", "1", False, ""), ("TRIP_DAY", "N", True, "")],
                      [], None, ["fk_trip_day_trip"]),
    "BASED_AT":      (False, [("DESTINATION", "1", False, ""), ("TRIP_DAY", "N", False, "")],
                      [], None, ["fk_trip_day_destination"]),
    "HAS_STOP":      (True, [("TRIP_DAY", "1", False, ""), ("ITINERARY_STOP", "N", True, "")],
                      [], None, ["fk_itinerary_stop_trip_day"]),
    "VISITS":        (False, [("PLACE", "1", False, ""), ("ITINERARY_STOP", "N", True, "")],
                      [], None, ["fk_itinerary_stop_place"]),
    "VALIDATES":     (False, [("TRIP", "1", False, ""), ("FEASIBILITY_RUN", "N", True, "")],
                      [], None, ["fk_feasibility_run_trip"]),
    "RAISES":        (True, [("FEASIBILITY_RUN", "1", False, ""), ("VIOLATION", "N", True, "")],
                      [], None, ["fk_violation_feasibility_run"]),
    "CONCERNS":      (False, [("ITINERARY_STOP", "1", False, ""), ("VIOLATION", "N", False, "")],
                      [], None, ["fk_violation_itinerary_stop"]),
    "REVIEWS":       (False, [("PLACE", "1", False, ""), ("REVIEW_SUMMARY", "N", True, "")],
                      [], None, ["fk_review_summary_place"]),
    "WRITES":        (False, [("USER_ACCOUNT", "1", False, ""), ("REVIEW_SUMMARY", "N", True, "")],
                      [], None, ["fk_review_summary_user_account"]),
}


def flat_names(attrs, stored_only=True):
    """Column names an attribute list stands for (composites flattened)."""
    out = []
    for a in attrs:
        name, kind = a[0], a[1]
        stored = a[2] if len(a) > 2 else True
        if stored_only and not stored:
            continue
        if isinstance(name, tuple):
            out.extend(name[1])
        else:
            out.append(name)
    return out


# ======================================================================
#  3. CHECK THE ER DESIGN AGAINST THE DATABASE
# ======================================================================

def check(tables, cons):
    problems = []
    fks = {c["name"]: c for c in cons if c["type"] == "f"}
    fk_cols = {}
    for c in fks.values():
        fk_cols.setdefault(c["t"], set()).update(c["cols"])
    notnull = {(t, c["c"]): c["notnull"] for t, cols in tables.items() for c in cols}

    # every FK belongs to exactly one relationship
    claimed = [fk for r in ER_RELATIONSHIPS.values() for fk in r[4]]
    for fk in fks:
        if claimed.count(fk) != 1:
            problems.append(f"foreign key {fk} is drawn {claimed.count(fk)} times (should be 1)")
    for fk in claimed:
        if fk not in fks:
            problems.append(f"diagram mentions {fk}, which does not exist in the database")

    # every table is an entity or a relationship-table
    rel_tables = {r[3]: name for name, r in ER_RELATIONSHIPS.items() if r[3]}
    ent_tables = {e.lower(): e for e in ER_ENTITIES}
    for t in tables:
        if t not in rel_tables and t not in ent_tables:
            problems.append(f"table {t} is not in the ER diagram")

    # every non-FK column is drawn; nothing drawn that isn't a column
    for t, cols in tables.items():
        if t in ent_tables:
            attrs = ER_ENTITIES[ent_tables[t]][1]
            where = ent_tables[t]
        elif t in rel_tables:
            attrs = ER_RELATIONSHIPS[rel_tables[t]][2]
            where = rel_tables[t]
        else:
            continue
        drawn = set(flat_names(attrs))
        real = {c["c"] for c in cols} - fk_cols.get(t, set())
        for c in sorted(real - drawn):
            problems.append(f"column {t}.{c} is missing from {where}")
        for c in sorted(drawn - real):
            problems.append(f"{where} shows '{c}', which is not a column of {t}")
        for (at, ac) in ALTER_ADDED:
            if at == t and ac not in {c["c"] for c in cols}:
                problems.append(f"{t}.{ac} should have been added by ALTER but is missing")

    # thick line (total participation) <=> NOT NULL foreign key, for 1:N / 1:1
    for name, (ident, parts, _a, rel_t, rel_fks) in ER_RELATIONSHIPS.items():
        if rel_t:  # M:N or ternary - the bridge table has its own rows; skip
            continue
        fk = fks[rel_fks[0]]
        child_ent = ent_tables[fk["t"]]
        parent_ent = ent_tables[fk["ref"]]
        must = all(notnull[(fk["t"], c)] for c in fk["cols"])
        for ent, card, total, _ in parts:
            if ent == child_ent and total != must:
                problems.append(f"{name}: {ent} line should be "
                                f"{'thick (total)' if must else 'thin (partial)'} - "
                                f"{fk['t']}.{','.join(fk['cols'])} is "
                                f"{'NOT NULL' if must else 'nullable'}")
            if ent == parent_ent and ent != child_ent and total:
                problems.append(f"{name}: {ent} line drawn thick, but nothing in SQL "
                                f"forces every {ent} to take part")
        if ident and not ER_ENTITIES[child_ent][0]:
            problems.append(f"{name} is identifying but {child_ent} is not drawn as weak")
        if ident:
            pk = next(c for c in cons if c["type"] == "p" and c["t"] == fk["t"])
            if not set(fk["cols"]) <= set(pk["cols"]):
                problems.append(f"{name} is identifying but the FK is not part of "
                                f"{fk['t']}'s primary key")
    return problems


# ======================================================================
#  4. DRAW THE RELATIONAL SCHEMA (crow's foot)
# ======================================================================

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def draw_schema(tables, cons):
    pk = {c["t"]: c["cols"] for c in cons if c["type"] == "p"}
    fks = [c for c in cons if c["type"] == "f"]
    uqs = [c for c in cons if c["type"] == "u"]
    fkcol = {(c["t"], col) for c in fks for col in c["cols"]}
    uq_single = {(c["t"], c["cols"][0]) for c in uqs if len(c["cols"]) == 1}
    uq_multi = {}
    for c in uqs:
        if len(c["cols"]) > 1:
            uq_multi.setdefault(c["t"], []).append(c["cols"])
    notnull = {(t, c["c"]): c["notnull"] for t, cols in tables.items() for c in cols}

    L = ['digraph schema {',
         f'  graph [rankdir=LR, splines=spline, nodesep=0.35, ranksep=1.1, pad=0.4,'
         f' fontname="{FONT}", fontsize=26, labelloc=t, newrank=true,'
         f' label=<<B>SANCHARI — RELATIONAL SCHEMA</B><BR/><FONT POINT-SIZE="15">'
         f'19 tables · 24 foreign keys · read directly from the database by build_diagrams.py'
         f'</FONT><BR/> >];',
         f'  node [shape=plaintext, fontname="{FONT}"];',
         f'  edge [color="#5b6b80", penwidth=1.1, dir=both, arrowsize=0.9];']

    for t, cols in tables.items():
        head, fill = GROUP[TABLE_GROUP[t]]
        rows = [f'<TR><TD COLSPAN="3" BGCOLOR="{head}" ALIGN="CENTER">'
                f'<FONT COLOR="white" POINT-SIZE="14"><B>{t}</B></FONT></TD></TR>']
        for c in cols:
            name = c["c"]
            tags = []
            if name in pk.get(t, []):
                tags.append("PK")
            if (t, name) in fkcol:
                tags.append("FK")
            if (t, name) in uq_single:
                tags.append("UQ")
            alter = (t, name) in ALTER_ADDED
            nm = f"<B>{name}</B>" if name in pk.get(t, []) else name
            if alter:
                nm = f"<I>{name} †</I>"
            ty = short_type(c)
            null_mark = "" if c["notnull"] else " ?"
            tagtxt = ",".join(tags)
            tagcol = "#0b6b3a" if "PK" in tags else ("#a0650b" if "FK" in tags else "#4b3a7a")
            tagcell = (f'<FONT COLOR="{tagcol}" POINT-SIZE="10"><B>{tagtxt}</B></FONT>'
                       if tagtxt else " ")
            rows.append(
                f'<TR><TD ALIGN="LEFT" PORT="{name}_l">{nm}</TD>'
                f'<TD ALIGN="LEFT"><FONT COLOR="#6b7480" POINT-SIZE="10">{esc(ty)}{null_mark}</FONT></TD>'
                f'<TD ALIGN="RIGHT" PORT="{name}">{tagcell}</TD></TR>')
        for cols_u in uq_multi.get(t, []):
            rows.append(f'<TR><TD COLSPAN="3" ALIGN="LEFT"><FONT COLOR="#4b3a7a" POINT-SIZE="10">'
                        f'UQ ({", ".join(cols_u)})</FONT></TD></TR>')
        L.append(f'  {t} [label=<<TABLE BORDER="1" COLOR="{head}" CELLBORDER="0" CELLSPACING="0" '
                 f'CELLPADDING="4" BGCOLOR="{fill}">{"".join(rows)}</TABLE>>];')

    for c in fks:
        child, parent = c["t"], c["ref"]
        must = all(notnull[(child, col)] for col in c["cols"])
        one_to_one = any(set(u["cols"]) == set(c["cols"]) for u in uqs if u["t"] == child) \
            or set(pk.get(child, [])) == set(c["cols"])
        tail = "teetee" if must else "teeodot"         # at the parent: exactly one / zero-or-one
        head = "teeodot" if one_to_one else "crowodot"  # at the child: zero-or-one / zero-or-many
        L.append(f'  {parent}:{c["refcols"][0]}:e -> {child}:{c["cols"][0]}_l:w '
                 f'[arrowtail={tail}, arrowhead={head}, tooltip="{c["name"]}"];')

    legend = ('<TABLE BORDER="1" COLOR="#1f3a5f" CELLBORDER="0" CELLPADDING="5" BGCOLOR="white">'
              '<TR><TD COLSPAN="2" BGCOLOR="#1f3a5f"><FONT COLOR="white"><B>HOW TO READ</B></FONT></TD></TR>'
              '<TR><TD ALIGN="LEFT">PK / FK / UQ</TD><TD ALIGN="LEFT">primary key / foreign key / unique</TD></TR>'
              '<TR><TD ALIGN="LEFT"><B>bold column</B></TD><TD ALIGN="LEFT">part of the primary key</TD></TR>'
              '<TR><TD ALIGN="LEFT">type ?</TD><TD ALIGN="LEFT">nullable column (may be empty)</TD></TR>'
              '<TR><TD ALIGN="LEFT"><I>name †</I></TD><TD ALIGN="LEFT">added later by ALTER (05a / 05b)</TD></TR>'
              '<TR><TD ALIGN="LEFT">|| at parent</TD><TD ALIGN="LEFT">exactly one parent (FK is NOT NULL)</TD></TR>'
              '<TR><TD ALIGN="LEFT">o| at parent</TD><TD ALIGN="LEFT">zero or one parent (FK may be NULL)</TD></TR>'
              '<TR><TD ALIGN="LEFT">crow + o at child</TD><TD ALIGN="LEFT">zero or many children</TD></TR>'
              '<TR><TD ALIGN="LEFT">| + o at child</TD><TD ALIGN="LEFT">zero or one child (1:1)</TD></TR>'
              '</TABLE>')
    L.append(f'  legend [label=<{legend}>];')
    L.append('  { rank=same; role; legend; }')
    L.append('}')
    return "\n".join(L)


# ======================================================================
#  5. DRAW THE ER DIAGRAM (Chen)
# ======================================================================

# Entity positions in inches (x, y), y grows upwards. Chosen by hand so the
# diagram reads in zones: availability rules top-left, people top-right,
# places in the middle, trips along the bottom, checks bottom-right.
POS = {
    "CLOSURE_WINDOW": (-15, 11), "OPENING_RULE": (-5, 13),
    "INTEREST_CATEGORY": (7, 13), "TRAVELLER_PROFILE": (19, 13),
    "PLACE_EMBEDDING": (-17, 2), "PLACE": (-3, 2), "REVIEW_SUMMARY": (9, 3),
    "USER_ACCOUNT": (21, 2), "ROLE": (30, 2),
    "DESTINATION": (-18, -8), "TRANSPORT_MODE": (-8, -9),
    "ITINERARY_STOP": (3, -9), "VIOLATION": (22, -9),
    "TRIP_DAY": (-9, -18), "TRIP": (9, -18), "FEASIBILITY_RUN": (22, -19),
}
# diamonds placed off the plain midpoint where that reads better
REL_POS = {
    "CONNECTED_BY": (-6.5, -3.0), "VISITS": (0.5, -4.0), "PLANS": (16.5, -6.5),
    "CONCERNS": (12.5, -9.0), "USES_MODE": (-0.5, -13.0), "HAS_STOP": (-3.0, -13.5),
    "LOCATED_IN": (-11.0, -3.5), "BASED_AT": (-14.0, -13.5),
}
CHAR_W = 0.088      # average character width in inches at 11 pt
ATTR_H = 0.40


def nid(*parts):
    return "_".join(p.replace(" ", "_") for p in parts)


def text_w(label):
    return len(label) * CHAR_W + 0.45


def er_layout():
    """Work out a position for every node. Entities and diamonds are fixed;
    attributes go in a ring around their owner, in the gaps between the
    owner's relationship lines, and are pushed outwards until nothing
    overlaps."""
    import math

    nodes = {}     # id -> dict(x, y, w, h)
    segs = []      # relationship lines, for collision checks: (x1, y1, x2, y2)

    for ent, (x, y) in POS.items():
        nodes[ent] = dict(x=x, y=y, w=text_w(ent) + 0.5, h=0.62)

    rel_xy = {}
    for rel, (_i, parts, _a, _t, _f) in ER_RELATIONSHIPS.items():
        if rel in REL_POS:
            x, y = REL_POS[rel]
        else:
            ents = list(dict.fromkeys(p[0] for p in parts))
            x = sum(POS[e][0] for e in ents) / len(ents)
            y = sum(POS[e][1] for e in ents) / len(ents)
        rel_xy[rel] = (x, y)
        w = max(1.9, text_w(rel) * 1.35)
        nodes[rel] = dict(x=x, y=y, w=w, h=0.95)
        for ent in dict.fromkeys(p[0] for p in parts):
            segs.append((x, y, POS[ent][0], POS[ent][1]))

    # directions (degrees) of each owner's relationship lines
    busy = {k: [] for k in nodes}
    for (x1, y1, x2, y2) in segs:
        for (ax, ay, bx, by) in ((x1, y1, x2, y2), (x2, y2, x1, y1)):
            for k, n in nodes.items():
                if abs(n["x"] - ax) < 1e-9 and abs(n["y"] - ay) < 1e-9:
                    busy[k].append(math.degrees(math.atan2(by - ay, bx - ax)) % 360)

    attrs_out = []   # (id, label, kind, stored, owner_id)
    placed = []      # boxes already fixed: entities, diamonds, attributes
    placed.extend(nodes.values())
    attr_segs = []   # owner -> attribute lines already drawn

    def boxes_hit(a, b, pad=0.12):
        return (abs(a["x"] - b["x"]) * 2 < a["w"] + b["w"] + pad and
                abs(a["y"] - b["y"]) * 2 < a["h"] + b["h"] + pad)

    def seg_hits_box(sg, n, pad=0.05):
        x1, y1, x2, y2 = sg
        xmin, xmax = n["x"] - n["w"] / 2 - pad, n["x"] + n["w"] / 2 + pad
        ymin, ymax = n["y"] - n["h"] / 2 - pad, n["y"] + n["h"] / 2 + pad
        t0, t1, dx, dy = 0.0, 1.0, x2 - x1, y2 - y1
        for pp, q in ((-dx, x1 - xmin), (dx, xmax - x1), (-dy, y1 - ymin), (dy, ymax - y1)):
            if pp == 0:
                if q < 0:
                    return False
            else:
                t = q / pp
                if pp < 0:
                    t0 = max(t0, t)
                else:
                    t1 = min(t1, t)
                if t0 > t1:
                    return False
        return True

    def spot_free(box, owner_box, line_from):
        if any(boxes_hit(box, o) for o in placed):
            return False
        if any(seg_hits_box(sg, box) for sg in segs + attr_segs):
            return False
        # this attribute's own line must not run through anything else
        line = (line_from[0], line_from[1], box["x"], box["y"])
        return not any(o is not owner_box and seg_hits_box(line, o, -0.02) for o in placed)

    def find_spot(owner_box, ang, base, w):
        """Try the preferred direction first, then swing a little either
        side and step outwards, until a free spot turns up."""
        swings = sorted(range(-90, 91, 6), key=abs)
        for r_step in range(0, 31):
            r = base + r_step * 0.2
            for d in swings:
                a = math.radians(ang + d)
                box = dict(x=owner_box["x"] + r * math.cos(a), y=owner_box["y"] + r * math.sin(a),
                           w=w, h=ATTR_H)
                if spot_free(box, owner_box, (owner_box["x"], owner_box["y"])):
                    return box, ang + d
        a = math.radians(ang)
        return dict(x=owner_box["x"] + base * math.cos(a), y=owner_box["y"] + base * math.sin(a),
                    w=w, h=ATTR_H), ang

    def find_spot_ring(owner, owner_box, base, w, taken):
        """Nearest free spot around the owner, preferring the direction that is
        farthest from the owner's relationship lines and its other attributes."""
        rays = busy[owner] + taken
        def gap(a):
            return min([min(abs(a - b), 360 - abs(a - b)) for b in rays] or [180])
        cands = sorted(range(0, 360, 5), key=lambda a: -gap(a))
        for r_step in range(0, 36):
            r = base + r_step * 0.2
            for ang in cands:
                if gap(ang) < 7:
                    break
                a = math.radians(ang)
                box = dict(x=owner_box["x"] + r * math.cos(a), y=owner_box["y"] + r * math.sin(a),
                           w=w, h=ATTR_H)
                if spot_free(box, owner_box, (owner_box["x"], owner_box["y"])):
                    return box, ang
        return find_spot(owner_box, cands[0], base, w)

    def place_attrs(owner, attrs):
        ob = nodes[owner]
        # a bigger ring for owners with many attributes, so they fit side by side
        base = max(ob["w"], ob["h"]) / 2 + 0.75 + 0.09 * max(0, len(attrs) - 6)
        taken = []
        # composites first: they need the most room
        attrs = sorted(attrs, key=lambda a: not isinstance(a[0], tuple))
        for a in attrs:
            name, kind = a[0], a[1]
            stored = a[2] if len(a) > 2 else True
            if isinstance(name, tuple):
                cname, kids = name
                cid = nid(owner, cname)
                box, used = find_spot_ring(owner, ob, base + 0.4, text_w(cname) + 1.6, taken)
                box["w"] = text_w(cname)
                taken.append(used)
                nodes[cid] = box
                placed.append(box)
                attr_segs.append((ob["x"], ob["y"], box["x"], box["y"]))
                attrs_out.append((cid, cname, kind, stored, owner))
                for j, kid in enumerate(kids):
                    kang = used + (j - (len(kids) - 1) / 2) * 50
                    kid_id = nid(owner, kid)
                    kbox, _ = find_spot(box, kang, 0.95, text_w(kid))
                    nodes[kid_id] = kbox
                    placed.append(kbox)
                    attr_segs.append((box["x"], box["y"], kbox["x"], kbox["y"]))
                    attrs_out.append((kid_id, kid, A, True, cid))
            else:
                aid = nid(owner, name)
                label = name + ("*" if kind == D and not stored else "") + (" †" if kind == AL else "")
                box, used = find_spot_ring(owner, ob, base, text_w(label), taken)
                taken.append(used)
                nodes[aid] = box
                placed.append(box)
                attr_segs.append((ob["x"], ob["y"], box["x"], box["y"]))
                attrs_out.append((aid, label, kind, stored, owner))

    # owners with the most attributes choose first
    owners = [(e, v[1]) for e, v in ER_ENTITIES.items()] + \
             [(r, v[2]) for r, v in ER_RELATIONSHIPS.items() if v[2]]
    for owner, attrs in sorted(owners, key=lambda o: -len(o[1])):
        place_attrs(owner, attrs)

    leftover = [k for k, n in nodes.items() if k not in POS and k not in ER_RELATIONSHIPS
                and any(o is not n and boxes_hit(n, o, 0.0) for o in placed)]
    return nodes, attrs_out, rel_xy, leftover


def draw_er():
    nodes, attrs_out, rel_xy, leftover = er_layout()
    if leftover:
        print("  note: some ER attributes still touch:", ", ".join(leftover))
    pt = lambda v: round(v * 72, 1)
    L = ['graph er {',
         f'  graph [splines=line, outputorder=edgesfirst, pad=0.6, fontname="{FONT}", fontsize=34,'
         f' labelloc=t, label=<<B>SANCHARI — ER DIAGRAM (Chen notation)</B><BR/><FONT POINT-SIZE="19">'
         f'16 entities · 20 relationships · checked against the database by build_diagrams.py'
         f'</FONT><BR/> >];',
         f'  node [fontname="{FONT}", fontsize=11, fixedsize=false];',
         f'  edge [color="#4a5568", penwidth=1.1, fontname="{FONT}", fontsize=15, fontcolor="#111827"];']

    for ent, (weak, _a) in ER_ENTITIES.items():
        head, fill = GROUP[TABLE_GROUP[ent.lower()]]
        n = nodes[ent]
        L.append(f'  {ent} [shape=box, peripheries={2 if weak else 1}, label="{ent}", style=filled,'
                 f' fillcolor="{fill}", color="{head}", penwidth=2, fontsize=15,'
                 f' margin="0.18,0.10", pos="{pt(n["x"])},{pt(n["y"])}!"];')

    for rel, (ident, parts, _a, _t, _f) in ER_RELATIONSHIPS.items():
        n = nodes[rel]
        label = "CONNECTED BY\\n(ternary)" if rel == "CONNECTED_BY" else rel.replace("_", " ")
        L.append(f'  {rel} [shape=diamond, peripheries={2 if ident else 1}, label="{label}",'
                 f' style=filled, fillcolor="#fbe9ea", color="#8b3a3a", fontcolor="#6b1f1f",'
                 f' fontsize=11, margin="0.02,0.02", pos="{pt(n["x"])},{pt(n["y"])}!"];')
        seen = {}
        for ent, card, total, role in parts:
            seen[ent] = seen.get(ent, 0) + 1
            lab = card + (f" ({role})" if role else "")
            pw = 3.6 if total else 1.2
            ports = ""
            if role:  # the two PLACE lines of the ternary: split them apart
                ports = ', tailport=w, headport=sw' if seen[ent] == 1 else ', tailport=n, headport=s'
            L.append(f'  {rel} -- {ent} [penwidth={pw}, label=< <B>{lab}</B> >{ports}];')

    for aid, label, kind, stored, owner in attrs_out:
        n = nodes[aid]
        p = f'pos="{pt(n["x"])},{pt(n["y"])}!"'
        if kind == K:
            style = (f'label=<<U>{label}</U>>, style=filled, fillcolor="#d9efe2", color="#1e6b4a",'
                     f' fontcolor="#0b3d24", penwidth=1.5')
        elif kind == P:
            style = f'label=<<U>{label}</U>>, style="dashed,filled", fillcolor="white", color="#1f2937", penwidth=1.3'
        elif kind == D:
            style = f'label="{label}", style="dashed,filled", fillcolor="#fff6dc", color="#b7791f", fontcolor="#7a4f0b", penwidth=1.3'
        elif kind == AL:
            style = f'label="{label}", style=filled, fillcolor="#e3f5f3", color="#0f766e", fontcolor="#0f4f4a", penwidth=1.3'
        else:
            style = f'label="{label}", style=filled, fillcolor="white", color="#3b5b85"'
        L.append(f'  {aid} [shape=ellipse, height=0.36, margin="0.06,0.02", {style}, {p}];')
        L.append(f'  {owner} -- {aid} [color="#7b8794", penwidth=0.9];')

    key = ('<TABLE BORDER="1" COLOR="#1f3a5f" CELLBORDER="0" CELLPADDING="6" BGCOLOR="white">'
           '<TR><TD COLSPAN="2" BGCOLOR="#1f3a5f"><FONT COLOR="white" POINT-SIZE="16"><B>NOTATION KEY</B></FONT></TD></TR>'
           '<TR><TD ALIGN="LEFT">rectangle</TD><TD ALIGN="LEFT">strong entity</TD></TR>'
           '<TR><TD ALIGN="LEFT">double rectangle</TD><TD ALIGN="LEFT">weak entity</TD></TR>'
           '<TR><TD ALIGN="LEFT">diamond</TD><TD ALIGN="LEFT">relationship</TD></TR>'
           '<TR><TD ALIGN="LEFT">double diamond</TD><TD ALIGN="LEFT">identifying relationship (owner → weak entity)</TD></TR>'
           '<TR><TD ALIGN="LEFT">ellipse</TD><TD ALIGN="LEFT">attribute</TD></TR>'
           '<TR><TD ALIGN="LEFT"><FONT COLOR="#0b3d24"><U>green, underlined</U></FONT></TD><TD ALIGN="LEFT">primary key</TD></TR>'
           '<TR><TD ALIGN="LEFT">dashed, <U>underlined</U></TD><TD ALIGN="LEFT">partial key of a weak entity</TD></TR>'
           '<TR><TD ALIGN="LEFT"><FONT COLOR="#7a4f0b">amber dashed ellipse</FONT></TD><TD ALIGN="LEFT">derived attribute (stored, kept up to date)</TD></TR>'
           '<TR><TD ALIGN="LEFT"><FONT COLOR="#7a4f0b">name*</FONT></TD><TD ALIGN="LEFT">derived, calculated when read (no column)</TD></TR>'
           '<TR><TD ALIGN="LEFT">ellipse with children</TD><TD ALIGN="LEFT">composite attribute</TD></TR>'
           '<TR><TD ALIGN="LEFT"><FONT COLOR="#0f4f4a">teal, name †</FONT></TD><TD ALIGN="LEFT">added later by ALTER (05a / 05b)</TD></TR>'
           '<TR><TD ALIGN="LEFT"><B>thick line</B></TD><TD ALIGN="LEFT">total participation (every row must take part)</TD></TR>'
           '<TR><TD ALIGN="LEFT">thin line</TD><TD ALIGN="LEFT">partial participation (may take part)</TD></TR>'
           '<TR><TD ALIGN="LEFT">1 / N / M / P</TD><TD ALIGN="LEFT">cardinality ratio</TD></TR>'
           '</TABLE>')
    L.append(f'  legend [shape=plaintext, label=<{key}>, pos="{pt(-16.5)},{pt(-24.5)}!"];')
    L.append('}')
    return "\n".join(L)


# ======================================================================
#  6. RUN
# ======================================================================

def render(dot_src, stem, engine):
    for fmt, extra in (("svg", []), ("png", ["-Gdpi=110"])):
        res = subprocess.run([*engine.split(), f"-T{fmt}", *extra, "-o", str(OUT / f"{stem}.{fmt}")],
                             input=dot_src, capture_output=True, text=True)
        if res.returncode != 0:
            sys.exit(f"Graphviz failed on {stem}.{fmt}:\n{res.stderr}")
    print(f"  wrote {stem}.png and {stem}.svg")


def main():
    tables, cons = read_catalog()
    problems = check(tables, cons)
    n_fk = sum(1 for c in cons if c["type"] == "f")
    print(f"Database: {len(tables)} tables, {n_fk} foreign keys, "
          f"{sum(len(c) for c in tables.values())} columns")
    if problems:
        print("\nThe ER design does NOT match the database:")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print("ER design matches the database: every column drawn, every FK mapped, "
          "every participation line agrees with NOT NULL.")
    render(draw_schema(tables, cons), "relational_schema", "dot")
    render(draw_er(), "er_diagram", "neato -n2")


if __name__ == "__main__":
    main()

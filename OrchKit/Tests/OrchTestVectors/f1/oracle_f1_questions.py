"""Independent oracle, questions (ticket-format §5.6, §5.6.1; design #1123 rev 4): the question hash, the refused
shapes, the answer rules, the pinned fold and blank sets, and one question in its three forms (raw event, read-view
item, hub needs). Standard library only; nothing here imports ``orch``.

These are the frozen fixtures that core, hub (D-hub), the phone (D-mob-1) and the dashboard (C) share:
``tests/vectors/f1/hashes.json`` keys ``question_hash``, ``question_hash_refused``, ``question_answers``,
``question_fold``, ``question_blank``; ``tests/vectors/f1/questions.json`` key ``forms``.

The recipe, written out: ``H("orch/v2/question|" || cj({"question_id": qid, "ticket": uid, "text": q.text,
"options": q.options or [], "spec": {every key of q except id, to, blocking, text, options}}))``. ``spec`` always
holds ``kind``. A client that has a read view hashes ``{question_id, ticket, text, options, spec}`` exactly as the
view gives them; it never rebuilds ``spec`` from other view keys.
"""

from __future__ import annotations

import copy
import hashlib
import json
from typing import Any

W = "0123456789abcdef0123456789abcdef"
UID = "01J9ZK4Q7M3R8T2V6X0B5N1C9D"
P_SEV = "p_" + "5e" * 16
P_MARA = "p_" + "3a" * 16
ROUTING = ("id", "to", "blocking")


def cj(o: Any) -> bytes:
    return json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def qid_of(qn: str, ticket: str = UID) -> str:
    return hashlib.sha256(
        b"orch/v2/question-id|" + cj({"workspace_id": W, "ticket": ticket, "question": qn})
    ).hexdigest()[:32]


def spec_of(q: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in q.items() if k not in ROUTING and k not in ("text", "options")}


def hashed(qid: str, ticket: str, q: dict[str, Any]) -> dict[str, Any]:
    return {
        "question_id": qid,
        "ticket": ticket,
        "text": q["text"],
        "options": q.get("options", []),
        "spec": spec_of(q),
    }


def qhash(qid: str, ticket: str, q: dict[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(b"orch/v2/question|" + cj(hashed(qid, ticket, q))).hexdigest()


def _q(kind: str, text: str = "Which tariff export is the source of truth?", **kw: Any) -> dict[str, Any]:
    return {"id": "Q1", "to": "ticket_owner", "text": text, "kind": kind, "blocking": True, **kw}


def _opts(n: int = 2) -> list[dict[str, Any]]:
    base = [
        {"key": "csv", "label": "Monthly CSV"},
        {"key": "api", "label": "Tariff API"},
        {"key": "pdf", "label": "PDF report"},
        {"key": "xls", "label": "Spreadsheet"},
        {"key": "xml", "label": "XML feed"},
        {"key": "manual", "label": "Typed in by hand"},
        {"key": "seventh", "label": "Seventh"},
    ]
    return copy.deepcopy(base[:n])


FULL = _q(
    "choice",
    "Which export should feed the tariff tables?\nPick the one we keep.",
    why="The seeds are stale.",
    details="If you pick CSV, we import monthly.\n\tAPI means a daily pull.",
    options=[
        {
            "key": "csv",
            "label": "Monthly CSV",
            "text": "One file a month, checked by hand",
            "facts": [["Effort", "\u00bd day"], ["Cost", "CHF 400"]],
            "cost": "\u00bd day",
        },
        {"key": "api", "label": "Tariff API", "text": "Daily pull, no manual step", "facts": [["Effort", "2 days"]]},
        {"key": "other", "label": "Keep the old seeds"},
    ],
    recommended="csv",
    allow_other=True,
)


def positive_questions() -> list[tuple[str, str, dict[str, Any]]]:
    """(name, note, raw question). Every one hashes; the tamper variants each differ from ``choice_full``."""
    out: list[tuple[str, str, dict[str, Any]]] = [
        (
            "choice_full",
            "every field: why, details (multi-line, tab), text, facts, cost, recommended, allow_other",
            FULL,
        ),
        ("choice_minimal", "two options with key and title only", _q("choice", options=_opts())),
        ("text_minimal", "an open question: kind text, no options (hashed options [])", _q("text", "Which bank?")),
        (
            "text_with_why_and_details",
            "a text question with why and details",
            _q("text", "Which bank?", why="For the invoice.", details="IBAN or name is fine."),
        ),
        ("choice_six_options", "the most options", _q("choice", options=_opts(6))),
        (
            "choice_at_every_limit",
            "question 140, key 32, title 60, text 200, 3 facts 24/40, details 1500, cost 60",
            _q(
                "choice",
                "q" * 140,
                details="d" * 1500,
                options=[
                    {
                        "key": "k" * 32,
                        "label": "T" * 60,
                        "text": "x" * 200,
                        "cost": "c" * 60,
                        "facts": [["A" * 24, "v" * 40], ["B" * 24, "v" * 40], ["C" * 24, "v" * 40]],
                    },
                    {"key": "b", "label": "Second"},
                ],
            ),
        ),
        (
            "choice_unicode",
            "NFC non-ASCII, a supplementary character, a key named other",
            _q(
                "choice",
                "Welcher Export gilt? Gr\u00f6\u00dfe \u2264 5 MB \U0001f4c8",
                options=[
                    {"key": "other", "label": "Z\u00fcrich \u00e9t\u00e9"},
                    {"key": "b", "label": "\u0391\u03b8\u03ae\u03bd\u03b1"},
                ],
            ),
        ),
        (
            "choice_options_swapped",
            "order: the same options swapped is another hash",
            _q("choice", options=list(reversed(_opts()))),
        ),
    ]
    tampers: list[tuple[str, Any]] = [
        ("text", lambda q: q.update(text="Which export should feed the tariff tables?")),
        ("why", lambda q: q.update(why="The seeds are old.")),
        ("why_removed", lambda q: q.pop("why")),
        ("details", lambda q: q.update(details="If you pick CSV, we import weekly.")),
        ("details_removed", lambda q: q.pop("details")),
        ("recommended", lambda q: q.update(recommended="api")),
        ("recommended_removed", lambda q: q.pop("recommended")),
        ("allow_other_removed", lambda q: q.pop("allow_other")),
        ("option_label", lambda q: q["options"][0].update(label="Monthly CSV file")),
        ("option_text", lambda q: q["options"][0].update(text="One file a month")),
        ("option_text_removed", lambda q: q["options"][0].pop("text")),
        ("option_key", lambda q: [q["options"][0].update(key="csv_file"), q.update(recommended="csv_file")]),
        ("option_cost", lambda q: q["options"][0].update(cost="1 day")),
        ("fact_value", lambda q: q["options"][0]["facts"][1].__setitem__(1, "CHF 500")),
        ("fact_label", lambda q: q["options"][0]["facts"][1].__setitem__(0, "Price")),
        ("fact_order", lambda q: q["options"][0]["facts"].reverse()),
        ("facts_removed", lambda q: q["options"][0].pop("facts")),
        ("option_order", lambda q: q["options"].reverse()),
        ("kind_text", lambda q: [q.update(kind="text"), q.pop("options"), q.pop("recommended"), q.pop("allow_other")]),
    ]
    for name, f in tampers:
        q = copy.deepcopy(FULL)
        f(q)
        out.append(
            (f"choice_full_tamper_{name}", f"choice_full with {name.replace('_', ' ')} changed: another hash", q)
        )
    return out


def routing_variants() -> list[tuple[str, dict[str, Any]]]:
    """Re-asks that change only routing (to, blocking): the SAME hash as ``choice_full``, so an answer stands."""
    return [
        ("choice_full_reask_to", {**FULL, "to": P_MARA}),
        ("choice_full_reask_blocking", {**FULL, "blocking": False}),
    ]


def refused_questions() -> list[tuple[str, Any]]:
    """(name, raw question) that the one validator refuses (hash, sign, replay)."""

    def m(f: Any, base: dict[str, Any] = FULL) -> dict[str, Any]:
        q = copy.deepcopy(base)
        f(q)
        return q

    def opt0(**kw: Any) -> Any:
        return lambda q: q["options"][0].update(kw)

    def titles(a: str, b: str) -> dict[str, Any]:
        return _q("choice", options=[{"key": "a", "label": a}, {"key": "b", "label": b}])

    text_q = _q("text", "Which bank?")
    return [
        (
            "legacy_shape_without_kind",
            {
                "id": "Q1",
                "to": "ticket_owner",
                "text": "Ok?",
                "blocking": True,
                "options": [{"key": "a", "label": "A"}, {"key": "b", "label": "B"}],
            },
        ),
        ("legacy_text_only_without_kind", {"id": "Q1", "to": "ticket_owner", "text": "Ok?", "blocking": True}),
        ("kind_null", m(lambda q: q.update(kind=None))),
        ("kind_unknown", m(lambda q: q.update(kind="date"))),
        ("not_an_object", ["Q1"]),
        ("missing_blocking", m(lambda q: q.pop("blocking"))),
        ("unknown_question_key", m(lambda q: q.update(value="x"))),
        ("unknown_option_key", m(opt0(value="x"))),
        ("choice_without_options", m(lambda q: [q.pop("options"), q.pop("recommended")])),
        ("choice_one_option", _q("choice", options=_opts(1))),
        ("choice_seven_options", _q("choice", options=_opts(7))),
        ("text_with_options", {**text_q, "options": _opts()}),
        ("text_with_recommended", {**text_q, "recommended": "csv"}),
        ("text_with_allow_other", {**text_q, "allow_other": True}),
        ("allow_other_false", m(lambda q: q.update(allow_other=False))),
        ("allow_other_null", m(lambda q: q.update(allow_other=None))),
        ("recommended_not_a_key", m(lambda q: q.update(recommended="pdf"))),
        ("question_empty", m(lambda q: q.update(text=""))),
        ("question_141", m(lambda q: q.update(text="q" * 141))),
        ("question_whitespace_only_nbsp_ideographic", m(lambda q: q.update(text="\u00a0\u3000 "))),
        ("question_not_nfc", m(lambda q: q.update(text="cafe\u0301?"))),
        ("question_crlf", m(lambda q: q.update(text="a\r\nb"))),
        ("question_zero_width", m(lambda q: q.update(text="Pick\u200bone"))),
        ("question_bidi", m(lambda q: q.update(text="Pick \u202eone"))),
        ("why_empty", m(lambda q: q.update(why=""))),
        ("details_empty", m(lambda q: q.update(details=""))),
        ("details_1501", m(lambda q: q.update(details="d" * 1501))),
        ("details_over_4096_bytes", m(lambda q: q.update(details="\u20ac" * 1400))),
        ("details_private_use", m(lambda q: q.update(details="see \ue000"))),
        ("option_title_empty", m(opt0(label=""))),
        ("option_title_61", m(opt0(label="T" * 61))),
        ("option_title_line_feed", m(opt0(label="Monthly\nCSV"))),
        ("option_title_tab", m(opt0(label="Monthly\tCSV"))),
        ("option_title_leading_mark", m(opt0(label="\u0301Monthly"))),
        ("option_title_zero_width_joiner", m(opt0(label="Monthly\u200dCSV"))),
        ("option_text_empty", m(opt0(text=""))),
        ("option_text_201", m(opt0(text="x" * 201))),
        ("option_cost_empty", m(opt0(cost=""))),
        ("option_cost_61", m(opt0(cost="c" * 61))),
        ("facts_empty_list", m(opt0(facts=[]))),
        ("facts_object_form", m(opt0(facts={"Effort": "1 day"}))),
        ("facts_four", m(opt0(facts=[["A", "1"], ["B", "2"], ["C", "3"], ["D", "4"]]))),
        ("fact_three_items", m(opt0(facts=[["A", "1", "x"]]))),
        ("fact_one_item", m(opt0(facts=[["A"]]))),
        ("fact_label_empty", m(opt0(facts=[["", "1"]]))),
        ("fact_value_empty", m(opt0(facts=[["A", ""]]))),
        ("fact_label_25", m(opt0(facts=[["A" * 25, "1"]]))),
        ("fact_value_41", m(opt0(facts=[["A", "v" * 41]]))),
        ("fact_value_not_text", m(opt0(facts=[["A", 1]]))),
        ("fact_labels_same_after_fold", m(opt0(facts=[["Cost", "1"], ["COST", "2"]]))),
        ("key_duplicate", m(lambda q: q["options"][1].update(key="csv"))),
        ("key_uppercase", m(opt0(key="CSV"))),
        ("key_ordinal_digit", m(opt0(key="1"))),
        ("key_33", m(opt0(key="k" * 33))),
        ("titles_same_exactly", titles("Yes", "Yes")),
        ("titles_same_case", titles("Monthly CSV", "monthly csv")),
        ("titles_fold_sharp_s", titles("Stra\u00dfe", "STRASSE")),
        ("titles_fold_capital_sharp_s", titles("\u1e9e", "ss")),
        ("titles_fold_long_s", titles("\u017fun", "sun")),
        ("titles_fold_kelvin", titles("\u212aelvin", "kelvin")),
        ("titles_fold_fi_ligature", titles("\ufb01le", "FILE")),
        ("titles_fold_final_sigma", titles("\u03c3\u03c2", "\u03a3\u03a3")),
        ("titles_fold_dotted_capital_i", titles("\u0130stanbul", "i\u0307stanbul")),
    ]


def answers() -> list[dict[str, Any]]:
    """Answer rules per kind (``option`` / ``text``, absent = not given)."""
    choice_no_other = _q("choice", options=_opts())
    text_q = _q("text", "Which bank?")
    rows = [
        ("choice_option", FULL, {"option": "csv"}, True),
        ("choice_option_with_note", FULL, {"option": "api", "text": "but only after the audit"}, True),
        ("choice_real_key_other", FULL, {"option": "other"}, True),
        ("choice_other_text_with_allow_other", FULL, {"text": "Ask the bank first"}, True),
        ("choice_other_text_without_allow_other", choice_no_other, {"text": "Ask the bank first"}, False),
        ("choice_neither", FULL, {}, False),
        ("choice_unknown_option", FULL, {"option": "pdf"}, False),
        ("choice_note_whitespace_only", FULL, {"option": "csv", "text": " \u00a0\u3000"}, False),
        ("choice_other_1000", FULL, {"text": "a" * 1000}, True),
        ("choice_other_1001", FULL, {"text": "a" * 1001}, False),
        ("choice_other_1000_supplementary", FULL, {"text": "\U0001f600" * 1000}, True),
        ("choice_other_zero_width", FULL, {"text": "ok\u200b"}, False),
        ("choice_other_with_tab_and_lines", FULL, {"text": "line 1\n\tline 2"}, True),
        ("choice_other_not_nfc", FULL, {"text": "cafe\u0301"}, False),
        ("text_answer", text_q, {"text": "UBS"}, True),
        ("text_answer_option", text_q, {"option": "csv"}, False),
        ("text_answer_option_and_text", text_q, {"option": "csv", "text": "UBS"}, False),
        ("text_answer_neither", text_q, {}, False),
        ("text_answer_ideographic_space_only", text_q, {"text": "\u3000"}, False),
    ]
    return [{"name": n, "question": q, **a, "ok": ok} for n, q, a, ok in rows]


def fold_pairs() -> list[dict[str, Any]]:
    """Pinned ``fold = NFC(full case fold C+F, Unicode 16.0 (NFC(s)))``; ``folded`` is the literal result."""
    rows = [
        ("Stra\u00dfe", "strasse"),
        ("\u1e9e", "ss"),
        ("\u017f", "s"),
        ("\u212a", "k"),
        ("\ufb01", "fi"),
        ("\u03c2", "\u03c3"),
        ("\u03a3", "\u03c3"),
        ("\u0130", "i\u0307"),
        ("Cafe\u0301", "caf\u00e9"),
        ("\U00010400", "\U00010428"),
    ]
    return [{"text": a, "folded": b} for a, b in rows]


def blank_cases() -> list[dict[str, Any]]:
    """Unicode White_Space (PropList 16.0) decides "only whitespace"; ZWSP is not White_Space (it is refused as an
    invisible instead)."""
    rows = [
        ("", True),
        (" ", True),
        ("\u00a0", True),
        ("\u3000", True),
        ("\u2028\u2029", True),
        ("\u1680\u202f\u205f", True),
        ("\u200b", False),
        ("\u180e", False),
        ("a", False),
    ]
    return [{"text": t, "blank": b} for t, b in rows]


def hash_vectors() -> dict[str, Any]:
    qid = qid_of("Q1")
    pos = []
    for name, note, q in positive_questions():
        pos.append(
            {
                "name": name,
                "note": note,
                "qid": qid,
                "ticket": UID,
                "question": q,
                "hashed": hashed(qid, UID, q),
                "hash": qhash(qid, UID, q),
            }
        )
    full = qhash(qid, UID, FULL)
    for name, q in routing_variants():
        assert qhash(qid, UID, q) == full
        pos.append(
            {
                "name": name,
                "note": "only routing changed (to or blocking): the same hash as choice_full",
                "qid": qid,
                "ticket": UID,
                "question": q,
                "hashed": hashed(qid, UID, q),
                "hash": full,
                "same_as": "choice_full",
            }
        )
    hashes = [p["hash"] for p in pos if "same_as" not in p]
    assert len(set(hashes)) == len(hashes)
    return {
        "question_hash": pos,
        "question_hash_refused": [{"name": n, "question": q} for n, q in refused_questions()],
        "question_answers": answers(),
        "question_fold": fold_pairs(),
        "question_blank": blank_cases(),
    }


def forms() -> list[dict[str, Any]]:
    """One choice and one text question in the three forms that carry a question, each with its hash.

    * ``raw_event``: the ``question.asked`` core (``question``, ``qid``, ``hash``): what is signed and replayed.
    * ``read_item``: a ``ticket.get`` Question item (host reads): enriched with state and asked_* keys; ``options``
      verbatim (absent for a text question) and ``spec`` verbatim; no top-level ``why``/``recommended``/``kind``.
    * ``hub_needs``: a hub needs row and its content: ``options`` verbatim (absent for a text question) and ``spec``.

    In every form the hash is ``qhash`` over ``{question_id, ticket, text, options or [], spec}`` as given."""
    out = []
    asked_by = {
        "kind": "agent",
        "id": "a_" + "1" * 32,
        "session": "s_" + "2" * 32,
        "for": P_SEV,
        "grant": "g_" + "3" * 32,
    }
    for name, q in (("choice_full", FULL), ("text_with_why_and_details", positive_questions()[3][2])):
        qid = qid_of(q["id"])
        hh = qhash(qid, UID, q)
        spec = spec_of(q)
        item: dict[str, Any] = {
            "id": q["id"],
            "state": "open",
            "to": [P_SEV],
            "blocking": q["blocking"],
            "answered_by": None,
            "answered_seq": None,
            "text": q["text"],
            "to_ref": q["to"],
        }
        if "options" in q:
            item["options"] = copy.deepcopy(q["options"])
        item.update(
            {
                "spec": copy.deepcopy(spec),
                "asked_at": "2026-10-23T12:00:00Z",
                "asked_by": asked_by,
                "asked_seq": 2,
                "qid": qid,
                "hash": hh,
            }
        )
        content: dict[str, Any] = {"ticket_title": "Tariff seeds", "question": q["id"], "text": q["text"]}
        if "options" in q:
            content["options"] = copy.deepcopy(q["options"])
        content.update({"spec": copy.deepcopy(spec), "blocking": q["blocking"], "short_hash": hh[7:19]})
        out.append(
            {
                "name": name,
                "ticket": UID,
                "raw_event": {"type": "question.asked", "question": copy.deepcopy(q), "qid": qid, "hash": hh},
                "read_item": item,
                "hub_needs": {
                    "row": {
                        "item_id": qid,
                        "kind": "question",
                        "type": "question",
                        "key": "DEMO-0001",
                        "title": q["text"].split("\n")[0],
                        "deadline": None,
                        "log": UID,
                        "hash": hh,
                    },
                    "content": content,
                },
            }
        )
    return out

"""Deterministic recommendation engine (default provider and fallback when no LLM is available).

Each recommendation is evidence-driven: it is proposed only when the profile shows real records that would violate it.
Output is always a Rule AST - never SQL.
"""
from __future__ import annotations

from typing import Optional

from .models import EntityProfile, SuggestRequest



def _drop_he(name: str) -> str:
    """Hebrew grammar: the prefix ל absorbs the definite article ה (ל + המחלקה = למחלקה)."""
    return name[1:] if name.startswith("ה") and len(name) > 1 else name

def _cmp(node_id: str, path: list[str], op: str, right: Optional[dict] = None, scope: Optional[str] = None) -> dict:
    left: dict = {"kind": "field", "path": path}
    if scope:
        left["scope"] = scope
    node = {"type": "comparison", "id": node_id, "left": left, "operator": op}
    if right is not None:
        node["right"] = right
    return node


def _group(node_id: str, logic: str, children: list[dict]) -> dict:
    return {"type": "group", "id": node_id, "logic": logic, "negate": False, "children": children}


def _pct(n: int, total: int) -> str:
    return f"{n:,} רשומות ({n / total:.1%})" if total else f"{n:,} רשומות"


def heuristic_suggestions(request: SuggestRequest, profiles: list[EntityProfile]) -> list[dict]:
    out: list[dict] = []
    for p in profiles:
        e = request.entity(p.entity_key)
        if e is None or p.row_count == 0:
            continue
        plural = e.displayNamePlural

        # 1) date ranges that end before they start
        for d in p.date_pairs:
            if d.violations == 0:
                continue
            s, en = e.field(d.start_key), e.field(d.end_key)
            out.append({
                "title": f"{en.displayName} מוקדם מ{s.displayName}",
                "explanationHe": f"ב{plural}, {en.displayName} אמור להיות אחרי {s.displayName}. "
                                 f"רשומה שבה הסדר הפוך מעידה על שגיאת הזנה ופוגעת בחישובי ותק ועלויות.",
                "evidence": f"נמצאו {_pct(d.violations, p.row_count)} שבהן {en.displayName} מוקדם מ{s.displayName}.",
                "severity": "High",
                "definition": {"schemaVersion": 1, "rootEntity": e.key,
                               "condition": _group("g1", "and", [_cmp("c1", [d.end_key], "lt", {"kind": "field", "path": [d.start_key]})])},
            })

        # 2) records linked to an inactive parent
        for f in p.inactive_parents:
            if f.violations == 0:
                continue
            rel = e.relationship(f.relation_key)
            children = ([f.root_active_condition] if f.root_active_condition else []) + \
                       [_cmp("c1", f.active_field_path, "eq", {"kind": "value", "value": False})]
            prefix = "פעילים " if f.root_active_condition else ""
            out.append({
                "title": f"{plural} {prefix}המשויכים ל{_drop_he(rel.displayName)} במצב לא פעיל".replace("  ", " "),
                "explanationHe": f"{plural} {prefix}לא אמורים להיות משויכים ל{_drop_he(rel.displayName)} במצב לא פעיל. "
                                 "שיוך כזה מצביע על עדכון חסר לאחר סגירה או שינוי מבני.",
                "evidence": f"נמצאו {_pct(f.violations, p.row_count)} כאלה.",
                "severity": "Medium",
                "definition": {"schemaVersion": 1, "rootEntity": e.key, "condition": _group("g1", "and", children)},
            })

        # 3) child records that start before the parent record
        for f in p.child_before_parent:
            if f.violations == 0:
                continue
            rel = e.relationship(f.relation_key)
            child_entity = request.entity(rel.toEntity)
            child_field = child_entity.field(f.child_date_key) if child_entity else None
            parent_field = e.field(f.parent_date_key)
            out.append({
                "title": f"{rel.displayName} שמתחילים לפני {parent_field.displayName}",
                "explanationHe": f"{child_field.displayName if child_field else 'תאריך ההתחלה'} של רשומה ב{rel.displayName} "
                                 f"לא אמור להיות מוקדם מ{parent_field.displayName}. רשומה כזו אינה אפשרית עסקית.",
                "evidence": f"נמצאו {_pct(f.violations, p.row_count)} עם לפחות רשומה קשורה כזו.",
                "severity": "Medium",
                "definition": {"schemaVersion": 1, "rootEntity": e.key, "condition": _group("g1", "and", [{
                    "type": "collection", "id": "q1", "relation": f.relation_key, "quantifier": "any",
                    "condition": _cmp("c1", [f.child_date_key], "lt", {"kind": "field", "scope": "root", "path": [f.parent_date_key]}),
                }])},
            })

        # 4) active parents without any child record (only when it is the exception, not the rule)
        for f in p.missing_children:
            if f.violations == 0 or f.violations > 0.2 * p.row_count:
                continue
            rel = e.relationship(f.relation_key)
            children = ([f.root_active_condition] if f.root_active_condition else []) + \
                       [{"type": "collection", "id": "q1", "relation": f.relation_key, "quantifier": "none"}]
            out.append({
                "title": f"{plural} ללא {rel.displayName}",
                "explanationHe": f"לרוב ה{plural} קיימות רשומות ב{rel.displayName}; היעדרן אצל מיעוט מעיד על נתון חסר.",
                "evidence": f"נמצאו {_pct(f.violations, p.row_count)} ללא אף רשומה.",
                "severity": "Low",
                "definition": {"schemaVersion": 1, "rootEntity": e.key, "condition": _group("g1", "and", children)},
            })

        # 5) business-required fields that are empty
        for fld in e.fields:
            fp = p.fields.get(fld.key)
            if not fld.isRequiredByBusiness or fp is None:
                continue
            missing = fp.nulls + fp.empties
            if missing == 0:
                continue
            out.append({
                "title": f"{fld.displayName} חסר",
                "explanationHe": f"{fld.displayName} מוגדר כחובה לפי הכללים העסקיים של {plural}, אך קיימות רשומות שבהן הוא ריק.",
                "evidence": f"נמצאו {_pct(missing, p.row_count)} עם ערך ריק.",
                "severity": "Low",
                "definition": {"schemaVersion": 1, "rootEntity": e.key,
                               "condition": _group("g1", "and", [_cmp("c1", [fld.key], "isEmpty")])},
            })

        # 6) numeric outliers (Tukey fence, 3 x IQR)
        for fld in e.fields:
            fp = p.fields.get(fld.key)
            if fp is None or fp.high_threshold is None or fp.high_outliers == 0:
                continue
            threshold = int(fp.high_threshold) if fld.dataType == "Integer" else round(fp.high_threshold, 2)
            out.append({
                "title": f"{fld.displayName} חריג כלפי מעלה",
                "explanationHe": f"ערכי {fld.displayName} גבוהים במיוחד ביחס להתפלגות (מעל {threshold:,}). "
                                 "ייתכן שמדובר בטעות הקלדה (למשל אפס מיותר) – כדאי לבדוק.",
                "evidence": f"{fp.high_outliers:,} ערכים מעל הסף שחושב לפי טווח בין־רבעוני (Q3 + 3×IQR).",
                "severity": "Low",
                "definition": {"schemaVersion": 1, "rootEntity": e.key,
                               "condition": _group("g1", "and", [_cmp("c1", [fld.key], "gt", {"kind": "value", "value": threshold})])},
            })

    severity_order = {"High": 0, "Medium": 1, "Low": 2}
    out.sort(key=lambda s: severity_order[s["severity"]])
    return out

"""Unit tests: heuristics produce valid ASTs, and the validator rejects malicious / hallucinated LLM output."""
from app.heuristics import heuristic_suggestions
from app.models import DatePairFinding, EntityProfile, FieldProfile, InactiveParentFinding, SuggestRequest
from app.profiler import find_date_pairs
from app.validation import validate_suggestion

CATALOG = {
    "maxSuggestions": 10,
    "entities": [
        {"key": "employee", "displayName": "עובד", "displayNamePlural": "עובדים", "schema": "biz", "table": "Employees", "primaryKey": "Id",
         "fields": [
             {"key": "hireDate", "displayName": "תאריך תחילת העסקה", "column": "HireDate", "dataType": "Date"},
             {"key": "terminationDate", "displayName": "תאריך סיום העסקה", "column": "TerminationDate", "dataType": "Date", "isNullable": True},
             {"key": "email", "displayName": "דוא\"ל", "column": "Email", "dataType": "String", "isNullable": True, "isRequiredByBusiness": True},
             {"key": "salary", "displayName": "שכר", "column": "Salary", "dataType": "Decimal", "isSensitive": True},
             {"key": "status", "displayName": "סטטוס", "column": "Status", "dataType": "Enum",
              "enumValues": [{"value": "A", "displayName": "פעיל"}, {"value": "T", "displayName": "סיים עבודה"}]},
         ],
         "relationships": [
             {"key": "department", "toEntity": "department", "cardinality": "ManyToOne", "fromColumn": "DepartmentId", "toColumn": "Id", "displayName": "המחלקה של העובד"},
         ]},
        {"key": "department", "displayName": "מחלקה", "displayNamePlural": "מחלקות", "schema": "biz", "table": "Departments", "primaryKey": "Id",
         "fields": [{"key": "isActive", "displayName": "פעילה", "column": "IsActive", "dataType": "Boolean"}], "relationships": []},
    ],
}


def request() -> SuggestRequest:
    return SuggestRequest.model_validate(CATALOG)


def profile() -> EntityProfile:
    return EntityProfile(
        entity_key="employee", row_count=200,
        fields={"email": FieldProfile(nulls=2, empties=1), "salary": FieldProfile(high_threshold=30000, high_outliers=2)},
        date_pairs=[DatePairFinding(start_key="hireDate", end_key="terminationDate", violations=2)],
        inactive_parents=[InactiveParentFinding(
            relation_key="department", active_field_path=["department", "isActive"], violations=3,
            root_active_condition={"type": "comparison", "id": "a1", "left": {"kind": "field", "path": ["status"]},
                                   "operator": "eq", "right": {"kind": "value", "value": "A"}})])


def test_every_heuristic_suggestion_is_a_valid_ast():
    req = request()
    suggestions = heuristic_suggestions(req, [profile()])
    assert len(suggestions) == 4
    for s in suggestions:
        parsed, errors = validate_suggestion(s, req)
        assert parsed is not None, errors


def test_high_severity_first_and_evidence_present():
    s = heuristic_suggestions(request(), [profile()])
    assert s[0]["severity"] == "High"
    assert all(x["evidence"] for x in s)


def test_no_suggestion_without_evidence():
    p = profile()
    p.date_pairs[0].violations = 0
    titles = [s["title"] for s in heuristic_suggestions(request(), [p])]
    assert not any("מוקדם" in t for t in titles)


def _suggestion(condition: dict, **extra) -> dict:
    return {"title": "בדיקה", "explanationHe": "הסבר עסקי", "severity": "Low",
            "definition": {"schemaVersion": 1, "rootEntity": "employee", "condition": condition, **extra}}


def test_rejects_sql_smuggled_as_extra_property():
    s = _suggestion({"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["email"]}, "operator": "isEmpty"},
                    sql="DELETE FROM biz.Employees")
    parsed, errors = validate_suggestion(s, request())
    assert parsed is None and errors


def test_rejects_hallucinated_field_and_wrong_operator_and_bad_enum():
    req = request()
    assert validate_suggestion(_suggestion({"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["bonus"]}, "operator": "isEmpty"}), req)[0] is None
    assert validate_suggestion(_suggestion({"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["hireDate"]}, "operator": "contains",
                                            "right": {"kind": "value", "value": "x"}}), req)[0] is None
    assert validate_suggestion(_suggestion({"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["status"]}, "operator": "eq",
                                            "right": {"kind": "value", "value": "X"}}), req)[0] is None


def test_rejects_unknown_operator():
    s = _suggestion({"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["email"]}, "operator": "; DROP TABLE x"})
    assert validate_suggestion(s, request())[0] is None


def test_date_pair_detection():
    req = request()
    pairs = find_date_pairs([f for f in req.entity("employee").fields if f.dataType == "Date"])
    assert [(a.key, b.key) for a, b in pairs] == [("hireDate", "terminationDate")]

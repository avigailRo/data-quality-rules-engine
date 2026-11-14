"""First validation layer for AI output (the authoritative one is the .NET RuleBinder).

1. Schema: the suggestion must parse into the strict Rule AST models (extra fields such as "sql" are rejected).
2. Catalog: every entity / relationship / field key must exist, paths may only traverse many-to-one relationships,
   collections only one-to-many, operators must fit the field type, enum values must be allowed.
"""
from __future__ import annotations

from typing import Optional

from pydantic import ValidationError

from .models import (CatalogEntity, CollectionNode, ComparisonNode, FieldOperand, GroupNode, Suggestion,
                     SuggestRequest, ValueOperand, ValuesOperand)

ALLOWED = {
    "String": {"eq", "neq", "in", "notIn", "contains", "startsWith", "endsWith", "isEmpty", "isNotEmpty"},
    "Integer": {"eq", "neq", "gt", "gte", "lt", "lte", "between", "in", "notIn", "isEmpty", "isNotEmpty"},
    "Decimal": {"eq", "neq", "gt", "gte", "lt", "lte", "between", "in", "notIn", "isEmpty", "isNotEmpty"},
    "Date": {"eq", "neq", "gt", "gte", "lt", "lte", "between", "isEmpty", "isNotEmpty"},
    "DateTime": {"eq", "neq", "gt", "gte", "lt", "lte", "between", "isEmpty", "isNotEmpty"},
    "Boolean": {"eq", "neq", "isEmpty", "isNotEmpty"},
    "Enum": {"eq", "neq", "in", "notIn", "isEmpty", "isNotEmpty"},
}


def validate_suggestion(raw: dict, request: SuggestRequest) -> tuple[Optional[Suggestion], list[str]]:
    try:
        s = Suggestion.model_validate(raw)
    except ValidationError as ex:
        return None, [f"{'.'.join(str(p) for p in err['loc'])}: {err['msg']}" for err in ex.errors()[:10]]

    root = request.entity(s.definition.rootEntity)
    if root is None:
        return None, [f"unknown entity '{s.definition.rootEntity}'"]

    errors: list[str] = []
    ids: set[str] = set()
    _walk(s.definition.condition, root, root, request, errors, ids)
    for path in (s.definition.output.displayFields if s.definition.output else []):
        _resolve(path.split("."), root, request, errors)
    return (s if not errors else None), errors


def _walk(node, scope: CatalogEntity, root: CatalogEntity, req: SuggestRequest, errors: list[str], ids: set[str]) -> None:
    if node.id in ids:
        errors.append(f"duplicate node id '{node.id}'")
    ids.add(node.id)

    if isinstance(node, GroupNode):
        for child in node.children:
            _walk(child, scope, root, req, errors, ids)
    elif isinstance(node, CollectionNode):
        rel = scope.relationship(node.relation)
        if rel is None or rel.cardinality != "OneToMany":
            errors.append(f"'{node.relation}' is not a one-to-many relationship of '{scope.key}'")
            return
        child = req.entity(rel.toEntity)
        if child is None:
            errors.append(f"unknown entity '{rel.toEntity}'")
            return
        if node.condition is not None:
            _walk(node.condition, child, root, req, errors, ids)
    elif isinstance(node, ComparisonNode):
        target = root if node.left.scope == "root" else scope
        field = _resolve(node.left.path, target, req, errors)
        if field is None:
            return
        if node.operator not in ALLOWED.get(field.dataType, set()):
            errors.append(f"operator '{node.operator}' is not allowed for {field.dataType} field '{field.key}'")
        if isinstance(node.right, FieldOperand):
            _resolve(node.right.path, root if node.right.scope == "root" else scope, req, errors)
        values = [node.right.value] if isinstance(node.right, ValueOperand) else \
                 node.right.values if isinstance(node.right, ValuesOperand) else []
        if field.dataType == "Enum":
            allowed = {v.value for v in field.enumValues}
            for v in values:
                if v not in allowed:
                    errors.append(f"value '{v}' is not allowed for '{field.key}'")


def _resolve(path: list[str], entity: CatalogEntity, req: SuggestRequest, errors: list[str]):
    current = entity
    for segment in path[:-1]:
        rel = current.relationship(segment)
        if rel is None or rel.cardinality != "ManyToOne":
            errors.append(f"'{segment}' is not a many-to-one relationship of '{current.key}'")
            return None
        nxt = req.entity(rel.toEntity)
        if nxt is None:
            errors.append(f"unknown entity '{rel.toEntity}'")
            return None
        current = nxt
    field = current.field(path[-1])
    if field is None:
        errors.append(f"unknown field '{path[-1]}' on '{current.key}'")
    return field

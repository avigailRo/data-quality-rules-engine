"""Contracts: the catalog sent by the .NET API, the profile, and the Rule AST (mirror of the .NET Domain AST)."""
from __future__ import annotations

from typing import Annotated, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field


class Camel(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")


# ---------------- catalog (input from .NET) ----------------

class EnumValue(Camel):
    value: str
    displayName: str


class CatalogField(Camel):
    key: str
    displayName: str
    column: Optional[str] = None
    dataType: str
    isNullable: bool = False
    isRequiredByBusiness: bool = False
    isSensitive: bool = False
    isComputed: bool = False
    enumValues: list[EnumValue] = []


class CatalogRelationship(Camel):
    key: str
    toEntity: str
    cardinality: str  # ManyToOne | OneToMany
    fromColumn: str
    toColumn: str
    displayName: str


class CatalogEntity(Camel):
    key: str
    displayName: str
    displayNamePlural: str
    schema_name: str = Field(alias="schema")
    table: str
    primaryKey: str
    fields: list[CatalogField]
    relationships: list[CatalogRelationship] = []

    def field(self, key: str) -> Optional[CatalogField]:
        return next((f for f in self.fields if f.key == key), None)

    def relationship(self, key: str) -> Optional[CatalogRelationship]:
        return next((r for r in self.relationships if r.key == key), None)


class SuggestRequest(Camel):
    maxSuggestions: int = 8
    entities: list[CatalogEntity]

    def entity(self, key: str) -> Optional[CatalogEntity]:
        return next((e for e in self.entities if e.key == key), None)


# ---------------- Rule AST (output) ----------------

class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


Scalar = Union[bool, int, float, str]


class FieldOperand(Strict):
    kind: Literal["field"]
    path: list[str] = Field(min_length=1, max_length=4)
    scope: Optional[Literal["root"]] = None


class ValueOperand(Strict):
    kind: Literal["value"]
    value: Scalar


class ValuesOperand(Strict):
    kind: Literal["values"]
    values: list[Scalar] = Field(min_length=1, max_length=200)


class RangeOperand(Strict):
    kind: Literal["range"]
    from_: Scalar = Field(alias="from")
    to: Scalar


Operand = Annotated[Union[FieldOperand, ValueOperand, ValuesOperand, RangeOperand], Field(discriminator="kind")]

OperatorName = Literal["eq", "neq", "gt", "gte", "lt", "lte", "between", "in", "notIn",
                       "contains", "startsWith", "endsWith", "isEmpty", "isNotEmpty"]


class ComparisonNode(Strict):
    type: Literal["comparison"]
    id: str = Field(min_length=1, max_length=40)
    left: FieldOperand
    operator: OperatorName
    right: Optional[Operand] = None


class GroupNode(Strict):
    type: Literal["group"]
    id: str = Field(min_length=1, max_length=40)
    logic: Literal["and", "or"] = "and"
    negate: bool = False
    children: list["Node"] = Field(min_length=1, max_length=30)


class CollectionNode(Strict):
    type: Literal["collection"]
    id: str = Field(min_length=1, max_length=40)
    relation: str
    quantifier: Literal["any", "none", "all"] = "any"
    condition: Optional["Node"] = None


Node = Annotated[Union[GroupNode, ComparisonNode, CollectionNode], Field(discriminator="type")]


class OutputSpec(Strict):
    displayFields: list[str] = Field(default_factory=list, max_length=10)


class RuleDefinition(Strict):
    schemaVersion: Literal[1] = 1
    rootEntity: str
    condition: Node
    output: Optional[OutputSpec] = None


GroupNode.model_rebuild()
CollectionNode.model_rebuild()
RuleDefinition.model_rebuild()


class Suggestion(Strict):
    title: str = Field(min_length=3, max_length=200)
    explanationHe: str = Field(min_length=3, max_length=2000)
    evidence: Optional[str] = None
    severity: Literal["Low", "Medium", "High"] = "Medium"
    definition: RuleDefinition


class SuggestResponse(BaseModel):
    provider: str
    model: Optional[str] = None
    fallbackUsed: bool
    fallbackReason: Optional[str] = None
    rejectedCount: int = 0
    suggestions: list[dict]


# ---------------- profile (internal) ----------------

class FieldProfile(BaseModel):
    nulls: int = 0
    empties: int = 0
    distinct: Optional[int] = None
    minimum: Optional[str] = None
    maximum: Optional[str] = None
    q1: Optional[float] = None
    q3: Optional[float] = None
    high_threshold: Optional[float] = None
    high_outliers: int = 0


class DatePairFinding(BaseModel):
    start_key: str
    end_key: str
    violations: int


class InactiveParentFinding(BaseModel):
    relation_key: str
    active_field_path: list[str]
    root_active_condition: Optional[dict] = None
    violations: int


class ChildBeforeParentFinding(BaseModel):
    relation_key: str
    child_date_key: str
    parent_date_key: str
    violations: int


class MissingChildrenFinding(BaseModel):
    relation_key: str
    root_active_condition: Optional[dict] = None
    violations: int


class EntityProfile(BaseModel):
    entity_key: str
    row_count: int
    fields: dict[str, FieldProfile] = {}
    date_pairs: list[DatePairFinding] = []
    inactive_parents: list[InactiveParentFinding] = []
    child_before_parent: list[ChildBeforeParentFinding] = []
    missing_children: list[MissingChildrenFinding] = []

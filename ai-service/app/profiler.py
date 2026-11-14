"""Safe statistical profiling of the business data.

Security:
  * runs as the database user dc_profiler (EXECUTE AS USER) - SELECT on schema biz only;
  * every table/column name is first checked against INFORMATION_SCHEMA (allowlist) and then bracket-quoted;
  * only aggregate queries and bounded samples (TOP 10000) are executed, with a query timeout;
  * nothing here is sent to the LLM directly - the prompt builder decides what is shared (aggregates only).
"""
from __future__ import annotations

import logging
import os
import statistics
from contextlib import contextmanager
from typing import Iterator, Optional

from .models import (ChildBeforeParentFinding, DatePairFinding, EntityProfile, FieldProfile,
                     InactiveParentFinding, MissingChildrenFinding, SuggestRequest, CatalogEntity, CatalogField)

log = logging.getLogger(__name__)

SAMPLE_SIZE = 10_000
QUERY_TIMEOUT_SECONDS = 15
NUMERIC = {"Integer", "Decimal"}
TEMPORAL = {"Date", "DateTime"}


def q(identifier: str) -> str:
    """Bracket-quote an identifier that has ALREADY been validated against INFORMATION_SCHEMA."""
    return "[" + identifier.replace("]", "]]") + "]"


def _connection_string() -> str:
    explicit = os.getenv("DQ_DB_CONNECTION")
    if explicit:
        return explicit
    import pyodbc  # imported lazily so unit tests do not need the driver
    drivers = sorted(d for d in pyodbc.drivers() if d.startswith("ODBC Driver") and "SQL Server" in d)
    driver = drivers[-1] if drivers else "SQL Server"
    server = os.getenv("DQ_DB_SERVER", r".\SQLEXPRESS")
    return (f"Driver={{{driver}}};Server={server};Database=DataControls;"
            "Trusted_Connection=yes;TrustServerCertificate=yes;Encrypt=no")


@contextmanager
def profiler_connection() -> Iterator["object"]:
    import pyodbc
    pyodbc.pooling = False  # an impersonated session must never be reused
    conn = pyodbc.connect(_connection_string(), autocommit=True, timeout=10)
    conn.timeout = QUERY_TIMEOUT_SECONDS
    try:
        cur = conn.cursor()
        cur.execute("EXECUTE AS USER = ?", os.getenv("DQ_PROFILER_USER", "dc_profiler"))
        yield conn
    finally:
        conn.close()


class Profiler:
    def __init__(self, conn, request: SuggestRequest):
        self.conn = conn
        self.request = request
        cur = conn.cursor()
        cur.execute("SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'biz'")
        self.allowed = {(t.lower(), c.lower()) for t, c in cur.fetchall()}

    # ---------- helpers ----------

    def _ok(self, entity: CatalogEntity, column: Optional[str]) -> bool:
        return (entity.schema_name == "biz" and column is not None
                and (entity.table.lower(), column.lower()) in self.allowed)

    def _table(self, entity: CatalogEntity) -> str:
        return f"{q('biz')}.{q(entity.table)}"

    def _scalar(self, sql: str, *params) -> int:
        cur = self.conn.cursor()
        cur.execute(sql, *params)
        row = cur.fetchone()
        return int(row[0] or 0) if row else 0

    # ---------- profiling ----------

    def profile_all(self) -> list[EntityProfile]:
        profiles = []
        for entity in self.request.entities:
            if not self._ok(entity, entity.primaryKey):
                log.warning("Skipping entity %s: not found in schema biz", entity.key)
                continue
            try:
                profiles.append(self.profile_entity(entity))
            except Exception:  # one bad entity must not stop the analysis
                log.exception("Profiling failed for %s", entity.key)
        return profiles

    def profile_entity(self, e: CatalogEntity) -> EntityProfile:
        t = self._table(e)
        p = EntityProfile(entity_key=e.key, row_count=self._scalar(f"SELECT COUNT_BIG(*) FROM {t}"))
        if p.row_count == 0:
            return p

        for f in e.fields:
            if f.isComputed or not self._ok(e, f.column):
                continue
            p.fields[f.key] = self._profile_field(t, f)

        self._date_pairs(e, p)
        self._relationships(e, p)
        return p

    def _profile_field(self, t: str, f: CatalogField) -> FieldProfile:
        c = q(f.column)
        empty = f"SUM(CASE WHEN LTRIM(RTRIM({c})) = N'' THEN 1 ELSE 0 END)" if f.dataType in {"String", "Enum"} else "0"
        minmax = f"CONVERT(NVARCHAR(50), MIN({c})), CONVERT(NVARCHAR(50), MAX({c}))" if f.dataType in NUMERIC | TEMPORAL else "NULL, NULL"
        cur = self.conn.cursor()
        cur.execute(f"SELECT SUM(CASE WHEN {c} IS NULL THEN 1 ELSE 0 END), {empty}, COUNT(DISTINCT {c}), {minmax} FROM {t}")
        nulls, empties, distinct, mn, mx = cur.fetchone()
        fp = FieldProfile(nulls=int(nulls or 0), empties=int(empties or 0), distinct=int(distinct or 0), minimum=mn, maximum=mx)

        if f.dataType in NUMERIC:
            cur.execute(f"SELECT TOP ({SAMPLE_SIZE}) {c} FROM {t} WHERE {c} IS NOT NULL")
            values = [float(r[0]) for r in cur.fetchall()]
            if len(values) >= 20:
                q1, _, q3 = statistics.quantiles(values, n=4)
                iqr = q3 - q1
                if iqr > 0:
                    high = q3 + 3 * iqr
                    fp.q1, fp.q3, fp.high_threshold = q1, q3, round(high, 2)
                    fp.high_outliers = sum(1 for v in values if v > high)
        return fp

    def _date_pairs(self, e: CatalogEntity, p: EntityProfile) -> None:
        dates = [f for f in e.fields if f.dataType in TEMPORAL and not f.isComputed and self._ok(e, f.column)]
        for start, end in find_date_pairs(dates):
            n = self._scalar(f"SELECT COUNT_BIG(*) FROM {self._table(e)} WHERE {q(end.column)} IS NOT NULL "
                             f"AND {q(start.column)} IS NOT NULL AND {q(end.column)} < {q(start.column)}")
            p.date_pairs.append(DatePairFinding(start_key=start.key, end_key=end.key, violations=n))

    def _root_active(self, e: CatalogEntity) -> tuple[Optional[str], Optional[dict]]:
        """SQL + AST condition for 'the root record is active', if the entity has such a notion."""
        active = e.field("isActive")
        if active and active.dataType == "Boolean" and self._ok(e, active.column):
            return (f"e.{q(active.column)} = 1",
                    {"type": "comparison", "id": "a1", "left": {"kind": "field", "path": ["isActive"]},
                     "operator": "eq", "right": {"kind": "value", "value": True}})
        status = e.field("status")
        if status and status.dataType == "Enum" and self._ok(e, status.column):
            value = next((v.value for v in status.enumValues if v.displayName.strip() in {"פעיל", "פעילה"}), None)
            if value is not None:
                return (f"e.{q(status.column)} = ?",
                        {"type": "comparison", "id": "a1", "left": {"kind": "field", "path": ["status"]},
                         "operator": "eq", "right": {"kind": "value", "value": value}, "_param": value})
        return None, None

    def _relationships(self, e: CatalogEntity, p: EntityProfile) -> None:
        root_sql, root_ast = self._root_active(e)
        params = [root_ast.pop("_param")] if root_ast and "_param" in root_ast else []

        for rel in e.relationships:
            target = self.request.entity(rel.toEntity)
            if target is None or not self._ok(e, rel.fromColumn) or not self._ok(target, rel.toColumn):
                continue
            join = f"{self._table(target)} AS t ON t.{q(rel.toColumn)} = e.{q(rel.fromColumn)}"

            if rel.cardinality == "ManyToOne":
                active = target.field("isActive")
                if active and active.dataType == "Boolean" and self._ok(target, active.column):
                    where = f"t.{q(active.column)} = 0" + (f" AND {root_sql}" if root_sql else "")
                    n = self._scalar(f"SELECT COUNT_BIG(*) FROM {self._table(e)} AS e JOIN {join} WHERE {where}", *params)
                    p.inactive_parents.append(InactiveParentFinding(
                        relation_key=rel.key, active_field_path=[rel.key, "isActive"],
                        root_active_condition=root_ast, violations=n))

            elif rel.cardinality == "OneToMany":
                parent_date = next((f for f in e.fields if f.key in {"hireDate", "startDate"} and self._ok(e, f.column)), None)
                child_start = next((f for f in target.fields if f.key == "startDate" and self._ok(target, f.column)), None)
                if parent_date and child_start:
                    n = self._scalar(
                        f"SELECT COUNT_BIG(DISTINCT e.{q(e.primaryKey)}) FROM {self._table(e)} AS e JOIN {join} "
                        f"WHERE t.{q(child_start.column)} < e.{q(parent_date.column)}")
                    p.child_before_parent.append(ChildBeforeParentFinding(
                        relation_key=rel.key, child_date_key=child_start.key, parent_date_key=parent_date.key, violations=n))

                where = f"NOT EXISTS (SELECT 1 FROM {join.split(' ON ')[0]} WHERE t.{q(rel.toColumn)} = e.{q(rel.fromColumn)})"
                if root_sql:
                    where += f" AND {root_sql}"
                n = self._scalar(f"SELECT COUNT_BIG(*) FROM {self._table(e)} AS e WHERE {where}", *params)
                p.missing_children.append(MissingChildrenFinding(relation_key=rel.key, root_active_condition=root_ast, violations=n))


def find_date_pairs(dates: list[CatalogField]) -> list[tuple[CatalogField, CatalogField]]:
    """Pairs like startDate/endDate, hireDate/terminationDate, xStartDate/xEndDate."""
    by_key = {f.key: f for f in dates}
    pairs = []
    known = [("startDate", "endDate"), ("hireDate", "terminationDate"), ("fromDate", "toDate"), ("openDate", "closeDate")]
    for s, e in known:
        if s in by_key and e in by_key:
            pairs.append((by_key[s], by_key[e]))
    for k, f in by_key.items():
        if k.endswith("StartDate"):
            end = by_key.get(k[: -len("StartDate")] + "EndDate")
            if end:
                pairs.append((f, end))
    return pairs

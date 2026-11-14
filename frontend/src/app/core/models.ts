// Typed API models (mirror of the .NET DTOs). Business keys and Hebrew names only - no physical names.

export type DataType = 'string' | 'integer' | 'decimal' | 'date' | 'dateTime' | 'boolean' | 'enum';

export interface EnumValue { value: string; displayName: string; }
export interface FieldDef {
  key: string; displayName: string; description?: string | null; dataType: DataType;
  isNullable: boolean; isRequiredByBusiness: boolean; unit?: string | null; isComputed: boolean; enumValues: EnumValue[];
}
export interface RelationshipDef { key: string; displayName: string; toEntity: string; cardinality: 'manyToOne' | 'oneToMany'; }
export interface EntityDef {
  key: string; displayName: string; displayNamePlural: string; description?: string | null; displayFieldKey: string;
  fields: FieldDef[]; relationships: RelationshipDef[];
}
export interface OperatorDef { op: string; labelHe: string; shape: 'none' | 'single' | 'list' | 'range'; allowsField: boolean; }
export interface TypeOperators { dataType: DataType; operators: OperatorDef[]; }

// ---- Rule AST ----
export type Scalar = string | number | boolean;
export interface FieldOperand { kind: 'field'; path: string[]; scope?: 'root'; }
export interface ValueOperand { kind: 'value'; value: Scalar; }
export interface ValuesOperand { kind: 'values'; values: Scalar[]; }
export interface RangeOperand { kind: 'range'; from: Scalar; to: Scalar; }
export type Operand = FieldOperand | ValueOperand | ValuesOperand | RangeOperand;

export interface GroupNode { type: 'group'; id: string; logic: 'and' | 'or'; negate: boolean; children: ConditionNode[]; }
export interface ComparisonNode { type: 'comparison'; id: string; left: FieldOperand; operator: string; right?: Operand; }
export interface CollectionNode { type: 'collection'; id: string; relation: string; quantifier: 'any' | 'none' | 'all'; condition?: ConditionNode; }
export type ConditionNode = GroupNode | ComparisonNode | CollectionNode;

export interface RuleDefinition {
  schemaVersion: 1; rootEntity: string; condition: ConditionNode; output?: { displayFields: string[] };
}

export type RuleStatus = 'Draft' | 'Active' | 'Archived';
export type Severity = 'Low' | 'Medium' | 'High';

export interface Rule {
  id: string; name: string; description?: string | null; rootEntity: { key: string; displayName: string };
  definition: RuleDefinition; summaryHe?: string | null; status: RuleStatus; severity: Severity; origin: 'Manual' | 'AI';
  version: number; lastRun?: { id: string; status: string; violationCount?: number | null; finishedAt?: string | null } | null;
  createdBy: string; createdAt: string; updatedBy: string; updatedAt: string;
}

export interface SaveRule { name: string; description?: string | null; status: RuleStatus; severity: Severity; definition: RuleDefinition; }

export interface ValidationError { nodeId?: string | null; code: string; messageHe: string; }
export interface ValidationResult { valid: boolean; errors: ValidationError[]; summaryHe?: string | null; }

export interface Paged<T> { items: T[]; page: number; pageSize: number; totalCount: number; }

export type RunStatus = 'Queued' | 'Running' | 'Succeeded' | 'Failed' | 'TimedOut';
export interface Run {
  id: string; ruleId: string; ruleVersionNo: number; status: RunStatus; queuedAt: string; startedAt?: string | null;
  finishedAt?: string | null; durationMs?: number | null; violationCount?: number | null; storedCount?: number | null;
  isTruncated: boolean; errorCode?: string | null; errorMessage?: string | null; triggeredBy: string; ruleName?: string | null;
}

export interface Column { key: string; displayName: string; }
export interface Reason { conditionId: string; textHe: string; }
export interface Violation { recordKey: string; displayLabel: string; reasons: Reason[]; values: Record<string, string>; }
export interface ConditionOption { id: string; textHe: string; }
export interface ViolationPage {
  run: Run; columns: Column[]; conditions: ConditionOption[]; items: Violation[]; page: number; pageSize: number; totalCount: number;
}
export interface PreviewResult { totalCount: number; columns: Column[]; items: Violation[]; }

export interface Suggestion {
  id: string; batchId: string;
  /** heuristic | openai | vertex */
  provider: string;
  /** 'llm' = produced by a language model; 'local' = deterministic metadata/statistics engine */
  source: 'llm' | 'local';
  model?: string | null;
  title: string; explanationHe: string; evidence?: string | null; severity: Severity;
  rootEntityName?: string | null; involvedFields: string[];
  definition: RuleDefinition; summaryHe?: string | null; status: 'Proposed' | 'Accepted' | 'Rejected' | 'Invalid';
  validationErrors: ValidationError[]; createdAt: string; acceptedRuleId?: string | null;
}
export interface GenerateResult {
  batchId: string; provider: string; model?: string | null; isLlm: boolean; fallbackUsed: boolean; fallbackReason?: string | null;
  proposed: number; invalid: number; duplicates: number; rejectedByAdvisor: number;
}
export interface AiStatus { available: boolean; provider?: string | null; model?: string | null; isLlm: boolean; }

export interface CatalogIssue { entityKey: string; fieldKey?: string | null; messageHe: string; }

export const RUN_TERMINAL: RunStatus[] = ['Succeeded', 'Failed', 'TimedOut'];
export const SEVERITY_HE: Record<Severity, string> = { Low: 'נמוכה', Medium: 'בינונית', High: 'גבוהה' };
export const STATUS_HE: Record<string, string> = {
  Draft: 'טיוטה', Active: 'פעילה', Archived: 'בארכיון',
  Queued: 'בתור', Running: 'רצה', Succeeded: 'הושלמה', Failed: 'נכשלה', TimedOut: 'חרגה מזמן',
  Proposed: 'ממתינה לבדיקה', Accepted: 'אושרה', Rejected: 'נדחתה', Invalid: 'לא תקינה',
};

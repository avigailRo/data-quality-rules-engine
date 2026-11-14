import { CollectionNode, ComparisonNode, ConditionNode, DataType, GroupNode } from '../../../core/models';

/** Node ids are opaque client-side identifiers (used for error mapping and explanations). The server never puts them in SQL. */
export function newId(prefix: string): string {
  return prefix + Math.random().toString(36).slice(2, 8);
}

export function blankComparison(): ComparisonNode {
  return { type: 'comparison', id: newId('c'), left: { kind: 'field', path: [] }, operator: 'eq' };
}

export function newGroup(withRow = true): GroupNode {
  return { type: 'group', id: newId('g'), logic: 'and', negate: false, children: withRow ? [blankComparison()] : [] };
}

export function newCollection(relation: string): CollectionNode {
  return { type: 'collection', id: newId('q'), relation, quantifier: 'any', condition: newGroup() };
}

export function compatible(a: DataType | undefined, b: DataType | undefined): boolean {
  if (!a || !b) return false;
  const numeric = ['integer', 'decimal'], temporal = ['date', 'dateTime'], text = ['string', 'enum'];
  return a === b || (numeric.includes(a) && numeric.includes(b)) || (temporal.includes(a) && temporal.includes(b))
    || (text.includes(a) && text.includes(b));
}

export function countNodes(node: ConditionNode): number {
  if (node.type === 'group') return 1 + node.children.reduce((n, c) => n + countNodes(c), 0);
  if (node.type === 'collection') return 1 + (node.condition ? countNodes(node.condition) : 0);
  return 1;
}

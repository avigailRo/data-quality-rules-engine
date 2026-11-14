import { Component, computed, forwardRef, inject, input, output } from '@angular/core';
import { CatalogStore } from '../../../core/catalog.store';
import { CollectionNode, ConditionNode, GroupNode } from '../../../core/models';
import { blankComparison, newCollection, newGroup } from './builder-model';
import { ConditionRowComponent } from './condition-row.component';

/**
 * Recursive AND/OR group. Business wording: "all of the conditions" / "at least one of the conditions".
 * The tree is immutable: every change emits a new node, the editor page owns the state (a signal).
 */
@Component({
  selector: 'dc-condition-group',
  imports: [ConditionRowComponent, forwardRef(() => CollectionConditionComponent)],
  template: `
    <fieldset class="group" [attr.data-depth]="depth()" [attr.data-logic]="node().logic" [class.has-error]="error()">
      <legend class="group-head">
        <select [disabled]="locked()" [value]="node().logic" (change)="setLogic($any($event.target).value)" aria-label="אופן צירוף התנאים">
          <option value="and">כל התנאים הבאים מתקיימים (וגם)</option>
          <option value="or">לפחות אחד מהתנאים מתקיים (או)</option>
        </select>
        <label class="check">
          <input type="checkbox" [disabled]="locked()" [checked]="node().negate" (change)="setNegate($any($event.target).checked)" />
          הפוך – הקבוצה <strong>לא</strong> מתקיימת
        </label>
        @if (removable() && !locked()) {
          <button type="button" class="icon-btn" (click)="removed.emit()" aria-label="מחיקת קבוצה" title="מחיקת קבוצה">🗑</button>
        }
      </legend>

      @for (child of node().children; track child.id; let i = $index; let last = $last) {
        @switch (child.type) {
          @case ('comparison') {
            <dc-condition-row [node]="$any(child)" [entityKey]="entityKey()" [rootEntityKey]="rootEntityKey()" [errors]="errors()" [locked]="locked()"
              (changed)="replace(i, $event)" (removed)="remove(i)" />
          }
          @case ('group') {
            <dc-condition-group [node]="$any(child)" [entityKey]="entityKey()" [rootEntityKey]="rootEntityKey()" [errors]="errors()" [locked]="locked()"
              [depth]="depth() + 1" [removable]="true" (changed)="replace(i, $event)" (removed)="remove(i)" />
          }
          @case ('collection') {
            <dc-collection-condition [node]="$any(child)" [entityKey]="entityKey()" [rootEntityKey]="rootEntityKey()" [errors]="errors()" [locked]="locked()"
              [depth]="depth() + 1" (changed)="replace(i, $event)" (removed)="remove(i)" />
          }
        }
        @if (!last) { <div class="joiner" [attr.data-logic]="node().logic" aria-hidden="true"><span>{{ node().logic === 'and' ? 'וגם' : 'או' }}</span></div> }
      }

      @if (error()) { <p class="field-error" role="alert">{{ error() }}</p> }

      @if (!locked()) {
        <div class="group-actions">
          <button type="button" class="btn btn-small" (click)="add(blank())">+ תנאי</button>
          @if (depth() < 4) { <button type="button" class="btn btn-small" (click)="add(group())">+ קבוצת תנאים</button> }
          @for (rel of collections(); track rel.key) {
            <button type="button" class="btn btn-small" (click)="add(collection(rel.key))">+ תנאי על {{ rel.displayName }}</button>
          }
        </div>
      }
    </fieldset>
  `,
})
export class ConditionGroupComponent {
  private readonly store = inject(CatalogStore);

  readonly node = input.required<GroupNode>();
  readonly entityKey = input.required<string>();
  readonly rootEntityKey = input.required<string>();
  readonly errors = input<Record<string, string>>({});
  readonly locked = input(false);
  readonly depth = input(0);
  readonly removable = input(false);
  readonly changed = output<GroupNode>();
  readonly removed = output<void>();

  protected readonly error = computed(() => this.errors()[this.node().id]);
  protected readonly collections = computed(() => this.depth() < 3 ? this.store.collections(this.entityKey()) : []);

  protected blank = blankComparison;
  protected group = () => newGroup();
  protected collection = (rel: string) => newCollection(rel);

  setLogic(logic: 'and' | 'or') { this.changed.emit({ ...this.node(), logic }); }
  setNegate(negate: boolean) { this.changed.emit({ ...this.node(), negate }); }
  add(child: ConditionNode) { this.changed.emit({ ...this.node(), children: [...this.node().children, child] }); }
  replace(i: number, child: ConditionNode) {
    const children = [...this.node().children];
    children[i] = child;
    this.changed.emit({ ...this.node(), children });
  }
  remove(i: number) { this.changed.emit({ ...this.node(), children: this.node().children.filter((_, idx) => idx !== i) }); }
}

/** Condition over a one-to-many relationship: "at least one / none / all of the employee's project assignments ...". */
@Component({
  selector: 'dc-collection-condition',
  imports: [ConditionGroupComponent],
  template: `
    <div class="collection" [class.has-error]="error()">
      <div class="collection-head">
        <select [disabled]="locked()" [value]="node().quantifier" (change)="setQuantifier($any($event.target).value)" aria-label="כמת">
          <option value="any">קיימת לפחות רשומה אחת ב</option>
          <option value="none">אין אף רשומה ב</option>
          <option value="all">כל הרשומות ב</option>
        </select>
        <strong>{{ relation()?.displayName ?? node().relation }}</strong>
        @if (node().condition) {
          <span>שבה:</span>
        } @else if (!locked()) {
          <button type="button" class="btn btn-small" (click)="addCondition()">+ הוספת תנאי על הרשומות</button>
        }
        @if (!locked()) {
          <button type="button" class="icon-btn" (click)="removed.emit()" aria-label="מחיקת תנאי רשומות קשורות" title="מחיקה">🗑</button>
        }
      </div>
      @if (node().condition; as cond) {
        @if (cond.type === 'group') {
          <dc-condition-group [node]="$any(cond)" [entityKey]="childEntityKey()" [rootEntityKey]="rootEntityKey()" [errors]="errors()" [locked]="locked()"
            [depth]="depth() + 1" [removable]="node().quantifier !== 'all'" (changed)="setCondition($event)" (removed)="clearCondition()" />
        }
      }
      @if (error()) { <p class="field-error" role="alert">{{ error() }}</p> }
    </div>
  `,
})
export class CollectionConditionComponent {
  private readonly store = inject(CatalogStore);

  readonly node = input.required<CollectionNode>();
  readonly entityKey = input.required<string>();
  readonly rootEntityKey = input.required<string>();
  readonly errors = input<Record<string, string>>({});
  readonly locked = input(false);
  readonly depth = input(0);
  readonly changed = output<CollectionNode>();
  readonly removed = output<void>();

  protected readonly relation = computed(() => this.store.collections(this.entityKey()).find(r => r.key === this.node().relation));
  protected readonly childEntityKey = computed(() => this.relation()?.toEntity ?? '');
  protected readonly error = computed(() => this.errors()[this.node().id]);

  setQuantifier(quantifier: 'any' | 'none' | 'all') {
    const next: CollectionNode = { ...this.node(), quantifier };
    if (quantifier === 'all' && !next.condition) next.condition = newGroup();
    this.changed.emit(next);
  }
  addCondition() { this.changed.emit({ ...this.node(), condition: newGroup() }); }
  setCondition(condition: GroupNode) { this.changed.emit({ ...this.node(), condition }); }
  clearCondition() {
    const { condition: _removed, ...rest } = this.node();
    this.changed.emit(rest as CollectionNode);
  }
}

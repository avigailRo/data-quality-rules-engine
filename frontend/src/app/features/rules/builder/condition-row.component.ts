import { NgTemplateOutlet } from '@angular/common';
import { Component, computed, inject, input, output } from '@angular/core';
import { CatalogStore, FieldOption } from '../../../core/catalog.store';
import { ComparisonNode, FieldDef, FieldOperand, OperatorDef, Operand, Scalar } from '../../../core/models';
import { compatible } from './builder-model';

/** One condition: [business field] [operator filtered by type] [typed value or another field]. */
@Component({
  selector: 'dc-condition-row',
  template: `
    <div class="cond-row" [class.has-error]="error()">
      <label class="field-col">
        <span class="sr-only">שדה</span>
        <select [disabled]="locked()" [value]="leftValue()" (change)="onField($any($event.target).value)">
          <option value="" disabled>בחרו שדה…</option>
          @for (g of groups(); track g.label) {
            <optgroup [label]="g.label">
              @for (o of g.options; track o.value) { <option [value]="o.value" [selected]="o.value === leftValue()">{{ o.field.displayName }}</option> }
            </optgroup>
          }
        </select>
      </label>

      <label class="op-col">
        <span class="sr-only">פעולה</span>
        <select [disabled]="locked() || !field()" [value]="node().operator" (change)="onOperator($any($event.target).value)">
          @for (op of operators(); track op.op) { <option [value]="op.op" [selected]="op.op === node().operator">{{ op.labelHe }}</option> }
        </select>
      </label>

      <div class="value-col">
        @switch (opDef()?.shape) {
          @case ('single') {
            @if (opDef()?.allowsField) {
              <div class="mode-toggle" role="radiogroup" aria-label="השוואה ל">
                <button type="button" class="chip" [class.on]="!isFieldMode()" [disabled]="locked()" (click)="setMode('value')">ערך</button>
                <button type="button" class="chip" [class.on]="isFieldMode()" [disabled]="locked()" (click)="setMode('field')">שדה אחר</button>
              </div>
            }
            @if (isFieldMode()) {
              <label><span class="sr-only">שדה להשוואה</span>
                <select [disabled]="locked()" [value]="rightFieldValue()" (change)="onRightField($any($event.target).value)">
                  <option value="" disabled>בחרו שדה…</option>
                  @for (g of compatibleGroups(); track g.label) {
                    <optgroup [label]="g.label">
                      @for (o of g.options; track o.value) { <option [value]="o.value" [selected]="o.value === rightFieldValue()">{{ o.field.displayName }}</option> }
                    </optgroup>
                  }
                </select>
              </label>
            } @else {
              <ng-container *ngTemplateOutlet="valueInput; context: { $implicit: singleValue(), set: setSingle }" />
            }
          }
          @case ('list') {
            @if (field()?.dataType === 'enum') {
              <div class="checks">
                @for (v of field()!.enumValues; track v.value) {
                  <label class="check"><input type="checkbox" [disabled]="locked()" [checked]="listValues().includes(v.value)" (change)="toggleListValue(v.value)" /> {{ v.displayName }}</label>
                }
              </div>
            } @else {
              <label><span class="sr-only">ערכים מופרדים בפסיק</span>
                <input type="text" [disabled]="locked()" placeholder="ערכים מופרדים בפסיק" [value]="listValues().join(', ')" (change)="onListText($any($event.target).value)" />
              </label>
            }
          }
          @case ('range') {
            <div class="range">
              <ng-container *ngTemplateOutlet="valueInput; context: { $implicit: rangeFrom(), set: setFrom }" />
              <span>עד</span>
              <ng-container *ngTemplateOutlet="valueInput; context: { $implicit: rangeTo(), set: setTo }" />
            </div>
          }
        }
        @if (field()?.unit && opDef()?.shape !== 'none' && !isFieldMode()) { <span class="unit">{{ field()!.unit }}</span> }
      </div>

      @if (!locked()) {
        <button type="button" class="icon-btn" (click)="removed.emit()" aria-label="מחיקת תנאי" title="מחיקת תנאי">🗑</button>
      }

      <ng-template #valueInput let-value let-set="set">
        @switch (field()?.dataType) {
          @case ('boolean') {
            <select [disabled]="locked()" [value]="String(value)" (change)="set($any($event.target).value)" aria-label="ערך">
              <option value="true">כן</option><option value="false">לא</option>
            </select>
          }
          @case ('enum') {
            <select [disabled]="locked()" [value]="value" (change)="set($any($event.target).value)" aria-label="ערך">
              @for (v of field()!.enumValues; track v.value) { <option [value]="v.value" [selected]="v.value === value">{{ v.displayName }}</option> }
            </select>
          }
          @default {
            <input [type]="inputType()" [disabled]="locked()" [value]="value" (change)="set($any($event.target).value)" aria-label="ערך" />
          }
        }
      </ng-template>
    </div>
    @if (error()) { <p class="field-error" role="alert">{{ error() }}</p> }
  `,
  imports: [NgTemplateOutlet],
})
export class ConditionRowComponent {
  private readonly store = inject(CatalogStore);

  readonly node = input.required<ComparisonNode>();
  readonly entityKey = input.required<string>();
  readonly rootEntityKey = input.required<string>();
  readonly errors = input<Record<string, string>>({});
  readonly locked = input(false);
  readonly changed = output<ComparisonNode>();
  readonly removed = output<void>();

  protected readonly String = String;

  protected readonly groups = computed(() =>
    this.store.fieldGroups(this.entityKey(), this.entityKey() !== this.rootEntityKey() ? this.rootEntityKey() : undefined));

  protected readonly error = computed(() => this.errors()[this.node().id]);

  protected readonly leftValue = computed(() => this.optionValue(this.node().left));
  protected readonly field = computed(() => this.fieldOf(this.node().left));
  protected readonly operators = computed(() => this.store.operatorsFor(this.field()?.dataType));
  protected readonly opDef = computed<OperatorDef | undefined>(() => this.operators().find(o => o.op === this.node().operator));
  protected readonly isFieldMode = computed(() => this.node().right?.kind === 'field');
  protected readonly rightFieldValue = computed(() => {
    const r = this.node().right;
    return r?.kind === 'field' ? this.optionValue(r) : '';
  });
  protected readonly compatibleGroups = computed(() => {
    const type = this.field()?.dataType;
    return this.groups()
      .map(g => ({ ...g, options: g.options.filter((o: FieldOption) => compatible(type, o.field.dataType) && o.value !== this.leftValue()) }))
      .filter(g => g.options.length > 0);
  });

  protected readonly singleValue = computed(() => { const r = this.node().right; return r?.kind === 'value' ? r.value : ''; });
  protected readonly listValues = computed<Scalar[]>(() => { const r = this.node().right; return r?.kind === 'values' ? r.values : []; });
  protected readonly rangeFrom = computed(() => { const r = this.node().right; return r?.kind === 'range' ? r.from : ''; });
  protected readonly rangeTo = computed(() => { const r = this.node().right; return r?.kind === 'range' ? r.to : ''; });

  protected readonly inputType = computed(() => {
    switch (this.field()?.dataType) {
      case 'integer': case 'decimal': return 'number';
      case 'date': return 'date';
      case 'dateTime': return 'datetime-local';
      default: return 'text';
    }
  });

  private optionValue(f: FieldOperand): string {
    return f.path.length === 0 ? '' : (f.scope === 'root' ? 'root:' : '') + f.path.join('.');
  }

  private parseOption(value: string): FieldOperand {
    return value.startsWith('root:')
      ? { kind: 'field', scope: 'root', path: value.slice(5).split('.') }
      : { kind: 'field', path: value.split('.') };
  }

  private fieldOf(f: FieldOperand): FieldDef | undefined {
    if (f.path.length === 0) return undefined;
    return this.store.resolve(f.scope === 'root' ? this.rootEntityKey() : this.entityKey(), f.path);
  }

  private convert(raw: string): Scalar {
    switch (this.field()?.dataType) {
      case 'integer': case 'decimal': return raw === '' ? '' : Number(raw);
      case 'boolean': return raw === 'true';
      default: return raw;
    }
  }

  private defaultRight(field: FieldDef | undefined, op: OperatorDef | undefined): Operand | undefined {
    if (!field || !op) return undefined;
    const first: Scalar = field.dataType === 'boolean' ? false : field.dataType === 'enum' ? (field.enumValues[0]?.value ?? '') : '';
    switch (op.shape) {
      case 'none': return undefined;
      case 'list': return { kind: 'values', values: [] };
      case 'range': return { kind: 'range', from: first, to: first };
      default: return { kind: 'value', value: first };
    }
  }

  private emit(patch: Partial<ComparisonNode>) {
    const next: ComparisonNode = { ...this.node(), ...patch };
    if (next.right === undefined) delete next.right;
    this.changed.emit(next);
  }

  onField(value: string) {
    const left = this.parseOption(value);
    const field = this.fieldOf(left);
    const ops = this.store.operatorsFor(field?.dataType);
    const op = ops.find(o => o.op === 'eq') ?? ops[0];
    this.emit({ left, operator: op?.op ?? 'eq', right: this.defaultRight(field, op) });
  }

  onOperator(opName: string) {
    const op = this.operators().find(o => o.op === opName);
    const keep = op?.shape === 'single' && this.opDef()?.shape === 'single' && (op.allowsField || this.node().right?.kind !== 'field');
    this.emit({ operator: opName, right: keep ? this.node().right : this.defaultRight(this.field(), op) });
  }

  setMode(mode: 'value' | 'field') {
    if (mode === 'field') this.emit({ right: { kind: 'field', path: [] } });
    else this.emit({ right: this.defaultRight(this.field(), this.opDef()) });
  }

  onRightField(value: string) { this.emit({ right: this.parseOption(value) }); }

  protected readonly setSingle = (raw: string) => this.emit({ right: { kind: 'value', value: this.convert(raw) } });
  protected readonly setFrom = (raw: string) => this.emit({ right: { kind: 'range', from: this.convert(raw), to: this.rangeTo() } });
  protected readonly setTo = (raw: string) => this.emit({ right: { kind: 'range', from: this.rangeFrom(), to: this.convert(raw) } });

  toggleListValue(v: string) {
    const current = this.listValues();
    const values = current.includes(v) ? current.filter(x => x !== v) : [...current, v];
    this.emit({ right: { kind: 'values', values } });
  }

  onListText(text: string) {
    const values = text.split(',').map(s => s.trim()).filter(s => s.length > 0).map(s => this.convert(s));
    this.emit({ right: { kind: 'values', values } });
  }
}


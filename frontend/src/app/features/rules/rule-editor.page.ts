import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, DestroyRef, computed, effect, inject, input, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { Api } from '../../core/api';
import { CatalogStore } from '../../core/catalog.store';
import { GroupNode, PreviewResult, Rule, RuleDefinition, RuleStatus, Run, Severity, ValidationResult } from '../../core/models';
import { Notifier, Session, problemCode } from '../../core/session';
import { Icon } from '../../shared/icon';
import { PageState, StatusBadge } from '../../shared/ui';
import { ConditionGroupComponent } from './builder/condition-group.component';
import { newGroup } from './builder/builder-model';

@Component({
  selector: 'dc-rule-editor',
  imports: [ReactiveFormsModule, RouterLink, DatePipe, DecimalPipe, Icon, PageState, StatusBadge, ConditionGroupComponent],
  template: `
    <a routerLink="/rules" class="back"><dc-icon name="arrowBack" [size]="16" /> חזרה לרשימת הבקרות</a>
    <header class="page-header">
      <div>
        <h1>{{ isNew() ? 'בקרה חדשה' : 'עריכת בקרה' }}
          @if (rule(); as r) { <dc-status [status]="r.status" /> @if (r.origin === 'AI') { <span class="badge" data-kind="ai">נוצרה מהמלצת AI</span> } <span class="badge">גרסה {{ r.version }}</span> }
        </h1>
        <p class="page-sub">מגדירים מתי רשומה נחשבת <strong>חריגה</strong>. כל רשומה שעומדת בתנאים תופיע בתוצאות ההרצה, יחד עם הסיבה.</p>
      </div>
    </header>

    <dc-page-state [loading]="loading()" [error]="loadError()" (retry)="load()">
      @if (locked()) {
        <p class="notice">{{ rule()?.status === 'Archived' ? 'הבקרה בארכיון ולכן לקריאה בלבד.' : 'אין לך הרשאת עריכה – הבקרה מוצגת לקריאה בלבד.' }}</p>
      }

      <form [formGroup]="form" (ngSubmit)="save()" novalidate>
        <section class="card">
          <h2>פרטי הבקרה</h2>
          <div class="form-grid">
            <label class="span-2">שם הבקרה *
              <input type="text" formControlName="name" maxlength="200" [attr.aria-invalid]="form.controls.name.invalid && form.controls.name.touched" />
              @if (form.controls.name.invalid && form.controls.name.touched) { <span class="field-error">יש להזין שם (עד 200 תווים).</span> }
            </label>
            <label class="span-2">תיאור
              <textarea formControlName="description" rows="2" maxlength="1000"></textarea>
            </label>
            <label>על מה הבקרה? *
              <select formControlName="rootEntity">
                <option value="" disabled>בחרו נושא…</option>
                @for (e of store.entities(); track e.key) { <option [value]="e.key">{{ e.displayNamePlural }}</option> }
              </select>
            </label>
            <label>חומרה
              <select formControlName="severity">
                <option value="Low">נמוכה</option><option value="Medium">בינונית</option><option value="High">גבוהה</option>
              </select>
            </label>
            <label>סטטוס
              <select formControlName="status">
                <option value="Draft">טיוטה</option><option value="Active">פעילה</option>
              </select>
            </label>
          </div>
        </section>

        @if (definition(); as def) {
          <section class="card">
            <h2>תנאי החריגה – אילו רשומות ייחשבו חריגות?</h2>
            <details class="help">
              <summary><dc-icon name="info" [size]="16" /> איך בונים תנאים?</summary>
              <ul>
                <li><span class="logic-pill" data-logic="and">וגם</span> כל התנאים בקבוצה חייבים להתקיים.</li>
                <li><span class="logic-pill" data-logic="or">או</span> מספיק שאחד מהתנאים יתקיים.</li>
                <li><strong>קבוצת תנאים</strong> מאפשרת לשלב, למשל: (פעיל וגם מחלקה לא פעילה) או (שכר מעל 15,000).</li>
                <li><strong>שדות של רשומה קשורה</strong> (כמו "המחלקה של העובד › פעילה") נבחרים ישירות מרשימת השדות.</li>
                <li><strong>תנאי על רשימה</strong> (כמו שיוכי הפרויקטים של עובד): "לפחות אחת", "אף אחת" או "כולן".</li>
                <li>שדה ריק לא מקיים אף השוואה. כדי למצוא ערכים חסרים, בחרו את הפעולה "ריק".</li>
              </ul>
            </details>
            <dc-condition-group [node]="$any(def.condition)" [entityKey]="def.rootEntity" [rootEntityKey]="def.rootEntity"
              [errors]="nodeErrors()" [locked]="locked()" (changed)="setCondition($event)" />

            <div class="summary" aria-live="polite">
              @if (validation(); as v) {
                @if (v.valid) { <p><strong>במילים:</strong> {{ v.summaryHe }}</p> }
                @else if (generalErrors().length) {
                  <ul class="field-error">@for (e of generalErrors(); track $index) { <li>{{ e }}</li> }</ul>
                } @else { <p class="muted">השלימו את התנאים המסומנים.</p> }
              }
            </div>

            <details class="display-fields">
              <summary>שדות שיוצגו בתוצאות ({{ def.output?.displayFields?.length ?? 0 }})</summary>
              <div class="checks">
                @for (g of displayGroups(); track g.label) {
                  <fieldset><legend>{{ g.label }}</legend>
                    @for (o of g.options; track o.value) {
                      <label class="check"><input type="checkbox" [disabled]="locked()" [checked]="isDisplayed(o.value)" (change)="toggleDisplay(o.value)" /> {{ o.field.displayName }}</label>
                    }
                  </fieldset>
                }
              </div>
            </details>
          </section>
        }

        <div class="actions sticky">
          @if (!locked()) {
            <button type="submit" class="btn btn-primary" [disabled]="saving()"><dc-icon name="check" [size]="16" /> {{ saving() ? 'שומר…' : 'שמירה' }}</button>
            <button type="button" class="btn" [disabled]="previewing() || !definition()" (click)="runPreview()"><dc-icon name="eye" [size]="16" /> {{ previewing() ? 'מחשב…' : 'תצוגה מקדימה' }}</button>
          }
          @if (rule() && session.canAuthor() && rule()!.status !== 'Archived') {
            <button type="button" class="btn" [disabled]="dirty() || running()" (click)="run()" [title]="dirty() ? 'יש לשמור את השינויים לפני הרצה' : ''"><dc-icon name="play" [size]="16" /> הרצת הבקרה</button>
          }
          @if (rule() && session.isAdmin()) { <button type="button" class="btn btn-ghost" (click)="showSql()">הצגת SQL (מנהל)</button> }
          @if (dirty() && !locked()) { <span class="muted">יש שינויים שלא נשמרו</span> }
        </div>
      </form>

      @if (preview(); as p) {
        <section class="card" aria-live="polite">
          <h2>תצוגה מקדימה: {{ p.totalCount | number }} רשומות חריגות</h2>
          @if (p.items.length === 0) { <p class="muted">לא נמצאו רשומות חריגות לפי ההגדרה הנוכחית.</p> }
          @else {
            <table class="table responsive compact">
              <thead><tr><th>רשומה</th>@for (c of p.columns; track c.key) { <th>{{ c.displayName }}</th> }<th>סיבת החריגה</th></tr></thead>
              <tbody>
                @for (v of p.items; track v.recordKey) {
                  <tr>
                    <td data-label="רשומה"><strong>{{ v.displayLabel }}</strong></td>
                    @for (c of p.columns; track c.key) { <td [attr.data-label]="c.displayName"><bdi>{{ v.values[c.key] }}</bdi></td> }
                    <td data-label="סיבה"><ul class="reasons">@for (r of v.reasons; track r.conditionId) { <li>{{ r.textHe }}</li> }</ul></td>
                  </tr>
                }
              </tbody>
            </table>
            @if (p.totalCount > p.items.length) { <p class="muted">מוצגות {{ p.items.length }} הראשונות. להצגה מלאה – שמרו והריצו.</p> }
          }
        </section>
      }

      @if (sql(); as s) {
        <section class="card">
          <h2>SQL שנוצר (פרמטרי, לקריאה בלבד)</h2>
          <pre class="sql" dir="ltr">{{ s.sql }}</pre>
          <pre class="sql" dir="ltr">{{ s.parameters.join('\\n') }}</pre>
        </section>
      }

      @if (history().length) {
        <section class="card">
          <h2>היסטוריית הרצות</h2>
          <table class="table compact">
            <thead><tr><th>מועד</th><th>גרסה</th><th>סטטוס</th><th>חריגות</th><th></th></tr></thead>
            <tbody>
              @for (h of history(); track h.id) {
                <tr>
                  <td>{{ h.queuedAt | date: 'dd/MM/yyyy HH:mm' }}</td><td>{{ h.ruleVersionNo }}</td>
                  <td><dc-status [status]="h.status" /></td><td>{{ h.violationCount ?? '—' }}</td>
                  <td><a [routerLink]="['/runs', h.id]">לתוצאות</a></td>
                </tr>
              }
            </tbody>
          </table>
        </section>
      }
    </dc-page-state>
  `,
})
export class RuleEditorPage {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly notifier = inject(Notifier);
  protected readonly store = inject(CatalogStore);
  protected readonly session = inject(Session);

  readonly id = input<string>();

  protected readonly rule = signal<Rule | null>(null);
  protected readonly definition = signal<RuleDefinition | null>(null);
  protected readonly validation = signal<ValidationResult | null>(null);
  protected readonly preview = signal<PreviewResult | null>(null);
  protected readonly history = signal<Run[]>([]);
  protected readonly sql = signal<{ sql: string; parameters: string[] } | null>(null);
  protected readonly loading = signal(true);
  protected readonly loadError = signal<unknown>(null);
  protected readonly saving = signal(false);
  protected readonly previewing = signal(false);
  protected readonly running = signal(false);
  protected readonly definitionDirty = signal(false);
  private readonly formDirty = signal(false);

  protected readonly isNew = computed(() => !this.id());
  protected readonly locked = computed(() => !this.session.canAuthor() || this.rule()?.status === 'Archived');
  protected readonly dirty = computed(() => this.definitionDirty() || this.formDirty());

  protected readonly form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required, Validators.maxLength(200)] }),
    description: new FormControl('', { nonNullable: true, validators: [Validators.maxLength(1000)] }),
    rootEntity: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    severity: new FormControl<Severity>('Medium', { nonNullable: true }),
    status: new FormControl<RuleStatus>('Active', { nonNullable: true }),
  });

  /** Server validation errors mapped to the condition that caused them (shown inline). */
  protected readonly nodeErrors = computed<Record<string, string>>(() => {
    const map: Record<string, string> = {};
    for (const e of this.validation()?.errors ?? []) if (e.nodeId && !map[e.nodeId]) map[e.nodeId] = e.messageHe;
    return map;
  });
  protected readonly generalErrors = computed(() => (this.validation()?.errors ?? []).filter(e => !e.nodeId).map(e => e.messageHe));
  protected readonly displayGroups = computed(() => {
    const def = this.definition();
    return def ? this.store.fieldGroups(def.rootEntity) : [];
  });

  constructor() {
    const destroyRef = inject(DestroyRef);
    const sub = this.form.controls.rootEntity.valueChanges.subscribe(key => {
      if (!key || this.loading() || key === this.definition()?.rootEntity) return;
      const entity = this.store.entity(key);
      this.definition.set({ schemaVersion: 1, rootEntity: key, condition: newGroup(), output: { displayFields: entity ? [entity.displayFieldKey] : [] } });
      this.definitionDirty.set(true);
      this.preview.set(null);
    });
    const dirtySub = this.form.valueChanges.subscribe(() => this.formDirty.set(this.form.dirty));
    destroyRef.onDestroy(() => { sub.unsubscribe(); dirtySub.unsubscribe(); });

    // Debounced live validation: summary sentence + inline errors from the authoritative server-side validator.
    effect(onCleanup => {
      const def = this.definition();
      if (!def) return;
      const handle = setTimeout(() => {
        this.api.validate(def).then(v => this.validation.set(v)).catch(() => { /* non-blocking */ });
      }, 400);
      onCleanup(() => clearTimeout(handle));
    });

    effect(() => {
      // re-load when navigating between /rules/new and /rules/:id
      this.id();
      queueMicrotask(() => this.load());
    });

    effect(() => {
      if (this.locked()) this.form.disable({ emitEvent: false });
      else this.form.enable({ emitEvent: false });
    });
  }

  async load() {
    this.loading.set(true);
    this.loadError.set(null);
    this.preview.set(null);
    this.sql.set(null);
    try {
      await this.store.load();
      const id = this.id();
      if (id) {
        const [r, runs] = await Promise.all([this.api.rule(id), this.api.runHistory(id)]);
        this.applyRule(r);
        this.history.set(runs.slice(0, 10));
      } else {
        this.rule.set(null);
        this.history.set([]);
        const first = this.store.entities()[0];
        this.form.reset({ name: '', description: '', rootEntity: first?.key ?? '', severity: 'Medium', status: 'Active' });
        this.definition.set(first ? { schemaVersion: 1, rootEntity: first.key, condition: newGroup(), output: { displayFields: [first.displayFieldKey] } } : null);
        this.definitionDirty.set(false);
        this.formDirty.set(false);
      }
    } catch (err) {
      this.loadError.set(err);
    } finally {
      this.loading.set(false);
    }
  }

  private applyRule(r: Rule) {
    this.rule.set(r);
    this.form.reset({ name: r.name, description: r.description ?? '', rootEntity: r.rootEntity.key, severity: r.severity, status: r.status === 'Archived' ? 'Draft' : r.status });
    const def = r.definition;
    this.definition.set(def.condition.type === 'group' ? def : { ...def, condition: { ...newGroup(false), children: [def.condition] } });
    this.definitionDirty.set(false);
    this.formDirty.set(false);
  }

  setCondition(condition: GroupNode) {
    this.definition.update(d => (d ? { ...d, condition } : d));
    this.definitionDirty.set(true);
  }

  isDisplayed(path: string) { return this.definition()?.output?.displayFields?.includes(path) ?? false; }

  toggleDisplay(path: string) {
    this.definition.update(d => {
      if (!d) return d;
      const current = d.output?.displayFields ?? [];
      const displayFields = current.includes(path) ? current.filter(p => p !== path) : [...current, path].slice(0, 10);
      return { ...d, output: { displayFields } };
    });
    this.definitionDirty.set(true);
  }

  async save() {
    const def = this.definition();
    if (this.form.invalid || !def) {
      this.form.markAllAsTouched();
      this.notifier.info('יש להשלים את השדות המסומנים.');
      return;
    }
    this.saving.set(true);
    try {
      const v = this.form.getRawValue();
      const body = { name: v.name, description: v.description || null, status: v.status, severity: v.severity, definition: def };
      const current = this.rule();
      const saved = current ? await this.api.updateRule(current.id, current.version, body) : await this.api.createRule(body);
      this.applyRule(saved);
      this.notifier.success('הבקרה נשמרה.');
      if (!current) await this.router.navigate(['/rules', saved.id]);
    } catch (err) {
      if (problemCode(err) === 'RULE_VALIDATION_FAILED') this.api.validate(def).then(r => this.validation.set(r)).catch(() => {});
      this.notifier.error(err);
    } finally {
      this.saving.set(false);
    }
  }

  async runPreview() {
    const def = this.definition();
    if (!def) return;
    this.previewing.set(true);
    try {
      this.preview.set(await this.api.preview(def));
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.previewing.set(false);
    }
  }

  async run() {
    const r = this.rule();
    if (!r) return;
    this.running.set(true);
    try {
      const run = await this.api.startRun(r.id);
      await this.router.navigate(['/runs', run.id]);
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.running.set(false);
    }
  }

  async showSql() {
    const r = this.rule();
    if (!r) return;
    try { this.sql.set(await this.api.ruleSql(r.id)); } catch (err) { this.notifier.error(err); }
  }
}

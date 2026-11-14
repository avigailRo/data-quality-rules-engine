import { Component, computed, inject, signal } from '@angular/core';
import { Api } from '../../core/api';
import { CatalogStore } from '../../core/catalog.store';
import { CatalogIssue, EntityDef } from '../../core/models';
import { Notifier, Session } from '../../core/session';
import { Icon } from '../../shared/icon';
import { PageState } from '../../shared/ui';

const TYPE_HE: Record<string, string> = {
  string: 'טקסט', integer: 'מספר שלם', decimal: 'מספר', date: 'תאריך', dateTime: 'תאריך ושעה', boolean: 'כן/לא', enum: 'רשימת ערכים',
};

/** Business view of the data: what users can build controls on, in business terms (no physical names). */
@Component({
  selector: 'dc-catalog',
  imports: [PageState, Icon],
  template: `
    <header class="page-header">
      <div>
        <h1>קטלוג הנתונים העסקי</h1>
        <p class="page-sub">הישויות, השדות והקשרים שאפשר לבנות עליהם בקרות, בשמות עסקיים. שמות הטבלאות והעמודות לא נחשפים לממשק.</p>
      </div>
      @if (session.isAdmin()) {
        <button type="button" class="btn" [disabled]="verifying()" (click)="verify()">
          <dc-icon name="check" /> {{ verifying() ? 'בודק…' : 'טעינה מחדש ואימות מול בסיס הנתונים' }}
        </button>
      }
    </header>

    @if (issues(); as list) {
      @if (list.length === 0) { <p class="notice" role="status"><dc-icon name="check" /> הקטלוג נטען מחדש ותואם את מבנה בסיס הנתונים.</p> }
      @else {
        <div class="notice notice-error" role="alert"><ul>@for (i of list; track $index) { <li>{{ i.entityKey }}{{ i.fieldKey ? '.' + i.fieldKey : '' }}: {{ i.messageHe }}</li> }</ul></div>
      }
    }

    <dc-page-state [loading]="!store.loaded() && !store.error()" [error]="store.error()" [skeleton]="3" (retry)="store.reload()">
      <section class="kpis kpis-3" aria-label="היקף הקטלוג">
        <div class="kpi"><span class="kpi-label">ישויות</span><span class="kpi-value">{{ store.entities().length }}</span></div>
        <div class="kpi"><span class="kpi-label">שדות</span><span class="kpi-value">{{ fieldCount() }}</span><span class="kpi-hint">{{ computedCount() }} מחושבים</span></div>
        <div class="kpi"><span class="kpi-label">קשרים</span><span class="kpi-value">{{ relationCount() }}</span></div>
      </section>

      <details class="help">
        <summary><dc-icon name="info" [size]="16" /> איך מרחיבים את הקטלוג לטבלה או לשדה חדשים?</summary>
        <ol class="help-steps">
          <li><strong>מגדירים Metadata:</strong> שורה ב־<code>dq.Entity</code> לטבלה, שורות ב־<code>dq.Field</code> לשדות (שם עסקי, טיפוס, ערכים מותרים) וב־<code>dq.Relationship</code> לקשרים. דוגמה מלאה: <code>db/06_seed_metadata.sql</code>.</li>
          <li><strong>מעניקים הרשאת קריאה בלבד:</strong> <code>GRANT SELECT</code> על הטבלה החדשה למשתמש ההרצה <code>dc_rule_reader</code>. בלי זה הבקרה לא תוכל לקרוא אותה – זו הגנה מכוונת.</li>
          <li><strong>טוענים ומאמתים:</strong> הכפתור "טעינה מחדש ואימות" (מנהל קטלוג) טוען את הקטלוג בלי הפעלה מחדש, ובודק שכל טבלה ועמודה קיימות ובטיפוס תואם.</li>
        </ol>
        <p class="muted small">מנוע הבקרות, ה־API והממשק לא משתנים: בונה הבקרות, ההסברים בעברית והמלצות ה־AI נבנים מהקטלוג.</p>
      </details>

      <div class="catalog-grid">
        @for (e of store.entities(); track e.key) {
          <section class="card entity-card">
            <header class="entity-head">
              <span class="entity-icon"><dc-icon name="database" [size]="18" /></span>
              <div>
                <h2>{{ e.displayNamePlural }}</h2>
                <span class="muted small">{{ e.fields.length }} שדות · {{ e.relationships.length }} קשרים</span>
              </div>
            </header>
            @if (e.description) { <p class="muted">{{ e.description }}</p> }
            <table class="table compact">
              <thead><tr><th>שדה</th><th>סוג</th><th><span class="sr-only">חובה עסקית</span></th></tr></thead>
              <tbody>
                @for (f of e.fields; track f.key) {
                  <tr>
                    <td>
                      {{ f.displayName }}
                      @if (f.isComputed) { <span class="badge" title="מחושב מתוך שדות אחרים">מחושב</span> }
                      @if (f.description) { <div class="muted small">{{ f.description }}</div> }
                    </td>
                    <td>
                      <span class="type-chip">{{ typeHe(f.dataType) }}@if (f.unit) { · {{ f.unit }} }</span>
                      @if (f.enumValues.length) { <div class="muted small">{{ enumText(f.enumValues) }}</div> }
                    </td>
                    <td>@if (f.isRequiredByBusiness) { <span class="badge" data-severity="Medium">חובה</span> }</td>
                  </tr>
                }
              </tbody>
            </table>
            @if (e.relationships.length) {
              <h3 class="rel-title"><dc-icon name="link" [size]="15" /> קשרים</h3>
              <ul class="rel-list">
                @for (r of e.relationships; track r.key) {
                  <li>
                    <span>{{ r.displayName }}</span>
                    <span class="rel-arrow" aria-hidden="true">←</span>
                    <span class="badge">{{ store.entity(r.toEntity)?.displayNamePlural }}</span>
                    <span class="muted small">{{ r.cardinality === 'manyToOne' ? 'רשומה אחת' : 'רשימת רשומות' }}</span>
                  </li>
                }
              </ul>
            }
          </section>
        }
      </div>
    </dc-page-state>
  `,
})
export class CatalogPage {
  private readonly api = inject(Api);
  private readonly notifier = inject(Notifier);
  protected readonly store = inject(CatalogStore);
  protected readonly session = inject(Session);
  protected readonly issues = signal<CatalogIssue[] | null>(null);
  protected readonly verifying = signal(false);

  protected readonly fieldCount = computed(() => this.store.entities().reduce((n, e) => n + e.fields.length, 0));
  protected readonly computedCount = computed(() => this.store.entities().reduce((n, e) => n + e.fields.filter(f => f.isComputed).length, 0));
  protected readonly relationCount = computed(() => this.store.entities().reduce((n: number, e: EntityDef) => n + e.relationships.length, 0));

  typeHe(t: string) { return TYPE_HE[t] ?? t; }
  enumText(values: { displayName: string }[]) { return values.map(v => v.displayName).join(' / '); }

  async verify() {
    this.verifying.set(true);
    try {
      const r = await this.api.verifyCatalog();
      this.issues.set(r.issues);
      await this.store.reload();   // the server reloaded the catalog - show the fresh version
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.verifying.set(false);
    }
  }
}

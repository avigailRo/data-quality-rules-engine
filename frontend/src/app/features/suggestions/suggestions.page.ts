import { DecimalPipe } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { Api } from '../../core/api';
import { AiStatus, GenerateResult, PreviewResult, Suggestion } from '../../core/models';
import { Notifier, Session } from '../../core/session';
import { ConfirmService } from '../../shared/confirm';
import { Icon } from '../../shared/icon';
import { PageState, SeverityBadge, StatusBadge } from '../../shared/ui';

interface PreviewState { loading: boolean; result?: PreviewResult; error?: string; }

/**
 * AI-powered data-quality recommendations.
 * Every suggestion is a typed rule AST validated by the server. The source is always shown honestly:
 * "LLM" only when a language model produced it, "local analysis" for the deterministic engine.
 * Approval creates a DRAFT rule - nothing is saved as active or run automatically.
 */
@Component({
  selector: 'dc-suggestions',
  imports: [DecimalPipe, Icon, PageState, StatusBadge, SeverityBadge],
  template: `
    <header class="page-header">
      <div>
        <h1>המלצות לבקרות איכות נתונים</h1>
        <p class="page-sub">המערכת מנתחת את מבנה הנתונים והסטטיסטיקה שלהם ומציעה בקרות. כל הצעה נבדקת ומחכה לאישור שלך.</p>
      </div>
      @if (session.canAuthor()) {
        <button type="button" class="btn btn-primary" [disabled]="generating() || !status()?.available" (click)="generate()">
          <dc-icon name="sparkles" /> {{ generating() ? 'מנתח את הנתונים…' : 'נתח והצע בקרות' }}
        </button>
      }
    </header>

    <section class="ai-pipeline card" aria-label="איך זה עובד">
      <ol>
        <li><dc-icon name="database" /><div><strong>ניתוח מבנה</strong><span>ישויות, שדות וקשרים מהקטלוג העסקי</span></div></li>
        <li><dc-icon name="cpu" /><div><strong>פרופיל סטטיסטי</strong><span>חוסרים, סדר תאריכים, חריגים – אגרגציות בלבד</span></div></li>
        <li><dc-icon name="sparkles" /><div><strong>יצירת הצעות</strong><span>{{ engineLabel() }}</span></div></li>
        <li><dc-icon name="check" /><div><strong>אימות ואישור</strong><span>ולידציה כפולה, ואז אישור אנושי לטיוטה</span></div></li>
      </ol>
      @if (status(); as s) {
        <p class="ai-status" [class.off]="!s.available">
          <span class="dot" [class.dot-ok]="s.available" [class.dot-off]="!s.available" aria-hidden="true"></span>
          @if (s.available) {
            @if (s.isLlm) { מנוע מוגדר: מודל שפה ({{ s.model ?? s.provider }}). נשלחים אליו שמות עסקיים וסטטיסטיקה מצטברת בלבד – ללא רשומות. אם המודל אינו זמין, הניתוח המקומי עונה במקומו וכל הצעה מסומנת לפי המקור שיצר אותה בפועל. }
            @else { מנוע מוגדר: ניתוח מקומי מבוסס Metadata וסטטיסטיקה. לא מוגדר מודל שפה (LLM), ולכן ההמלצות דטרמיניסטיות. }
          } @else { שירות ההמלצות אינו זמין כרגע. שאר המערכת פועלת כרגיל – אפשר ליצור ולהריץ בקרות ידנית. }
        </p>
      }
    </section>

    @if (lastResult(); as r) {
      <div class="notice" role="status">
        <dc-icon name="info" />
        <span>
          נוצרו {{ r.proposed }} הצעות חדשות ({{ r.isLlm ? 'מודל שפה ' + (r.model ?? r.provider) : 'ניתוח מקומי' }}).
          @if (r.fallbackUsed) { מודל השפה לא היה זמין ({{ r.fallbackReason }}) ולכן הופעל הניתוח המקומי. }
          @if (r.invalid) { {{ r.invalid }} נפסלו בבדיקת התקינות. }
          @if (r.rejectedByAdvisor) { {{ r.rejectedByAdvisor }} תשובות לא תקינות של המודל נדחו. }
          @if (r.duplicates) { {{ r.duplicates }} הושמטו כי בקרה או הצעה זהה כבר קיימות. }
        </span>
      </div>
    }

    @if (!session.canAuthor()) {
      <p class="notice"><dc-icon name="info" /> צפייה בהמלצות זמינה לכותבי בקרות.</p>
    } @else {
      <div class="tabs" role="tablist" aria-label="סינון לפי סטטוס">
        @for (t of tabs; track t.value) {
          <button type="button" role="tab" class="tab" [class.on]="filter() === t.value" [attr.aria-selected]="filter() === t.value" (click)="setFilter(t.value)">{{ t.label }}</button>
        }
      </div>

      <dc-page-state [loading]="loading()" [error]="error()" [empty]="items().length === 0" [skeleton]="3"
                     emptyText="אין הצעות בקטגוריה זו. לחצו על 'נתח והצע בקרות' כדי להתחיל." (retry)="load()">
        <div class="suggestion-grid">
          @for (s of items(); track s.id) {
            <article class="card suggestion" [attr.aria-labelledby]="'sg-' + s.id">
              <header class="suggestion-head">
                <div class="suggestion-tags">
                  <span class="badge" [attr.data-kind]="s.source === 'llm' ? 'ai' : 'local'">
                    <dc-icon [name]="s.source === 'llm' ? 'sparkles' : 'cpu'" [size]="14" />
                    {{ s.source === 'llm' ? 'מודל שפה' + (s.model ? ' · ' + s.model : '') : 'ניתוח מקומי' }}
                  </span>
                  <dc-severity [severity]="s.severity" />
                  @if (s.status !== 'Proposed') { <dc-status [status]="s.status" /> }
                </div>
                <h2 [id]="'sg-' + s.id">{{ s.title }}</h2>
                @if (s.rootEntityName) { <span class="muted small">נושא: {{ s.rootEntityName }}</span> }
              </header>

              <p>{{ s.explanationHe }}</p>
              @if (s.evidence) { <p class="evidence"><dc-icon name="alert" [size]="16" /> <span><strong>למה זה רלוונטי:</strong> {{ s.evidence }}</span></p> }
              @if (s.summaryHe) { <p class="rule-sentence"><strong>מה הבקרה תאתר:</strong> {{ s.summaryHe }}</p> }

              @if (s.involvedFields.length) {
                <div class="chips" aria-label="שדות מעורבים">
                  <span class="muted small">שדות:</span>
                  @for (f of s.involvedFields; track f) { <span class="chip-static">{{ f }}</span> }
                </div>
              }

              @if (s.validationErrors.length) {
                <ul class="field-error">@for (e of s.validationErrors; track $index) { <li>{{ e.messageHe }}</li> }</ul>
              }

              @if (previews()[s.id]; as p) {
                <div class="preview-box" aria-live="polite">
                  @if (p.loading) { <span class="spinner" aria-hidden="true"></span> מחשב תצוגה מקדימה… }
                  @else if (p.error) { <span class="field-error">{{ p.error }}</span> }
                  @else if (p.result) {
                    <strong>{{ p.result.totalCount | number }} רשומות יזוהו כחריגות.</strong>
                    @if (p.result.items.length) {
                      <ul class="preview-list">
                        @for (v of p.result.items.slice(0, 3); track v.recordKey) { <li>{{ v.displayLabel }} – {{ v.reasons[0]?.textHe }}</li> }
                      </ul>
                    }
                  }
                </div>
              }

              <footer class="actions">
                @if (s.status === 'Proposed') {
                  <button type="button" class="btn btn-small" (click)="preview(s)"><dc-icon name="eye" [size]="16" /> תצוגה מקדימה</button>
                  <button type="button" class="btn btn-small btn-primary" [disabled]="busy() === s.id" (click)="accept(s)"><dc-icon name="check" [size]="16" /> אישור כטיוטה</button>
                  <button type="button" class="btn btn-small btn-ghost" [disabled]="busy() === s.id" (click)="reject(s)"><dc-icon name="x" [size]="16" /> דחייה</button>
                }
                @if (s.status === 'Accepted' && s.acceptedRuleId) {
                  <button type="button" class="btn btn-small" (click)="open(s.acceptedRuleId)"><dc-icon name="edit" [size]="16" /> לבקרה שנוצרה</button>
                }
              </footer>
            </article>
          }
        </div>
      </dc-page-state>
    }
  `,
})
export class SuggestionsPage {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly notifier = inject(Notifier);
  private readonly confirm = inject(ConfirmService);
  protected readonly session = inject(Session);

  protected readonly tabs = [
    { value: 'Proposed', label: 'ממתינות לבדיקה' },
    { value: 'Accepted', label: 'אושרו' },
    { value: 'Rejected', label: 'נדחו' },
    { value: 'Invalid', label: 'נפסלו בבדיקה' },
  ];

  protected readonly status = signal<AiStatus | null>(null);
  protected readonly items = signal<Suggestion[]>([]);
  protected readonly filter = signal('Proposed');
  protected readonly loading = signal(false);
  protected readonly error = signal<unknown>(null);
  protected readonly generating = signal(false);
  protected readonly busy = signal<string | null>(null);
  protected readonly lastResult = signal<GenerateResult | null>(null);
  protected readonly previews = signal<Record<string, PreviewState>>({});

  constructor() {
    this.api.aiStatus().then(s => this.status.set(s)).catch(() => this.status.set({ available: false, isLlm: false }));
    if (this.session.canAuthor()) this.load();
  }

  engineLabel(): string {
    const s = this.status();
    if (!s?.available) return 'השירות אינו זמין';
    return s.isLlm ? `מודל שפה (${s.model ?? s.provider}) עם פלט JSON מובנה` : 'מנוע כללים מקומי (ללא LLM)';
  }

  setFilter(value: string) { this.filter.set(value); this.load(); }

  async load() {
    this.loading.set(true);
    this.error.set(null);
    try { this.items.set(await this.api.suggestions(this.filter())); }
    catch (err) { this.error.set(err); }
    finally { this.loading.set(false); }
  }

  async generate() {
    this.generating.set(true);
    try {
      this.lastResult.set(await this.api.generateSuggestions(8));
      this.filter.set('Proposed');
      await this.load();
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.generating.set(false);
    }
  }

  async preview(s: Suggestion) {
    this.previews.update(p => ({ ...p, [s.id]: { loading: true } }));
    try {
      const result = await this.api.preview(s.definition);
      this.previews.update(p => ({ ...p, [s.id]: { loading: false, result } }));
    } catch {
      this.previews.update(p => ({ ...p, [s.id]: { loading: false, error: 'לא ניתן לחשב תצוגה מקדימה כרגע.' } }));
    }
  }

  async accept(s: Suggestion) {
    const ok = await this.confirm.ask({
      title: 'לאשר את ההצעה?',
      message: `"${s.title}" תישמר כבקרה בסטטוס טיוטה. היא לא תופעל ולא תורץ עד שתבחרי בכך.`,
      confirmText: 'אישור ושמירה כטיוטה',
    });
    if (!ok) return;
    this.busy.set(s.id);
    try {
      const rule = await this.api.acceptSuggestion(s.id);
      this.notifier.success('ההצעה נשמרה כטיוטה. אפשר לבדוק, לערוך ולהריץ.');
      await this.router.navigate(['/rules', rule.id]);
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.busy.set(null);
    }
  }

  async reject(s: Suggestion) {
    const ok = await this.confirm.ask({ title: 'לדחות את ההצעה?', message: `"${s.title}" תסומן כנדחתה.`, confirmText: 'דחייה', tone: 'danger' });
    if (!ok) return;
    this.busy.set(s.id);
    try {
      await this.api.rejectSuggestion(s.id);
      await this.load();
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.busy.set(null);
    }
  }

  open(id: string) { this.router.navigate(['/rules', id]); }
}

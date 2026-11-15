import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Api } from '../../core/api';
import { AiStatus, Rule } from '../../core/models';
import { Session } from '../../core/session';
import { Icon } from '../../shared/icon';
import { PageState, SeverityBadge, StatusBadge } from '../../shared/ui';

/** Overview built only from real data: the rules list (with each rule's latest run) and the AI service status. */
@Component({
  selector: 'dc-dashboard',
  imports: [RouterLink, DatePipe, DecimalPipe, Icon, PageState, StatusBadge, SeverityBadge],
  template: `
    <header class="page-header">
      <div>
        <h1>סקירה כללית</h1>
        <p class="page-sub">מצב איכות הנתונים לפי ההרצה האחרונה של כל בקרה.</p>
      </div>
      @if (session.canAuthor()) { <a routerLink="/rules/new" class="btn btn-primary"><dc-icon name="plus" /> בקרה חדשה</a> }
    </header>

    <dc-page-state [loading]="loading()" [error]="error()" [skeleton]="4" (retry)="load()">
      <section class="kpis" aria-label="מדדים">
        <div class="kpi"><span class="kpi-label">בקרות פעילות</span><span class="kpi-value">{{ activeCount() }}</span><span class="kpi-hint">{{ draftCount() }} טיוטות</span></div>
        <div class="kpi" [class.kpi-alert]="openViolations() > 0"><span class="kpi-label">חריגות פתוחות</span><span class="kpi-value">{{ openViolations() | number }}</span><span class="kpi-hint">לפי ההרצות האחרונות</span></div>
        <div class="kpi"><span class="kpi-label">בקרות עם חריגות</span><span class="kpi-value">{{ withViolations().length }}</span><span class="kpi-hint">מתוך {{ ranRules().length }} שהורצו</span></div>
        <div class="kpi" [class.kpi-warn]="neverRun().length > 0"><span class="kpi-label">טרם הורצו</span><span class="kpi-value">{{ neverRun().length }}</span><span class="kpi-hint">{{ failedRuns().length }} הרצות אחרונות נכשלו</span></div>
      </section>

      <div class="grid-2">
        <section class="card">
          <h2 class="card-title"><dc-icon name="alert" /> הבקרות עם הכי הרבה חריגות</h2>
          @if (topRules().length === 0) {
            <p class="muted">אין חריגות בהרצות האחרונות. 🎉</p>
          } @else {
            <ul class="bar-list">
              @for (r of topRules(); track r.id) {
                <li>
                  <div class="bar-head">
                    <a [routerLink]="['/runs', r.lastRun!.id]">{{ r.name }}</a>
                    <span class="bar-value">{{ (r.lastRun!.violationCount ?? 0) | number }}</span>
                  </div>
                  <div class="bar"><span [style.width.%]="barWidth(r)"></span></div>
                  <div class="bar-meta"><dc-severity [severity]="r.severity" /> <span class="muted small">{{ r.lastRun!.finishedAt | date: 'dd/MM/yy HH:mm' }}</span></div>
                </li>
              }
            </ul>
          }
        </section>

        <section class="card">
          <h2 class="card-title"><dc-icon name="history" /> דורש תשומת לב</h2>
          @if (neverRun().length === 0 && failedRuns().length === 0) {
            <p class="muted">כל הבקרות הורצו בהצלחה.</p>
          } @else {
            <ul class="plain-list">
              @for (r of failedRuns(); track r.id) {
                <li><dc-status [status]="r.lastRun!.status" /> <a [routerLink]="['/runs', r.lastRun!.id]">{{ r.name }}</a></li>
              }
              @for (r of neverRun(); track r.id) {
                <li><span class="badge">טרם הורצה</span> <a [routerLink]="['/rules', r.id]">{{ r.name }}</a></li>
              }
            </ul>
          }
          <h2 class="card-title spaced"><dc-icon name="sparkles" /> המלצות AI</h2>
          @if (ai(); as a) {
            <p>
              @if (a.available) {
                <span class="dot dot-ok" aria-hidden="true"></span> השירות זמין ·
                {{ a.isLlm ? 'מודל שפה: ' + (a.model ?? a.provider) : 'מנוע המלצות מקומי (בתוך הארגון)' }}
              } @else { <span class="dot dot-off" aria-hidden="true"></span> השירות אינו זמין כרגע – שאר המערכת פועלת כרגיל. }
            </p>
          }
          <a routerLink="/suggestions" class="btn btn-small">למסך ההמלצות</a>
        </section>
      </div>
    </dc-page-state>
  `,
})
export class DashboardPage {
  private readonly api = inject(Api);
  protected readonly session = inject(Session);

  protected readonly rules = signal<Rule[]>([]);
  protected readonly ai = signal<AiStatus | null>(null);
  protected readonly loading = signal(true);
  protected readonly error = signal<unknown>(null);

  protected readonly activeCount = computed(() => this.rules().filter(r => r.status === 'Active').length);
  protected readonly draftCount = computed(() => this.rules().filter(r => r.status === 'Draft').length);
  protected readonly ranRules = computed(() => this.rules().filter(r => r.lastRun?.status === 'Succeeded'));
  protected readonly withViolations = computed(() => this.ranRules().filter(r => (r.lastRun?.violationCount ?? 0) > 0));
  protected readonly openViolations = computed(() => this.ranRules().reduce((n, r) => n + (r.lastRun?.violationCount ?? 0), 0));
  protected readonly neverRun = computed(() => this.rules().filter(r => !r.lastRun));
  protected readonly failedRuns = computed(() => this.rules().filter(r => r.lastRun && ['Failed', 'TimedOut'].includes(r.lastRun.status)));
  protected readonly topRules = computed(() =>
    [...this.withViolations()].sort((a, b) => (b.lastRun!.violationCount ?? 0) - (a.lastRun!.violationCount ?? 0)).slice(0, 6));
  private readonly maxViolations = computed(() => Math.max(1, ...this.topRules().map(r => r.lastRun!.violationCount ?? 0)));

  constructor() { this.load(); }

  barWidth(r: Rule): number { return Math.max(4, Math.round(((r.lastRun?.violationCount ?? 0) / this.maxViolations()) * 100)); }

  async load() {
    this.loading.set(true);
    this.error.set(null);
    try {
      const [page, ai] = await Promise.all([
        this.api.rules({ page: 1, pageSize: 100 }),
        this.api.aiStatus().catch(() => ({ available: false, provider: null, model: null, isLlm: false } as AiStatus)),
      ]);
      this.rules.set(page.items);
      this.ai.set(ai);
    } catch (err) {
      this.error.set(err);
    } finally {
      this.loading.set(false);
    }
  }
}

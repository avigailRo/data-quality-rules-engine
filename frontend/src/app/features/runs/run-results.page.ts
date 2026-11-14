import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, DestroyRef, computed, effect, inject, input, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { Api } from '../../core/api';
import { RUN_TERMINAL, Run, ViolationPage } from '../../core/models';
import { Notifier, Session } from '../../core/session';
import { PageState, Pager, StatusBadge } from '../../shared/ui';

@Component({
  selector: 'dc-run-results',
  imports: [RouterLink, DatePipe, DecimalPipe, PageState, Pager, StatusBadge],
  template: `
    <a routerLink="/rules" class="back">→ חזרה לרשימת הבקרות</a>

    <dc-page-state [loading]="!run() && !error()" [error]="error()" (retry)="poll()">
      @if (run(); as r) {
        <div class="page-head">
          <h1>תוצאות: {{ r.ruleName }}</h1>
          <div class="actions">
            <a class="btn" [routerLink]="['/rules', r.ruleId]">לבקרה</a>
            @if (session.canAuthor() && terminal()) { <button type="button" class="btn btn-primary" (click)="runAgain(r)">הרצה מחדש</button> }
          </div>
        </div>

        <div class="cards" aria-live="polite">
          <div class="stat"><span class="stat-label">סטטוס</span><dc-status [status]="r.status" /></div>
          <div class="stat"><span class="stat-label">רשומות חריגות</span><strong class="stat-value">{{ r.violationCount === null || r.violationCount === undefined ? '—' : (r.violationCount | number) }}</strong></div>
          <div class="stat"><span class="stat-label">משך</span><strong>{{ r.durationMs !== null && r.durationMs !== undefined ? (r.durationMs | number) + ' מילישניות' : '—' }}</strong></div>
          <div class="stat"><span class="stat-label">גרסת בקרה</span><strong>גרסה {{ r.ruleVersionNo }}</strong><span class="stat-sub">הופעל ע"י <bdi>{{ r.triggeredBy }}</bdi></span></div>
          <div class="stat"><span class="stat-label">מועד</span><strong>{{ r.queuedAt | date: 'dd/MM/yyyy HH:mm:ss' }}</strong></div>
        </div>

        @if (!terminal()) { <p class="state" role="status"><span class="spinner" aria-hidden="true"></span> הבקרה רצה…</p> }
        @if (r.errorMessage) { <p class="notice notice-error" role="alert">{{ r.errorMessage }}</p> }
        @if (r.isTruncated) { <p class="notice">נשמרו {{ r.storedCount | number }} רשומות ראשונות מתוך {{ r.violationCount | number }}.</p> }

        @if (r.status === 'Succeeded') {
          <div class="filters" role="search">
            <label>חיפוש בתוצאות
              <input type="search" placeholder="שם, ערך או סיבה" [value]="search()" (input)="onSearch($any($event.target).value)" />
            </label>
            @if ((page()?.conditions?.length ?? 0) > 1) {
              <label>סינון לפי סיבת החריגה
                <select [value]="conditionId()" (change)="conditionId.set($any($event.target).value); loadPage(1)">
                  <option value="">כל הסיבות</option>
                  @for (c of page()!.conditions; track c.id) { <option [value]="c.id" [selected]="c.id === conditionId()">{{ c.textHe }}</option> }
                </select>
              </label>
            }
          </div>

          <dc-page-state [loading]="pageLoading()" [error]="pageError()" [empty]="(page()?.items?.length ?? 0) === 0"
                         [emptyText]="search() || conditionId() ? 'אין תוצאות התואמות לסינון.' : 'לא נמצאו רשומות חריגות – הנתונים תקינים לפי בקרה זו.'"
                         (retry)="loadPage()">
            @if (page(); as pg) {
            <table class="table responsive">
              <thead>
                <tr>
                  <th>רשומה</th>
                  @for (c of pg.columns; track c.key) { <th>{{ c.displayName }}</th> }
                  <th>סיבת החריגה</th>
                </tr>
              </thead>
              <tbody>
                @for (v of pg.items; track v.recordKey) {
                  <tr>
                    <td data-label="רשומה"><strong>{{ v.displayLabel }}</strong></td>
                    @for (c of pg.columns; track c.key) { <td [attr.data-label]="c.displayName"><bdi>{{ cell(v.values[c.key]) }}</bdi></td> }
                    <td data-label="סיבת החריגה">
                      <ul class="reasons">@for (reason of v.reasons; track reason.conditionId) { <li>{{ reason.textHe }}</li> }</ul>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
            <dc-pager [page]="pg.page" [pageSize]="pg.pageSize" [total]="pg.totalCount" (pageChange)="loadPage($event)" />
            }
          </dc-page-state>
        }
      }
    </dc-page-state>
  `,
})
export class RunResultsPage {
  private readonly api = inject(Api);

  /** Values are pre-formatted by the server for sentences (strings in quotes); a table cell shows them bare. */
  protected cell(value: unknown): string {
    const text = value === null || value === undefined ? '' : String(value);
    return text.length >= 2 && text.startsWith('"') && text.endsWith('"') ? text.slice(1, -1) : text;
  }
  private readonly router = inject(Router);
  private readonly notifier = inject(Notifier);
  protected readonly session = inject(Session);

  readonly runId = input.required<string>();

  protected readonly run = signal<Run | null>(null);
  protected readonly error = signal<unknown>(null);
  protected readonly page = signal<ViolationPage | null>(null);
  protected readonly pageLoading = signal(false);
  protected readonly pageError = signal<unknown>(null);
  protected readonly search = signal('');
  protected readonly conditionId = signal('');
  protected readonly terminal = computed(() => { const r = this.run(); return !!r && RUN_TERMINAL.includes(r.status); });

  private timer?: ReturnType<typeof setTimeout>;
  private searchTimer?: ReturnType<typeof setTimeout>;
  private delay = 500;

  constructor() {
    effect(() => {
      this.runId();
      queueMicrotask(() => {
        this.run.set(null);
        this.page.set(null);
        this.delay = 500;
        this.poll();
      });
    });
    inject(DestroyRef).onDestroy(() => { clearTimeout(this.timer); clearTimeout(this.searchTimer); });
  }

  /** Polls the run status with back-off until it reaches a terminal state, then loads the first page. */
  async poll() {
    clearTimeout(this.timer);
    this.error.set(null);
    try {
      const r = await this.api.run(this.runId());
      this.run.set(r);
      if (RUN_TERMINAL.includes(r.status)) {
        if (r.status === 'Succeeded') await this.loadPage(1);
      } else {
        this.delay = Math.min(this.delay * 1.5, 4000);
        this.timer = setTimeout(() => this.poll(), this.delay);
      }
    } catch (err) {
      this.error.set(err);
    }
  }

  onSearch(text: string) {
    this.search.set(text);
    clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => this.loadPage(1), 350);
  }

  async loadPage(pageNo = this.page()?.page ?? 1) {
    this.pageLoading.set(true);
    this.pageError.set(null);
    try {
      this.page.set(await this.api.violations(this.runId(), { search: this.search(), conditionId: this.conditionId(), page: pageNo, pageSize: 25 }));
    } catch (err) {
      this.pageError.set(err);
    } finally {
      this.pageLoading.set(false);
    }
  }

  async runAgain(r: Run) {
    try {
      const run = await this.api.startRun(r.ruleId);
      await this.router.navigate(['/runs', run.id]);
    } catch (err) { this.notifier.error(err); }
  }
}

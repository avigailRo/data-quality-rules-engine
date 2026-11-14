import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { Router, RouterLink } from '@angular/router';
import { Api } from '../../core/api';
import { CatalogStore } from '../../core/catalog.store';
import { Paged, Rule } from '../../core/models';
import { Notifier, Session } from '../../core/session';
import { ConfirmService } from '../../shared/confirm';
import { Icon } from '../../shared/icon';
import { PageState, Pager, SeverityBadge, StatusBadge } from '../../shared/ui';

@Component({
  selector: 'dc-rule-list',
  imports: [RouterLink, DatePipe, DecimalPipe, Icon, PageState, Pager, StatusBadge, SeverityBadge],
  template: `
    <header class="page-header">
      <div>
        <h1>בקרות נתונים</h1>
        <p class="page-sub">בקרה מגדירה אילו רשומות נחשבות חריגות. מריצים אותה כדי לקבל את הרשומות ואת הסיבה לחריגה.</p>
      </div>
      @if (session.canAuthor()) { <a routerLink="/rules/new" class="btn btn-primary"><dc-icon name="plus" /> בקרה חדשה</a> }
    </header>

    <div class="filters" role="search">
      <label>חיפוש
        <input type="search" placeholder="שם או תיאור" [value]="search()" (input)="onSearch($any($event.target).value)" />
      </label>
      <label>נושא
        <select [value]="entity()" (change)="entity.set($any($event.target).value); reload(1)">
          <option value="">הכל</option>
          @for (e of store.entities(); track e.key) { <option [value]="e.key" [selected]="e.key === entity()">{{ e.displayNamePlural }}</option> }
        </select>
      </label>
      <label>סטטוס
        <select [value]="status()" (change)="status.set($any($event.target).value); reload(1)">
          <option value="">פעילות וטיוטות</option>
          <option value="Active">פעילות</option>
          <option value="Draft">טיוטות</option>
          <option value="Archived">בארכיון</option>
        </select>
      </label>
    </div>

    <dc-page-state [loading]="loading()" [error]="error()" [skeleton]="6" [empty]="(data()?.items?.length ?? 0) === 0"
                   emptyText="לא נמצאו בקרות. אפשר ליצור בקרה חדשה או לבקש המלצות מה־AI." (retry)="reload()">
      @if (data(); as d) {
      <table class="table responsive">
        <thead>
          <tr><th>שם הבקרה</th><th>נושא</th><th>סטטוס</th><th>חומרה</th><th>הרצה אחרונה</th><th><span class="sr-only">פעולות</span></th></tr>
        </thead>
        <tbody>
          @for (r of d.items; track r.id) {
            <tr>
              <td data-label="שם הבקרה">
                <a [routerLink]="['/rules', r.id]" class="rule-name">{{ r.name }}</a>
                @if (r.summaryHe) { <div class="muted small">{{ r.summaryHe }}</div> }
              </td>
              <td data-label="נושא">{{ r.rootEntity.displayName }}</td>
              <td data-label="סטטוס"><dc-status [status]="r.status" /> @if (r.origin === 'AI') { <span class="badge" data-kind="ai">AI</span> }</td>
              <td data-label="חומרה"><dc-severity [severity]="r.severity" /></td>
              <td data-label="הרצה אחרונה">
                @if (r.lastRun; as lr) {
                  <a [routerLink]="['/runs', lr.id]">
                    @if (lr.status === 'Succeeded') { {{ (lr.violationCount ?? 0) | number }} חריגות } @else { <dc-status [status]="lr.status" /> }
                  </a>
                  <div class="muted small">{{ lr.finishedAt | date: 'dd/MM/yy HH:mm' }}</div>
                } @else { <span class="muted">טרם הורצה</span> }
              </td>
              <td class="row-actions">
                @if (session.canAuthor() && r.status !== 'Archived') {
                  <button type="button" class="btn btn-small btn-primary" [disabled]="busy() === r.id" (click)="run(r)" [attr.aria-label]="'הרצת ' + r.name"><dc-icon name="play" [size]="14" /> הרצה</button>
                  <button type="button" class="icon-btn" (click)="duplicate(r)" [attr.aria-label]="'שכפול ' + r.name" title="שכפול"><dc-icon name="copy" /></button>
                  <button type="button" class="icon-btn" (click)="archive(r)" [attr.aria-label]="'העברה לארכיון ' + r.name" title="לארכיון"><dc-icon name="archive" /></button>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>
      <dc-pager [page]="page()" [pageSize]="pageSize" [total]="d.totalCount" (pageChange)="reload($event)" />
      }
    </dc-page-state>
  `,
})
export class RuleListPage {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  private readonly notifier = inject(Notifier);
  private readonly confirm = inject(ConfirmService);
  protected readonly store = inject(CatalogStore);
  protected readonly session = inject(Session);

  protected readonly data = signal<Paged<Rule> | null>(null);
  protected readonly loading = signal(true);
  protected readonly error = signal<unknown>(null);
  protected readonly busy = signal<string | null>(null);
  protected readonly search = signal('');
  protected readonly entity = signal('');
  protected readonly status = signal('');
  protected readonly page = signal(1);
  protected readonly pageSize = 20;
  private searchTimer?: ReturnType<typeof setTimeout>;

  constructor() { this.reload(); }

  onSearch(text: string) {
    this.search.set(text);
    clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => this.reload(1), 350);
  }

  async reload(page = this.page()) {
    this.page.set(page);
    this.loading.set(true);
    this.error.set(null);
    try {
      this.data.set(await this.api.rules({ search: this.search(), entity: this.entity(), status: this.status(), page, pageSize: this.pageSize }));
    } catch (err) {
      this.error.set(err);
    } finally {
      this.loading.set(false);
    }
  }

  async run(r: Rule) {
    this.busy.set(r.id);
    try {
      const run = await this.api.startRun(r.id);
      await this.router.navigate(['/runs', run.id]);
    } catch (err) {
      this.notifier.error(err);
    } finally {
      this.busy.set(null);
    }
  }

  async duplicate(r: Rule) {
    try {
      const copy = await this.api.duplicateRule(r.id);
      this.notifier.success('נוצר עותק כטיוטה.');
      await this.router.navigate(['/rules', copy.id]);
    } catch (err) { this.notifier.error(err); }
  }

  async archive(r: Rule) {
    const ok = await this.confirm.ask({
      title: 'להעביר לארכיון?', message: `"${r.name}" תוסר מרשימת הבקרות הפעילות. היסטוריית ההרצות נשמרת.`,
      confirmText: 'העברה לארכיון', tone: 'danger',
    });
    if (!ok) return;
    try {
      await this.api.archiveRule(r.id);
      this.notifier.success('הבקרה הועברה לארכיון.');
      await this.reload();
    } catch (err) { this.notifier.error(err); }
  }
}

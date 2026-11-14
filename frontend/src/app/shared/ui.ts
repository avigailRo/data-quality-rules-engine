import { Component, computed, input, output } from '@angular/core';
import { STATUS_HE, SEVERITY_HE, Severity } from '../core/models';
import { errorMessage } from '../core/session';

/** One place for loading / error / empty states, so every screen behaves the same way. */
@Component({
  selector: 'dc-page-state',
  template: `
    @if (loading()) {
      @if (skeleton() > 0) {
        <div class="skeleton-list" role="status" aria-live="polite">
          <span class="sr-only">{{ loadingText() }}</span>
          @for (r of skeletonRows(); track $index) { <div class="skeleton-row"><span></span><span></span><span></span></div> }
        </div>
      } @else {
        <div class="state" role="status" aria-live="polite">
          <span class="spinner" aria-hidden="true"></span> {{ loadingText() }}
        </div>
      }
    } @else if (error()) {
      <div class="state state-error" role="alert">
        <span class="state-icon" aria-hidden="true">!</span>
        <p>{{ message() }}</p>
        <button type="button" class="btn" (click)="retry.emit()">נסו שוב</button>
      </div>
    } @else if (empty()) {
      <div class="state state-empty">
        <p>{{ emptyText() }}</p>
        <ng-content select="[empty-action]" />
      </div>
    } @else {
      <ng-content />
    }
  `,
})
export class PageState {
  readonly loading = input(false);
  readonly error = input<unknown>(null);
  readonly empty = input(false);
  readonly loadingText = input('טוען…');
  readonly emptyText = input('אין נתונים להצגה.');
  /** Number of skeleton rows to show while loading (0 = spinner). */
  readonly skeleton = input(0);
  protected readonly skeletonRows = computed(() => Array.from({ length: this.skeleton() }));
  readonly retry = output<void>();
  protected readonly message = computed(() => errorMessage(this.error()));
}

@Component({
  selector: 'dc-status',
  template: `<span class="badge" [attr.data-status]="status()">{{ label() }}</span>`,
})
export class StatusBadge {
  readonly status = input.required<string>();
  protected readonly label = computed(() => STATUS_HE[this.status()] ?? this.status());
}

@Component({
  selector: 'dc-severity',
  template: `<span class="badge" [attr.data-severity]="severity()">חומרה {{ label() }}</span>`,
})
export class SeverityBadge {
  readonly severity = input.required<Severity>();
  protected readonly label = computed(() => SEVERITY_HE[this.severity()]);
}

@Component({
  selector: 'dc-pager',
  template: `
    @if (totalPages() > 1) {
      <nav class="pager" aria-label="דפדוף">
        <button type="button" class="btn" [disabled]="page() <= 1" (click)="pageChange.emit(page() - 1)">הקודם</button>
        <span>עמוד {{ page() }} מתוך {{ totalPages() }} ({{ total() }} רשומות)</span>
        <button type="button" class="btn" [disabled]="page() >= totalPages()" (click)="pageChange.emit(page() + 1)">הבא</button>
      </nav>
    }
  `,
})
export class Pager {
  readonly page = input.required<number>();
  readonly pageSize = input.required<number>();
  readonly total = input.required<number>();
  readonly pageChange = output<number>();
  protected readonly totalPages = computed(() => Math.max(1, Math.ceil(this.total() / this.pageSize())));
}

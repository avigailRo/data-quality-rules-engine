import { Component, inject } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { CatalogStore } from './core/catalog.store';
import { DEMO_USERS, DemoUser, Notifier, Session } from './core/session';
import { ConfirmHost } from './shared/confirm';
import { Icon } from './shared/icon';

@Component({
  selector: 'dc-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, Icon, ConfirmHost],
  template: `
    <a class="skip-link" href="#main">דלג לתוכן</a>
    <div class="shell">
      <aside class="sidebar" aria-label="ניווט ראשי">
        <div class="brand">
          <span class="brand-mark" aria-hidden="true"><dc-icon name="layers" [size]="20" /></span>
          <div><strong>בקרות נתונים</strong><span class="brand-sub">איכות נתונים ארגונית</span></div>
        </div>
        <nav class="side-nav">
          <a routerLink="/dashboard" routerLinkActive="active"><dc-icon name="dashboard" /> סקירה כללית</a>
          <a routerLink="/rules" routerLinkActive="active"><dc-icon name="rules" /> בקרות</a>
          <a routerLink="/suggestions" routerLinkActive="active"><dc-icon name="sparkles" /> המלצות AI</a>
          <a routerLink="/catalog" routerLinkActive="active"><dc-icon name="database" /> קטלוג נתונים</a>
        </nav>
        <label class="user-switch">
          <span class="user-switch-label"><dc-icon name="user" [size]="16" /> משתמש דמו</span>
          <select [value]="session.user()" (change)="switchUser($any($event.target).value)">
            @for (u of users; track u.id) { <option [value]="u.id" [selected]="u.id === session.user()">{{ u.label }}</option> }
          </select>
        </label>
      </aside>

      <main id="main" class="content" tabindex="-1">
        <router-outlet />
      </main>
    </div>

    <dc-confirm-host />

    <div class="toasts" aria-live="polite" aria-atomic="false">
      @for (t of notifier.toasts(); track t.id) {
        <div class="toast" [attr.data-kind]="t.kind" role="status">
          <dc-icon [name]="t.kind === 'error' ? 'alert' : t.kind === 'success' ? 'check' : 'info'" />
          <span>{{ t.text }}</span>
          <button type="button" class="icon-btn" aria-label="סגירת הודעה" (click)="notifier.dismiss(t.id)"><dc-icon name="x" [size]="16" /></button>
        </div>
      }
    </div>
  `,
})
export class App {
  protected readonly session = inject(Session);
  protected readonly notifier = inject(Notifier);
  protected readonly users = DEMO_USERS;

  constructor() {
    inject(CatalogStore).load().catch(() => { /* each page shows its own error state */ });
  }

  switchUser(user: DemoUser) {
    this.session.setUser(user);
    location.reload(); // simplest way to re-fetch everything with the new permissions
  }
}

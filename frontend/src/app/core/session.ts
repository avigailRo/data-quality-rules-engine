import { HttpErrorResponse } from '@angular/common/http';
import { Injectable, computed, signal } from '@angular/core';

export type DemoUser = 'admin' | 'author' | 'viewer';

export const DEMO_USERS: { id: DemoUser; label: string }[] = [
  { id: 'author', label: 'כותב בקרות' },
  { id: 'viewer', label: 'צופה' },
  { id: 'admin', label: 'מנהל מערכת' },
];

function readStoredUser(): DemoUser {
  try {
    const v = localStorage.getItem('dc.user');
    return v === 'admin' || v === 'viewer' || v === 'author' ? v : 'author';
  } catch {
    return 'author';
  }
}

/** Demo session: the selected user is sent as X-Demo-User. Permissions are enforced by the server; the UI only hides actions. */
@Injectable({ providedIn: 'root' })
export class Session {
  readonly user = signal<DemoUser>(readStoredUser());
  readonly canAuthor = computed(() => this.user() !== 'viewer');
  readonly isAdmin = computed(() => this.user() === 'admin');

  setUser(user: DemoUser): void {
    this.user.set(user);
    try { localStorage.setItem('dc.user', user); } catch { /* storage may be unavailable */ }
  }
}

export interface Toast { id: number; kind: 'success' | 'error' | 'info'; text: string; }

@Injectable({ providedIn: 'root' })
export class Notifier {
  private seq = 0;
  readonly toasts = signal<Toast[]>([]);

  success(text: string) { this.push('success', text); }
  info(text: string) { this.push('info', text); }
  error(err: unknown) { this.push('error', errorMessage(err)); }

  dismiss(id: number) { this.toasts.update(list => list.filter(t => t.id !== id)); }

  private push(kind: Toast['kind'], text: string) {
    const id = ++this.seq;
    this.toasts.update(list => [...list, { id, kind, text }]);
    setTimeout(() => this.dismiss(id), kind === 'error' ? 8000 : 4000);
  }
}

/** Turns ProblemDetails (RFC 9457) from the API into a readable Hebrew message. */
export function errorMessage(err: unknown): string {
  if (err instanceof HttpErrorResponse) {
    if (err.status === 0) return 'אין חיבור לשרת. ודאו שה־API פועל.';
    const p = err.error as { title?: string; errors?: { messageHe: string }[] } | null;
    if (p?.errors?.length) return `${p.title ?? 'שגיאה'} ${p.errors.map(e => e.messageHe).join(' · ')}`;
    if (p?.title) return p.title;
    if (err.status === 401 || err.status === 403) return 'אין לך הרשאה לפעולה זו.';
    return `שגיאה (${err.status})`;
  }
  return 'אירעה שגיאה בלתי צפויה.';
}

export function problemCode(err: unknown): string | undefined {
  return err instanceof HttpErrorResponse ? (err.error as { code?: string } | null)?.code : undefined;
}

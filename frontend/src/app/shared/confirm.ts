import { Component, ElementRef, Injectable, effect, inject, signal, viewChild } from '@angular/core';
import { Icon } from './icon';

export interface ConfirmOptions {
  title: string;
  message: string;
  confirmText?: string;
  cancelText?: string;
  tone?: 'primary' | 'danger';
}

interface PendingConfirm extends ConfirmOptions { resolve: (ok: boolean) => void; }

/** Promise-based confirmation for significant actions (archive, approve, reject). */
@Injectable({ providedIn: 'root' })
export class ConfirmService {
  readonly pending = signal<PendingConfirm | null>(null);

  ask(options: ConfirmOptions): Promise<boolean> {
    this.pending()?.resolve(false);
    return new Promise<boolean>(resolve => this.pending.set({ ...options, resolve }));
  }

  close(ok: boolean) {
    const p = this.pending();
    this.pending.set(null);
    p?.resolve(ok);
  }
}

/** Native <dialog>: focus trap, Escape and backdrop handled by the browser (accessible by default). */
@Component({
  selector: 'dc-confirm-host',
  imports: [Icon],
  template: `
    <dialog #dlg class="dialog" aria-labelledby="confirm-title" aria-describedby="confirm-message" (cancel)="onCancel($event)">
      @if (svc.pending(); as p) {
        <div class="dialog-body">
          <span class="dialog-icon" [attr.data-tone]="p.tone ?? 'primary'"><dc-icon [name]="p.tone === 'danger' ? 'alert' : 'info'" [size]="22" /></span>
          <div>
            <h2 id="confirm-title">{{ p.title }}</h2>
            <p id="confirm-message">{{ p.message }}</p>
          </div>
        </div>
        <div class="dialog-actions">
          <button type="button" class="btn" (click)="svc.close(false)">{{ p.cancelText ?? 'ביטול' }}</button>
          <button type="button" class="btn" [class.btn-danger]="p.tone === 'danger'" [class.btn-primary]="p.tone !== 'danger'"
                  (click)="svc.close(true)" autofocus>{{ p.confirmText ?? 'אישור' }}</button>
        </div>
      }
    </dialog>
  `,
})
export class ConfirmHost {
  protected readonly svc = inject(ConfirmService);
  private readonly dialog = viewChild.required<ElementRef<HTMLDialogElement>>('dlg');

  constructor() {
    effect(() => {
      const el = this.dialog().nativeElement;
      if (this.svc.pending() && !el.open) el.showModal();
      if (!this.svc.pending() && el.open) el.close();
    });
  }

  onCancel(event: Event) {
    event.preventDefault();
    this.svc.close(false);
  }
}

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
        <p class="page-sub">הנושאים, השדות והקשרים שאפשר לבנות עליהם בקרות. כל המונחים מוצגים בשפה עסקית.</p>
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
        <div class="kpi"><span class="kpi-label">נושאים</span><span class="kpi-value">{{ store.entities().length }}</span></div>
        <div class="kpi"><span class="kpi-label">שדות</span><span class="kpi-value">{{ fieldCount() }}</span><span class="kpi-hint">{{ computedCount() }} מחושבים אוטומטית</span></div>
        <div class="kpi"><span class="kpi-label">קשרים</span><span class="kpi-value">{{ relationCount() }}</span></div>
      </section>

      <details class="help">
        <summary><dc-icon name="info" [size]="16" /> למנהלי מערכת: איך מוסיפים נושא או שדה חדש?</summary>
        <ol class="help-steps">
          <li><strong>מגדירים Metadata:</strong> שורה ב־<code>dq.Entity</code> לטבלה, שורות ב־<code>dq.Field</code> לשדות (שם עסקי, טיפוס, ערכים מותרים) וב־<code>dq.Relationship</code> לקשרים. דוגמה מלאה: <code>db/06_seed_metadata.sql</code>.</li>
          <li><strong>מעניקים הרשאת קריאה בלבד:</strong> <code>GRANT SELECT</code> על הטבלה החדשה למשתמש ההרצה <code>dc_rule_reader</code>. בלי זה הבקרה לא תוכל לקרוא אותה – זו הגנה מכוונת.</li>
          <li><strong>טוענים ומאמתים:</strong> הכפתור "טעינה מחדש ואימות" (מנהל קטלוג) טוען את הקטלוג בלי הפעלה מחדש, ובודק שכל טבלה ועמודה קיימות ובטיפוס תואם.</li>
        </ol>
        <p class="muted small">מנוע הבקרות, ה־API והממשק לא משתנים: בונה הבקרות, ההסברים בעברית והמלצות ה־AI נבנים מהקטלוג.</p>
      </details>

      <section class="card data-map" aria-labelledby="data-map-title">
        <h2 id="data-map-title" class="map-title"><dc-icon name="link" [size]="16" /> מפת הנתונים העסקית</h2>
        <p class="muted small">כל ריבוע הוא נושא, וכל חץ הוא קשר בין נושאים. למשל, החץ מעובדים למחלקות אומר שכל עובד שייך למחלקה אחת. לחיצה על נושא מציגה את השדות שלו.</p>
        <svg class="map-svg" viewBox="0 0 800 440" role="img" aria-label="מפת הקשרים בין הנושאים העסקיים">
          <defs>
            <marker id="map-arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M0,0 L10,5 L0,10 z" class="map-arrow-head" />
            </marker>
          </defs>
          @for (edge of mapEdges(); track edge.id) {
            <line class="map-edge" [attr.x1]="edge.x1" [attr.y1]="edge.y1" [attr.x2]="edge.x2" [attr.y2]="edge.y2" marker-end="url(#map-arrow)" />
            <text class="map-edge-label" [attr.x]="edge.lx" [attr.y]="edge.ly" text-anchor="middle">{{ edge.label }}</text>
          }
          @for (node of mapNodes(); track node.key) {
            <g class="map-node" tabindex="0" role="button" [attr.aria-label]="'הצגת השדות של ' + node.name"
               (click)="showEntity(node.key)" (keydown.enter)="showEntity(node.key)">
              <rect [attr.x]="node.x - 80" [attr.y]="node.y - 26" width="160" height="52" rx="12" />
              <text [attr.x]="node.x" [attr.y]="node.y - 3" text-anchor="middle" class="map-node-name">{{ node.name }}</text>
              <text [attr.x]="node.x" [attr.y]="node.y + 16" text-anchor="middle" class="map-node-meta">{{ node.fields }} שדות</text>
            </g>
          }
        </svg>
      </section>

      <div class="catalog-grid">
        @for (e of store.entities(); track e.key) {
          <section class="card entity-card" [id]="'entity-' + e.key">
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
                    <span class="muted small">{{ r.cardinality === 'manyToOne' ? 'מצביע על פריט אחד' : 'רשימה של פריטים' }}</span>
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

  /**
   * Entity map, built from the catalog (generic): the most connected subject sits in the centre, the others around it,
   * with subjects that are related to each other placed next to each other so the arrows stay short and do not cross.
   * Arrows show many-to-one relations (the reverse "list" side is implied).
   */
  protected readonly mapNodes = computed(() => {
    const list = this.store.entities();
    if (list.length === 0) return [];
    const neighbours = new Map<string, Set<string>>(list.map(e => [e.key, new Set<string>()]));
    for (const e of list) for (const r of e.relationships) {
      if (r.toEntity === e.key || !neighbours.has(r.toEntity)) continue;
      neighbours.get(e.key)!.add(r.toEntity); neighbours.get(r.toEntity)!.add(e.key);
    }
    const centre = [...list].sort((a, b) => neighbours.get(b.key)!.size - neighbours.get(a.key)!.size)[0];
    const ring: string[] = [];
    const visit = (key: string) => {
      if (key === centre.key || ring.includes(key)) return;
      ring.push(key);
      for (const n of neighbours.get(key)!) visit(n);   // related subjects end up side by side
    };
    for (const e of list) visit(e.key);
    const byKey = new Map(list.map(e => [e.key, e] as const));
    const node = (key: string, x: number, y: number) => {
      const e = byKey.get(key)!;
      return { key, name: e.displayNamePlural, fields: e.fields.length, x: Math.round(x), y: Math.round(y) };
    };
    const n = Math.max(ring.length, 1);
    return [node(centre.key, 400, 220), ...ring.map((key, i) => {
      const angle = -Math.PI / 2 + Math.PI / n + (2 * Math.PI * i) / n;   // start beside the top, not on it
      return node(key, 400 + 290 * Math.cos(angle), 220 + 160 * Math.sin(angle));
    })];
  });

  protected readonly mapEdges = computed(() => {
    const pos = new Map(this.mapNodes().map(nd => [nd.key, nd] as const));
    const byKey = new Map(this.store.entities().map(x => [x.key, x] as const));
    const edges: { id: string; x1: number; y1: number; x2: number; y2: number; lx: number; ly: number; label: string }[] = [];
    for (const e of this.store.entities()) {
      for (const r of e.relationships) {
        const a = pos.get(e.key), b = pos.get(r.toEntity);
        if (!a || !b || a === b || r.cardinality !== 'manyToOne') continue;
        // stop the line at the edge of the target box so the arrow head stays visible
        const dx = b.x - a.x, dy = b.y - a.y;
        const f = Math.min(88 / Math.abs(dx || 1e-6), 34 / Math.abs(dy || 1e-6));   // where the line leaves a box (+ small gap)
        const t = Math.min(1, Math.max(0, 1 - f));
        // two relations between the same pair (one each way) are drawn side by side, not on top of each other
        // perpendicular of the pair's canonical direction (lower key -> higher key), so opposite edges get opposite sides
        const len = Math.hypot(dx, dy) || 1, forward = e.key < r.toEntity;
        const cdx = forward ? dx : -dx, cdy = forward ? dy : -dy, side = forward ? 1 : -1;
        const paired = (byKey.get(r.toEntity)?.relationships ?? []).some(x => x.toEntity === e.key && x.cardinality === 'manyToOne');
        const shift = paired ? 10 : 0;   // only a pair of opposite arrows is drawn side by side
        const ox = (-cdy / len) * shift * side, oy = (cdx / len) * shift * side;
        edges.push({ id: e.key + '.' + r.key,
          x1: Math.round(a.x + dx * (1 - t) + ox), y1: Math.round(a.y + dy * (1 - t) + oy),
          x2: Math.round(a.x + dx * t + ox), y2: Math.round(a.y + dy * t + oy),
          // label at ~40% of the visible segment (away from the arrow head), pushed a little to the side of its own line
          lx: Math.round(a.x + dx * ((1 - t) + (2 * t - 1) * 0.4) + (paired ? ox * 2.4 : (-cdy / len) * 14)),
          ly: Math.round(a.y + dy * ((1 - t) + (2 * t - 1) * 0.4) + (paired ? oy * 2.4 : (cdx / len) * 14) + 4), label: r.displayName });
      }
    }
    return edges;
  });

  showEntity(key: string) {
    document.getElementById('entity-' + key)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

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

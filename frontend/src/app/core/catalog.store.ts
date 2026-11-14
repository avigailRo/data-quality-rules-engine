import { Injectable, computed, inject, signal } from '@angular/core';
import { Api } from './api';
import { DataType, EntityDef, FieldDef, OperatorDef, RelationshipDef, TypeOperators } from './models';

export interface FieldOption { value: string; path: string[]; scope?: 'root'; label: string; field: FieldDef; }
export interface FieldGroup { label: string; options: FieldOption[]; }

/** Catalog + operator matrix, loaded once per session and shared by all screens (signal-based store). */
@Injectable({ providedIn: 'root' })
export class CatalogStore {
  private readonly api = inject(Api);
  readonly entities = signal<EntityDef[]>([]);
  readonly operators = signal<TypeOperators[]>([]);
  readonly loaded = signal(false);
  readonly error = signal<unknown>(null);
  private loading?: Promise<void>;

  readonly entityMap = computed(() => new Map(this.entities().map(e => [e.key, e])));

  load(): Promise<void> {
    this.loading ??= Promise.all([this.api.entities(), this.api.operators()])
      .then(([entities, operators]) => {
        this.entities.set(entities);
        this.operators.set(operators);
        this.loaded.set(true);
        this.error.set(null);
      })
      .catch(err => {
        this.error.set(err);
        this.loading = undefined;
        throw err;
      });
    return this.loading;
  }

  /** Forces a fresh load, e.g. after an admin reloaded the catalog on the server. */
  reload(): Promise<void> {
    this.loading = undefined;
    return this.load();
  }

  entity(key: string | null | undefined): EntityDef | undefined {
    return key ? this.entityMap().get(key) : undefined;
  }

  operatorsFor(type: DataType | undefined): OperatorDef[] {
    return this.operators().find(o => o.dataType === type)?.operators ?? [];
  }

  /** Resolves a field path (relative to an entity) to its field definition. */
  resolve(entityKey: string, path: string[]): FieldDef | undefined {
    let entity = this.entity(entityKey);
    for (const seg of path.slice(0, -1)) {
      const rel = entity?.relationships.find(r => r.key === seg && r.cardinality === 'manyToOne');
      entity = rel ? this.entity(rel.toEntity) : undefined;
    }
    return entity?.fields.find(f => f.key === path[path.length - 1]);
  }

  pathLabel(entityKey: string, path: string[]): string {
    const parts: string[] = [];
    let entity = this.entity(entityKey);
    for (const seg of path.slice(0, -1)) {
      const rel = entity?.relationships.find(r => r.key === seg);
      parts.push(rel?.displayName ?? seg);
      entity = rel ? this.entity(rel.toEntity) : undefined;
    }
    parts.push(entity?.fields.find(f => f.key === path[path.length - 1])?.displayName ?? path[path.length - 1]);
    return parts.join(' › ');
  }

  /** Field picker options in business terms: the entity's own fields + fields of related single records (one level). */
  fieldGroups(entityKey: string, rootEntityKey?: string): FieldGroup[] {
    const entity = this.entity(entityKey);
    if (!entity) return [];
    const groups: FieldGroup[] = [{
      label: `פרטי ה${entity.displayName}`,
      options: entity.fields.map(f => ({ value: f.key, path: [f.key], label: f.displayName, field: f })),
    }];
    for (const rel of entity.relationships.filter(r => r.cardinality === 'manyToOne')) {
      const target = this.entity(rel.toEntity);
      if (!target) continue;
      groups.push({
        label: rel.displayName,
        options: target.fields.map(f => ({ value: `${rel.key}.${f.key}`, path: [rel.key, f.key], label: `${rel.displayName} › ${f.displayName}`, field: f })),
      });
    }
    if (rootEntityKey && rootEntityKey !== entityKey) {
      const root = this.entity(rootEntityKey);
      if (root) {
        groups.push({
          label: `ה${root.displayName} (הרשומה הראשית)`,
          options: root.fields.map(f => ({ value: `root:${f.key}`, path: [f.key], scope: 'root' as const, label: `ה${root.displayName} › ${f.displayName}`, field: f })),
        });
      }
    }
    return groups;
  }

  collections(entityKey: string): RelationshipDef[] {
    return this.entity(entityKey)?.relationships.filter(r => r.cardinality === 'oneToMany') ?? [];
  }
}

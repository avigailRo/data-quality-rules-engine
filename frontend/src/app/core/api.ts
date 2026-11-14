import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import {
  AiStatus, CatalogIssue, EntityDef, GenerateResult, Paged, PreviewResult, Rule, RuleDefinition, Run, SaveRule,
  Suggestion, TypeOperators, ValidationResult, ViolationPage,
} from './models';

function params(obj: Record<string, string | number | null | undefined>): HttpParams {
  let p = new HttpParams();
  for (const [k, v] of Object.entries(obj)) if (v !== null && v !== undefined && v !== '') p = p.set(k, String(v));
  return p;
}

/** Typed REST client for /api/v1. */
@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);
  private readonly base = '/api/v1';

  // catalog
  entities() { return firstValueFrom(this.http.get<EntityDef[]>(`${this.base}/catalog/entities`)); }
  operators() { return firstValueFrom(this.http.get<TypeOperators[]>(`${this.base}/catalog/operators`)); }
  verifyCatalog() { return firstValueFrom(this.http.post<{ valid: boolean; issues: CatalogIssue[] }>(`${this.base}/admin/catalog/verify`, {})); }

  // rules
  rules(q: { search?: string; status?: string; entity?: string; page: number; pageSize: number }) {
    return firstValueFrom(this.http.get<Paged<Rule>>(`${this.base}/rules`, { params: params(q) }));
  }
  rule(id: string) { return firstValueFrom(this.http.get<Rule>(`${this.base}/rules/${id}`)); }
  createRule(body: SaveRule) { return firstValueFrom(this.http.post<Rule>(`${this.base}/rules`, body)); }
  updateRule(id: string, version: number, body: SaveRule) {
    return firstValueFrom(this.http.put<Rule>(`${this.base}/rules/${id}`, body, { headers: new HttpHeaders({ 'If-Match': `"${version}"` }) }));
  }
  duplicateRule(id: string) { return firstValueFrom(this.http.post<Rule>(`${this.base}/rules/${id}/duplicate`, {})); }
  archiveRule(id: string) { return firstValueFrom(this.http.post<void>(`${this.base}/rules/${id}/archive`, {})); }
  validate(definition: RuleDefinition) { return firstValueFrom(this.http.post<ValidationResult>(`${this.base}/rules/validate`, { definition })); }
  preview(definition: RuleDefinition) { return firstValueFrom(this.http.post<PreviewResult>(`${this.base}/rules/preview`, { definition })); }
  ruleSql(id: string) { return firstValueFrom(this.http.get<{ sql: string; parameters: string[] }>(`${this.base}/rules/${id}/sql`)); }

  // runs
  startRun(ruleId: string) { return firstValueFrom(this.http.post<Run>(`${this.base}/rules/${ruleId}/runs`, {})); }
  runHistory(ruleId: string) { return firstValueFrom(this.http.get<Run[]>(`${this.base}/rules/${ruleId}/runs`)); }
  run(runId: string) { return firstValueFrom(this.http.get<Run>(`${this.base}/runs/${runId}`)); }
  violations(runId: string, q: { search?: string; conditionId?: string; page: number; pageSize: number }) {
    return firstValueFrom(this.http.get<ViolationPage>(`${this.base}/runs/${runId}/violations`, { params: params(q) }));
  }

  // AI
  aiStatus() { return firstValueFrom(this.http.get<AiStatus>(`${this.base}/ai/status`)); }
  generateSuggestions(maxSuggestions: number) {
    return firstValueFrom(this.http.post<GenerateResult>(`${this.base}/ai/suggestions/generate`, { maxSuggestions }));
  }
  suggestions(status?: string) { return firstValueFrom(this.http.get<Suggestion[]>(`${this.base}/ai/suggestions`, { params: params({ status }) })); }
  acceptSuggestion(id: string) { return firstValueFrom(this.http.post<Rule>(`${this.base}/ai/suggestions/${id}/accept`, {})); }
  rejectSuggestion(id: string) { return firstValueFrom(this.http.post<void>(`${this.base}/ai/suggestions/${id}/reject`, {})); }
}

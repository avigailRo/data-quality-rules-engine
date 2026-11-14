import { Routes } from '@angular/router';

export const routes: Routes = [
  { path: '', pathMatch: 'full', redirectTo: 'dashboard' },
  { path: 'dashboard', title: 'סקירה כללית', loadComponent: () => import('./features/dashboard/dashboard.page').then(m => m.DashboardPage) },
  { path: 'rules', title: 'בקרות', loadComponent: () => import('./features/rules/rule-list.page').then(m => m.RuleListPage) },
  { path: 'rules/new', title: 'בקרה חדשה', loadComponent: () => import('./features/rules/rule-editor.page').then(m => m.RuleEditorPage) },
  { path: 'rules/:id', title: 'עריכת בקרה', loadComponent: () => import('./features/rules/rule-editor.page').then(m => m.RuleEditorPage) },
  { path: 'runs/:runId', title: 'תוצאות הרצה', loadComponent: () => import('./features/runs/run-results.page').then(m => m.RunResultsPage) },
  { path: 'suggestions', title: 'המלצות AI', loadComponent: () => import('./features/suggestions/suggestions.page').then(m => m.SuggestionsPage) },
  { path: 'catalog', title: 'קטלוג נתונים', loadComponent: () => import('./features/catalog/catalog.page').then(m => m.CatalogPage) },
  { path: '**', redirectTo: 'dashboard' },
];

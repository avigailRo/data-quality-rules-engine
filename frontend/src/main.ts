import { registerLocaleData } from '@angular/common';
import localeHe from '@angular/common/locales/he';
import { bootstrapApplication } from '@angular/platform-browser';
import { App } from './app/app';
import { appConfig } from './app/app.config';

registerLocaleData(localeHe);

bootstrapApplication(App, appConfig).catch(err => console.error(err));

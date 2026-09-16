import { platformBrowser } from '@angular/platform-browser';
import { AppModule } from './app/app.module';

// Classic NgModule bootstrap - no bootstrapApplication, no app.config.ts.
platformBrowser().bootstrapModule(AppModule).catch((err) => console.error(err));

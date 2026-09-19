import {
  APP_INITIALIZER,
  EnvironmentProviders,
  ErrorHandler,
  Provider,
  inject,
  makeEnvironmentProviders,
} from '@angular/core';
import { ERP_ERROR_CONFIG, ERP_ERROR_DEFAULT_CONFIG, ErpErrorConfig } from './config/erp-error-config';
import { ErpGlobalErrorHandler } from './capture/erp-global-error-handler';
import { ErpErrorReporterService } from './capture/erp-error-reporter.service';
import { ErpErrorContextService } from './core/erp-error-context.service';

/**
 * THE integration surface for the Angular side of the ERP.
 *
 * Everything the brief asks for on the front end is switched on by adding this
 * one call to app.config.ts, plus the interceptor in the existing
 * provideHttpClient(...) call:
 *
 *   export const appConfig: ApplicationConfig = {
 *     providers: [
 *       provideRouter(routes),
 *       provideHttpClient(withInterceptors([erpHttpErrorInterceptor])),
 *       provideErpErrorManagement({
 *         apiBaseUrl: '/api/error-management',
 *         environment: 'Production',
 *         appVersion: '2026.3.1',
 *         // The ERP's existing global service - no new identity, no mapping.
 *         userProvider: () => ({
 *           profileId: generic_service.GetUserProfileKey(),
 *           name: generic_service.GetUserName(),
 *         }),
 *       }),
 *     ],
 *   };
 *
 * No existing component, service, form, LOV or module is edited.
 *
 * For an NgModule application the same providers go in AppModule's `providers`
 * array - makeEnvironmentProviders is accepted there too.
 */
export function provideErpErrorManagement(
  config: Partial<ErpErrorConfig> & Pick<ErpErrorConfig, 'apiBaseUrl' | 'environment'>,
): EnvironmentProviders {
  const merged: ErpErrorConfig = {
    ...ERP_ERROR_DEFAULT_CONFIG,
    ...config,
    // Merge rather than replace the safety lists: a host that passes its own
    // allow-list almost never means "and drop the framework's own endpoint
    // exclusions", and silently losing those causes an infinite capture loop.
    ignoreUrlPatterns: [
      ...ERP_ERROR_DEFAULT_CONFIG.ignoreUrlPatterns,
      ...(config.ignoreUrlPatterns ?? []),
    ],
    ignoreMessagePatterns: [
      ...ERP_ERROR_DEFAULT_CONFIG.ignoreMessagePatterns,
      ...(config.ignoreMessagePatterns ?? []),
    ],
    headerAllowList: [
      ...new Set([
        ...ERP_ERROR_DEFAULT_CONFIG.headerAllowList,
        ...(config.headerAllowList ?? []),
      ]),
    ],
    payloadKeyAllowList: [
      ...new Set([
        ...ERP_ERROR_DEFAULT_CONFIG.payloadKeyAllowList,
        ...(config.payloadKeyAllowList ?? []),
      ]),
    ],
  };

  const providers: Provider[] = [
    { provide: ERP_ERROR_CONFIG, useValue: merged },
    { provide: ErrorHandler, useClass: ErpGlobalErrorHandler },
    {
      provide: APP_INITIALIZER,
      multi: true,
      useFactory: () => {
        // Instantiating these at bootstrap (rather than on first error) means
        // the window-level listeners below and the persisted-queue replay are
        // live before any application code runs.
        const reporter = inject(ErpErrorReporterService);
        const context = inject(ErpErrorContextService);
        return () => installWindowHandlers(reporter, context);
      },
    },
  ];

  return makeEnvironmentProviders(providers);
}

/**
 * Angular's ErrorHandler does not see everything.
 *
 *  - `window.onerror` catches errors thrown from code outside the zone:
 *    third-party widgets, legacy jQuery still embedded in an ERP page, script
 *    tags, and anything inside a `runOutsideAngular` block.
 *  - `unhandledrejection` catches a promise nobody awaited - the single most
 *    common way an async save silently does nothing in an Angular app.
 *
 * Both are added passively; neither calls preventDefault, so the browser's own
 * console output and any existing handler the ERP already installed both still
 * run.
 */
function installWindowHandlers(reporter: ErpErrorReporterService, context: ErpErrorContextService): void {
  if (typeof window === 'undefined') return;

  window.addEventListener('error', (event: ErrorEvent) => {
    try {
      // Resource load failures (img/script/link) surface here too, with no
      // `error` object.  They are not application faults - skip them.
      if (!event.error && !event.message) return;
      void reporter.report(event.error ?? new Error(event.message), {
        component: null,
        customData: { source: 'window.onerror', filename: stripOrigin(event.filename) },
      });
    } catch {
      /* passive listener */
    }
  });

  window.addEventListener('unhandledrejection', (event: PromiseRejectionEvent) => {
    try {
      void reporter.report(event.reason ?? new Error('Unhandled promise rejection'), {
        customData: { source: 'unhandledrejection' },
      });
    } catch {
      /* passive listener */
    }
  });

  // Click breadcrumbs: which button, not what was typed.
  window.addEventListener(
    'click',
    (event: MouseEvent) => {
      try {
        const el = event.target as HTMLElement | null;
        if (!el) return;
        const actionable = el.closest('button,[role="button"],a[href],input[type="submit"]');
        if (!actionable) return;
        const label =
          actionable.getAttribute('data-erp-action') ??
          actionable.getAttribute('aria-label') ??
          actionable.getAttribute('id') ??
          (actionable.textContent ?? '').trim().slice(0, 60);
        if (label) context.addBreadcrumb({ kind: 'click', message: label });
      } catch {
        /* passive listener */
      }
    },
    { capture: true, passive: true },
  );
}

function stripOrigin(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).pathname;
  } catch {
    return url;
  }
}

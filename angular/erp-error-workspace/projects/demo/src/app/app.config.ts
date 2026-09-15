import { ApplicationConfig, provideBrowserGlobalErrorListeners, provideZoneChangeDetection } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient, withInterceptors } from '@angular/common/http';

import { erpHttpErrorInterceptor, provideErpErrorManagement } from 'erp-error-management';

import { routes } from './app.routes';

/**
 * THIS IS THE ENTIRE FRONT-END INTEGRATION.
 *
 * Two additions to a file the ERP already has:
 *   1. erpHttpErrorInterceptor in the existing provideHttpClient(...) call
 *   2. provideErpErrorManagement({...})
 *
 * Every component, service, form, LOV and route in the demo below is written
 * as if the framework did not exist.  None of them import it, none of them
 * catch anything, and all of their failures are still captured, fingerprinted,
 * shown to the user with a reference number, and turned into a ticket on
 * request.
 */
export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZoneChangeDetection({ eventCoalescing: true }),
    provideRouter(routes),

    provideHttpClient(withInterceptors([erpHttpErrorInterceptor])),

    provideErpErrorManagement({
      apiBaseUrl: '/api/error-management',
      environment: 'Demo',
      appVersion: '2026.3.1',
      defaultErpModule: 'CORE',
      logToConsole: true,
      // In the real ERP this reads from the existing auth service.
      userProvider: () => ({
        id: 'U-10427',
        name: 'fatima.saeed',
        displayName: 'Fatima Saeed',
        tenantId: 'GROUP-01',
      }),
    }),
  ],
};

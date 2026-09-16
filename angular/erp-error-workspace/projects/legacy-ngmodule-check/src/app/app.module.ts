import { NgModule, ErrorHandler } from '@angular/core';
import { BrowserModule } from '@angular/platform-browser';
import { HttpClientModule, HTTP_INTERCEPTORS, HttpClient, HttpErrorResponse,
         HttpEvent, HttpHandler, HttpInterceptor, HttpRequest } from '@angular/common/http';
import { Component, Injectable, inject } from '@angular/core';
import { Observable, throwError } from 'rxjs';
import { catchError } from 'rxjs/operators';

import {
  provideErpErrorManagement,
  ErpErrorReporterService,
  ErpErrorNotificationService,
  ErpFormErrorService,
  ErpGlobalErrorHandler,
} from 'erp-error-management';

/**
 * PROOF that the library works in a LEGACY NgModule application, not only in a
 * standalone/app.config.ts one.
 *
 * Two things are being proved here:
 *  1. `provideErpErrorManagement(...)` returns EnvironmentProviders, which
 *     NgModule.providers accepts (Angular 15+). No separate NgModule wrapper
 *     is needed.
 *  2. The class-based interceptor path works for apps still on
 *     HttpClientModule + HTTP_INTERCEPTORS, which cannot use
 *     withInterceptors([...]).
 */

/**
 * Class-based equivalent of erpHttpErrorInterceptor, for NgModule apps that
 * register interceptors through HTTP_INTERCEPTORS rather than
 * provideHttpClient(withInterceptors(...)).
 */
@Injectable()
export class ErpLegacyHttpErrorInterceptor implements HttpInterceptor {
  private readonly reporter = inject(ErpErrorReporterService);
  private readonly notifier = inject(ErpErrorNotificationService);

  intercept(req: HttpRequest<unknown>, next: HttpHandler): Observable<HttpEvent<unknown>> {
    return next.handle(req).pipe(
      catchError((error: unknown) => {
        if (error instanceof HttpErrorResponse && !this.reporter.shouldIgnore(error, req.url)) {
          void this.reporter.report(error, { httpError: error }).then((r) => {
            if (r?.shouldNotifyUser) this.notifier.show(r);
          });
        }
        return throwError(() => error);
      }),
    );
  }
}

@Component({
  selector: 'legacy-root',
  standalone: false,
  template: `<h1>Legacy NgModule host</h1><button (click)="boom()">boom</button>`,
})
export class LegacyAppComponent {
  private readonly http = inject(HttpClient);
  private readonly formErrors = inject(ErpFormErrorService);

  boom(): void {
    const x = undefined as unknown as { y: number };
    console.log(x.y);
  }
}

@NgModule({
  declarations: [LegacyAppComponent],
  imports: [BrowserModule, HttpClientModule],
  providers: [
    // EnvironmentProviders in an NgModule providers array - this is the thing
    // being proved.
    provideErpErrorManagement({
      apiBaseUrl: '/api/error-management',
      environment: 'Production',
      appVersion: '2026.3.1',
    }),
    { provide: HTTP_INTERCEPTORS, useClass: ErpLegacyHttpErrorInterceptor, multi: true },
  ],
  bootstrap: [LegacyAppComponent],
})
export class AppModule {}

// Referenced so the compiler checks the exported symbols resolve.
export const _typeChecks: [typeof ErrorHandler, typeof ErpGlobalErrorHandler] =
  [ErrorHandler, ErpGlobalErrorHandler];

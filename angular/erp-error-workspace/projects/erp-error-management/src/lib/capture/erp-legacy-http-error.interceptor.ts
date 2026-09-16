import {
  HttpErrorResponse,
  HttpEvent,
  HttpHandler,
  HttpInterceptor,
  HttpRequest,
  HttpResponse,
} from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable, throwError } from 'rxjs';
import { catchError, tap } from 'rxjs/operators';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import { ErpErrorContextService } from '../core/erp-error-context.service';
import { redactHeaders, redactObject, redactQueryString, safeEndpoint } from '../core/redaction';
import { ErpErrorReporterService } from './erp-error-reporter.service';
import { ErpErrorNotificationService } from '../ui/erp-error-notification.service';
import { ERP_ERROR_INTERNAL_REQUEST } from '../transport/erp-error-transport.service';

/**
 * Class-based equivalent of `erpHttpErrorInterceptor`, for the LEGACY half of
 * the ERP.
 *
 * An application still on `HttpClientModule` registers interceptors through
 * the `HTTP_INTERCEPTORS` multi-provider and cannot use
 * `provideHttpClient(withInterceptors([...]))`. Rather than force those modules
 * to migrate first - which would be exactly the kind of restructuring the brief
 * rules out - the framework ships both forms. They are behaviourally identical
 * and share every helper, so there is no second implementation to keep in step.
 *
 * Registration in an NgModule:
 *
 *     providers: [
 *       provideErpErrorManagement({ ... }),
 *       { provide: HTTP_INTERCEPTORS, useClass: ErpLegacyHttpErrorInterceptor, multi: true },
 *     ]
 *
 * Both forms may coexist in one application while modules are migrated: a
 * request passes through exactly one HttpClient instance, so it is observed
 * once, not twice.
 */
@Injectable()
export class ErpLegacyHttpErrorInterceptor implements HttpInterceptor {
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly context = inject(ErpErrorContextService);
  private readonly reporter = inject(ErpErrorReporterService);
  private readonly notifier = inject(ErpErrorNotificationService);

  intercept(req: HttpRequest<unknown>, next: HttpHandler): Observable<HttpEvent<unknown>> {
    // Requests made BY the framework are never observed by it.
    if (req.context.get(ERP_ERROR_INTERNAL_REQUEST)) {
      return next.handle(req);
    }

    const requestId = this.context.newRequestId();
    const correlationId = this.context.getCorrelationId();
    const startedAt = Date.now();

    const stamped = req.clone({
      setHeaders: {
        'X-Correlation-Id': correlationId,
        'X-Request-Id': requestId,
        ...(this.context.getModule() ? { 'X-Erp-Module': this.context.getModule()! } : {}),
        ...(this.context.getScreen() ? { 'X-Erp-Screen': this.context.getScreen()! } : {}),
        ...(this.config.appVersion ? { 'X-App-Version': this.config.appVersion } : {}),
      },
    });

    return next.handle(stamped).pipe(
      tap((event) => {
        if (event instanceof HttpResponse) {
          this.context.addBreadcrumb({
            kind: 'http',
            message: `${req.method} ${safeEndpoint(req.urlWithParams)} -> ${event.status}`,
            data: { durationMs: Date.now() - startedAt },
          });
        }
      }),
      catchError((error: unknown) => {
        try {
          if (error instanceof HttpErrorResponse && !this.reporter.shouldIgnore(error, req.url)) {
            const durationMs = Date.now() - startedAt;

            this.context.addBreadcrumb({
              kind: 'http',
              message: `${req.method} ${safeEndpoint(req.urlWithParams)} -> ${error.status}`,
              data: { durationMs },
            });

            const allowedHeaders = this.reporter.headerAllowList();
            const allowedKeys = new Set(this.config.payloadKeyAllowList.map((k) => k.toLowerCase()));

            const headers: Record<string, string | null> = {};
            for (const name of req.headers.keys()) {
              headers[name] = req.headers.get(name);
            }

            void this.reporter
              .report(error, {
                httpError: error,
                durationMs,
                requestPayload: {
                  url: safeEndpoint(req.urlWithParams),
                  method: req.method,
                  headers: redactHeaders(headers, allowedHeaders),
                  query: redactQueryString(req.urlWithParams, allowedKeys),
                  body: this.config.captureRequestBody
                    ? redactObject(req.body, allowedKeys)
                    : undefined,
                },
                responsePayload: this.config.captureResponseBody
                  ? redactObject(error.error, allowedKeys)
                  : undefined,
              })
              .then((result) => {
                if (result?.shouldNotifyUser) this.notifier.show(result);
              });
          }
        } catch {
          /* capture must never change what the caller receives */
        }

        return throwError(() => error);
      }),
    );
  }
}

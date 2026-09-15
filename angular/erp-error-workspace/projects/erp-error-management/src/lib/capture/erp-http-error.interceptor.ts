import {
  HttpErrorResponse,
  HttpEvent,
  HttpHandlerFn,
  HttpInterceptorFn,
  HttpRequest,
  HttpResponse,
} from '@angular/common/http';
import { inject } from '@angular/core';
import { Observable, throwError } from 'rxjs';
import { catchError, tap } from 'rxjs/operators';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import { ErpErrorContextService } from '../core/erp-error-context.service';
import { redactHeaders, redactObject, redactQueryString, safeEndpoint } from '../core/redaction';
import { ErpErrorReporterService } from './erp-error-reporter.service';
import { ErpErrorNotificationService } from '../ui/erp-error-notification.service';
import { ERP_ERROR_INTERNAL_REQUEST } from '../transport/erp-error-transport.service';

/**
 * Captures every failed HTTP call in the application, and stamps the
 * correlation headers that let the API-side and SQL-side records be joined back
 * to this one.
 *
 * Registering this once in `provideHttpClient(withInterceptors([...]))` covers
 * every service in every module.  No page changes.
 *
 * Note it RE-THROWS.  The framework observes; it does not change the
 * application's control flow.  A component that already handles a 404 keeps
 * handling it exactly as before.
 */
export const erpHttpErrorInterceptor: HttpInterceptorFn = (
  req: HttpRequest<unknown>,
  next: HttpHandlerFn,
): Observable<HttpEvent<unknown>> => {
  const config = inject(ERP_ERROR_CONFIG);
  const context = inject(ErpErrorContextService);
  const reporter = inject(ErpErrorReporterService);
  const notifier = inject(ErpErrorNotificationService);

  // Requests made BY the framework are never observed by it.
  if (req.context.get(ERP_ERROR_INTERNAL_REQUEST)) {
    return next(req);
  }

  const requestId = context.newRequestId();
  const correlationId = context.getCorrelationId();
  const startedAt = Date.now();

  // These four headers are the entire contract with the back end.  The Web API
  // message handler reads them and puts them into the .NET side's ambient
  // context, which is how an exception 3 layers deep still knows which screen
  // the user was on.
  const stamped = req.clone({
    setHeaders: {
      'X-Correlation-Id': correlationId,
      'X-Request-Id': requestId,
      ...(context.getModule() ? { 'X-Erp-Module': context.getModule()! } : {}),
      ...(context.getScreen() ? { 'X-Erp-Screen': context.getScreen()! } : {}),
      ...(config.appVersion ? { 'X-App-Version': config.appVersion } : {}),
    },
  });

  return next(stamped).pipe(
    tap((event) => {
      if (event instanceof HttpResponse) {
        context.addBreadcrumb({
          kind: 'http',
          message: `${req.method} ${safeEndpoint(req.urlWithParams)} -> ${event.status}`,
          data: { durationMs: Date.now() - startedAt },
        });
      }
    }),
    catchError((error: unknown) => {
      try {
        if (error instanceof HttpErrorResponse && !reporter.shouldIgnore(error, req.url)) {
          const durationMs = Date.now() - startedAt;

          context.addBreadcrumb({
            kind: 'http',
            message: `${req.method} ${safeEndpoint(req.urlWithParams)} -> ${error.status}`,
            data: { durationMs },
          });

          const allowedHeaders = reporter.headerAllowList();
          const allowedKeys = new Set(config.payloadKeyAllowList.map((k) => k.toLowerCase()));

          const headers: Record<string, string | null> = {};
          for (const name of req.headers.keys()) {
            headers[name] = req.headers.get(name);
          }

          void reporter
            .report(error, {
              httpError: error,
              durationMs,
              requestPayload: {
                url: safeEndpoint(req.urlWithParams),
                method: req.method,
                headers: redactHeaders(headers, allowedHeaders),
                query: redactQueryString(req.urlWithParams, allowedKeys),
                body: config.captureRequestBody ? redactObject(req.body, allowedKeys) : undefined,
              },
              responsePayload: config.captureResponseBody
                ? redactObject(error.error, allowedKeys)
                : undefined,
            })
            .then((result) => {
              // The API's own capture already wrote the .NET/SQL rows for this
              // correlation id.  Notifying here, from the layer the user can
              // actually see, keeps exactly one dialog per failed action.
              if (result?.shouldNotifyUser) notifier.show(result);
            });
        }
      } catch {
        /* capture must never change what the caller receives */
      }

      return throwError(() => error);
    }),
  );
};

import { ErrorHandler, Injectable, NgZone, inject } from '@angular/core';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import { ErpErrorReporterService } from './erp-error-reporter.service';
import { ErpErrorNotificationService } from '../ui/erp-error-notification.service';

/**
 * Replaces Angular's default ErrorHandler.
 *
 * This is the "capture without requiring developers to implement error handling
 * on every page" half of the brief for the front end: registering this once in
 * the application providers means every uncaught exception in every component,
 * template, pipe, guard, resolver, effect and rxjs subscription in the entire
 * ERP is captured - with no change to any of them.
 *
 * Deliberately still calls through to console.error.  Swallowing the console
 * output would make the framework itself the reason a developer cannot debug
 * locally, which is a good way to get it removed from the project.
 */
@Injectable()
export class ErpGlobalErrorHandler implements ErrorHandler {
  private readonly reporter = inject(ErpErrorReporterService);
  private readonly notifier = inject(ErpErrorNotificationService);
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly zone = inject(NgZone);

  handleError(error: unknown): void {
    // 1. Never interfere with the developer's console.
    try {
      // eslint-disable-next-line no-console
      console.error(error);
    } catch {
      /* console may be unavailable in some embedded hosts */
    }

    // 2. Capture and notify, entirely defensively.  An exception raised in here
    //    would be handled by... this handler.  Hence the try/catch and the
    //    re-entrancy guard inside the reporter.
    try {
      const envelopePromise = this.reporter.report(error, {
        component: this.componentNameFrom(error),
      });

      void envelopePromise.then((result) => {
        if (!result) {
          // The capture endpoint did not answer.  The user still deserves to be
          // told something went wrong - just without a reference number.
          this.notifier.show({
            errorReference: null,
            occurrenceId: null,
            fingerprintId: null,
            shouldNotifyUser: true,
            autoTicketNumber: null,
            isKnownIssue: false,
          });
          return;
        }
        if (result.shouldNotifyUser) {
          this.notifier.show(result);
        }
      });
    } catch {
      /* capture is best-effort by design */
    }
  }

  /**
   * Angular does not hand the ErrorHandler the component that threw.  The
   * closest reliable signal is the top application frame in the stack, which
   * after minification is the component's class name if `namedChunks` and
   * source maps are on - and is at least a stable token either way.
   */
  private componentNameFrom(error: unknown): string | null {
    try {
      const stack = (error as { stack?: string } | null)?.stack;
      if (!stack) return null;
      for (const line of stack.split('\n').slice(1, 12)) {
        const m = /at\s+(?:new\s+)?([A-Z][A-Za-z0-9_$]*(?:Component|Directive|Service|Effects|Resolver|Guard))[.\s]/.exec(
          line,
        );
        if (m) return m[1];
      }
      return null;
    } catch {
      return null;
    }
  }
}

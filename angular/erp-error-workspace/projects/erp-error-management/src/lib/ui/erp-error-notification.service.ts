import {
  ApplicationRef,
  ComponentRef,
  EnvironmentInjector,
  Injectable,
  NgZone,
  createComponent,
  inject,
} from '@angular/core';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import { ErpErrorCaptureResult } from '../models/error-envelope';
import { ErpErrorTransportService } from '../transport/erp-error-transport.service';
import { ErpErrorDialogComponent } from './erp-error-dialog.component';

/**
 * Owns the single user-facing dialog.
 *
 * Two behaviours here matter more than they look:
 *
 * 1. ONE dialog at a time.  A failing dashboard can raise eight errors in the
 *    same tick; eight stacked modals is worse than the original fault.  A
 *    second error while a dialog is open is captured silently.
 *
 * 2. Repeat suppression per fingerprint.  A polling grid that fails every 5
 *    seconds must not re-prompt every 5 seconds.  The same problem gets one
 *    dialog per suppression window, while every occurrence is still recorded.
 */
@Injectable({ providedIn: 'root' })
export class ErpErrorNotificationService {
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly appRef = inject(ApplicationRef);
  private readonly injector = inject(EnvironmentInjector);
  private readonly transport = inject(ErpErrorTransportService);
  private readonly zone = inject(NgZone);

  private current: ComponentRef<ErpErrorDialogComponent> | null = null;
  private readonly lastShownByFingerprint = new Map<number, number>();

  show(result: ErpErrorCaptureResult): void {
    try {
      if (this.config.notificationMode === 'silent') return;
      if (this.current) return;

      if (result.fingerprintId !== null && result.fingerprintId !== undefined) {
        const last = this.lastShownByFingerprint.get(result.fingerprintId) ?? 0;
        const now = Date.now();
        if (now - last < this.config.duplicateDialogSuppressionMs) return;
        this.lastShownByFingerprint.set(result.fingerprintId, now);
        this.pruneSuppressionMap(now);
      }

      // Component creation and DOM attachment must run inside the zone or the
      // dialog renders once and never updates.
      this.zone.run(() => this.attach(result));
    } catch {
      /* a failure to show the dialog must not become a second error */
    }
  }

  dismiss(): void {
    try {
      if (!this.current) return;
      this.appRef.detachView(this.current.hostView);
      this.current.destroy();
      this.current.location.nativeElement.remove?.();
    } catch {
      /* already gone */
    } finally {
      this.current = null;
    }
  }

  private attach(result: ErpErrorCaptureResult): void {
    const host = document.createElement('div');
    host.setAttribute('data-erp-error-host', '');
    document.body.appendChild(host);

    const ref = createComponent(ErpErrorDialogComponent, {
      environmentInjector: this.injector,
      hostElement: host,
    });

    ref.setInput('result', result);
    ref.setInput('allowDescription', true);

    const sub1 = ref.instance.close.subscribe(() => this.dismiss());
    const sub2 = ref.instance.submitIssue.subscribe((description: string | null) => {
      if (!result.errorReference) {
        ref.instance.setTicketResult(null, false);
        return;
      }
      this.transport.createTicket(result.errorReference, description).subscribe((created) => {
        // createTicket never errors - it maps failure to null - so the dialog
        // always gets an answer and never hangs on "Reporting...".
        ref.instance.setTicketResult(created?.ticketNumber ?? null, created?.wasDeduplicated ?? false);
      });
    });

    ref.onDestroy(() => {
      sub1.unsubscribe();
      sub2.unsubscribe();
      host.remove();
    });

    this.appRef.attachView(ref.hostView);
    ref.changeDetectorRef.detectChanges();
    this.current = ref;
  }

  /** Keep the suppression map from growing without bound in a long session. */
  private pruneSuppressionMap(now: number): void {
    if (this.lastShownByFingerprint.size < 200) return;
    const cutoff = now - this.config.duplicateDialogSuppressionMs * 4;
    for (const [k, v] of this.lastShownByFingerprint) {
      if (v < cutoff) this.lastShownByFingerprint.delete(k);
    }
  }
}

import { CommonModule } from '@angular/common';
import { ChangeDetectionStrategy, ChangeDetectorRef, Component, EventEmitter, Input, Output, inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ErpErrorCaptureResult } from '../models/error-envelope';

export type ErpErrorDialogState = 'prompt' | 'submitting' | 'submitted' | 'failed';

/**
 * The user-facing dialog.
 *
 * Constraints taken straight from the brief:
 *  - Professional, plain-language message.
 *  - NOT ONE technical detail: no stack trace, no SQL text, no server name, no
 *    exception type.  The only technical token shown is the reference number,
 *    which is meaningless outside the error store and is exactly what support
 *    needs the user to quote.
 *  - A Submit / Report option that raises the ticket and shows its number
 *    immediately.
 *
 * Zero third-party dependencies - no Angular Material, no CDK, no Bootstrap.
 * An ERP that already has a design system can replace this component wholesale
 * (see provideErpErrorManagement({ dialogComponent })) without touching
 * anything else in the framework.
 */
@Component({
  selector: 'erperr-error-dialog',
  standalone: true,
  imports: [CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="erperr-backdrop" role="presentation" (click)="onBackdrop($event)">
      <div
        class="erperr-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="erperr-title"
        aria-describedby="erperr-body"
        (click)="$event.stopPropagation()"
      >
        <div class="erperr-head">
          <span class="erperr-icon" aria-hidden="true">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
                 stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="10"></circle>
              <line x1="12" y1="8" x2="12" y2="13"></line>
              <line x1="12" y1="16.5" x2="12.01" y2="16.5"></line>
            </svg>
          </span>
          <h2 id="erperr-title">{{ title }}</h2>
        </div>

        <div id="erperr-body" class="erperr-body">
          @switch (state) {
            @case ('submitted') {
              <p class="erperr-lead">
                Thank you. Your issue has been logged with our support team.
              </p>
              <dl class="erperr-refs">
                <div>
                  <dt>Ticket number</dt>
                  <dd><code>{{ ticketNumber }}</code></dd>
                </div>
                @if (result?.errorReference) {
                  <div>
                    <dt>Error reference</dt>
                    <dd><code>{{ result!.errorReference }}</code></dd>
                  </div>
                }
              </dl>
              @if (wasDeduplicated) {
                <p class="erperr-note">
                  This matches an issue we are already working on, so your report has been
                  added to the existing ticket. You will be notified as it progresses.
                </p>
              } @else {
                <p class="erperr-note">
                  You can track the status of this ticket at any time from
                  <strong>Help &rsaquo; My Issues</strong>.
                </p>
              }
            }

            @case ('failed') {
              <p class="erperr-lead">
                We could not create a support ticket just now.
              </p>
              <p class="erperr-note">
                Your error has still been recorded. Please quote the reference below if you
                contact support.
              </p>
              @if (result?.errorReference) {
                <dl class="erperr-refs">
                  <div>
                    <dt>Error reference</dt>
                    <dd><code>{{ result!.errorReference }}</code></dd>
                  </div>
                </dl>
              }
            }

            @default {
              <p class="erperr-lead">
                We encountered an unexpected problem while processing your request.
              </p>

              @if (result?.isKnownIssue) {
                <p class="erperr-note erperr-known">
                  Our team is already aware of this issue and is working on it.
                </p>
              }

              @if (result?.errorReference) {
                <p class="erperr-note">
                  Your issue has been recorded and can be tracked using the reference below.
                </p>
                <dl class="erperr-refs">
                  <div>
                    <dt>Error reference</dt>
                    <dd><code>{{ result!.errorReference }}</code></dd>
                  </div>
                </dl>
              } @else {
                <p class="erperr-note">
                  Please try again. If the problem continues, report it to your support team.
                </p>
              }

              @if (allowDescription && result?.errorReference) {
                <label class="erperr-label" for="erperr-desc">
                  What were you doing when this happened? <span>(optional)</span>
                </label>
                <textarea
                  id="erperr-desc"
                  class="erperr-textarea"
                  rows="3"
                  maxlength="2000"
                  [(ngModel)]="description"
                  placeholder="e.g. I clicked Save on a new purchase order"
                ></textarea>
              }
            }
          }
        </div>

        <div class="erperr-foot">
          @if (state === 'submitted' || state === 'failed') {
            <button type="button" class="erperr-btn erperr-btn-primary" (click)="close.emit()" autofocus>
              Close
            </button>
          } @else {
            <button type="button" class="erperr-btn erperr-btn-ghost" (click)="close.emit()">
              Dismiss
            </button>
            @if (result?.errorReference) {
              <button
                type="button"
                class="erperr-btn erperr-btn-primary"
                [disabled]="state === 'submitting'"
                (click)="onSubmit()"
              >
                {{ state === 'submitting' ? 'Reporting...' : 'Report issue' }}
              </button>
            }
          }
        </div>
      </div>
    </div>
  `,
  styles: [
    `
      :host {
        --erperr-accent: #b3261e;
        --erperr-fg: #1f2329;
        --erperr-muted: #5b6470;
        --erperr-border: #e2e5ea;
        --erperr-bg: #ffffff;
        font-family: inherit;
      }

      .erperr-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(17, 20, 24, 0.45);
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 16px;
        /* Above a typical ERP's own modals, which usually sit in the 1000-1100 band. */
        z-index: 2147483000;
      }

      .erperr-dialog {
        background: var(--erperr-bg);
        color: var(--erperr-fg);
        width: 100%;
        max-width: 480px;
        border-radius: 10px;
        box-shadow: 0 18px 48px rgba(0, 0, 0, 0.28);
        overflow: hidden;
        animation: erperr-in 140ms ease-out;
      }

      @keyframes erperr-in {
        from { transform: translateY(6px); opacity: 0; }
        to   { transform: none; opacity: 1; }
      }

      @media (prefers-reduced-motion: reduce) {
        .erperr-dialog { animation: none; }
      }

      .erperr-head {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 18px 20px 6px;
      }

      .erperr-icon { color: var(--erperr-accent); display: inline-flex; }

      .erperr-head h2 {
        margin: 0;
        font-size: 16px;
        font-weight: 600;
        letter-spacing: -0.01em;
      }

      .erperr-body { padding: 4px 20px 16px; }

      .erperr-lead { margin: 8px 0 10px; font-size: 14px; line-height: 1.5; }

      .erperr-note {
        margin: 0 0 10px;
        font-size: 13px;
        line-height: 1.5;
        color: var(--erperr-muted);
      }

      .erperr-known {
        background: #fff7e6;
        border: 1px solid #ffe2a8;
        color: #7a5200;
        border-radius: 6px;
        padding: 8px 10px;
      }

      .erperr-refs {
        margin: 0 0 12px;
        display: grid;
        gap: 6px;
        background: #f6f7f9;
        border: 1px solid var(--erperr-border);
        border-radius: 6px;
        padding: 10px 12px;
      }

      .erperr-refs div { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }
      .erperr-refs dt { font-size: 12px; color: var(--erperr-muted); margin: 0; }
      .erperr-refs dd { margin: 0; }

      .erperr-refs code {
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.02em;
        user-select: all;
      }

      .erperr-label {
        display: block;
        font-size: 12px;
        font-weight: 600;
        margin: 4px 0 6px;
      }

      .erperr-label span { font-weight: 400; color: var(--erperr-muted); }

      .erperr-textarea {
        width: 100%;
        box-sizing: border-box;
        border: 1px solid var(--erperr-border);
        border-radius: 6px;
        padding: 8px 10px;
        font: inherit;
        font-size: 13px;
        resize: vertical;
      }

      .erperr-textarea:focus {
        outline: 2px solid #2563eb;
        outline-offset: 1px;
        border-color: transparent;
      }

      .erperr-foot {
        display: flex;
        justify-content: flex-end;
        gap: 8px;
        padding: 12px 20px 18px;
        border-top: 1px solid var(--erperr-border);
        background: #fbfbfc;
      }

      .erperr-btn {
        font: inherit;
        font-size: 13px;
        font-weight: 600;
        border-radius: 6px;
        padding: 8px 14px;
        cursor: pointer;
        border: 1px solid transparent;
      }

      .erperr-btn:disabled { opacity: 0.6; cursor: default; }

      .erperr-btn-ghost {
        background: transparent;
        border-color: var(--erperr-border);
        color: var(--erperr-muted);
      }

      .erperr-btn-ghost:hover:not(:disabled) { background: #f0f1f3; }

      .erperr-btn-primary { background: #1f2329; color: #fff; }
      .erperr-btn-primary:hover:not(:disabled) { background: #33383f; }

      .erperr-btn:focus-visible { outline: 2px solid #2563eb; outline-offset: 2px; }
    `,
  ],
})
export class ErpErrorDialogComponent {
  private readonly cdr = inject(ChangeDetectorRef);

  @Input() result: ErpErrorCaptureResult | null = null;
  @Input() title = 'Something went wrong';
  @Input() allowDescription = true;
  /** Clicking the backdrop closes the dialog only before a ticket is raised. */
  @Input() closeOnBackdrop = true;

  @Output() readonly close = new EventEmitter<void>();
  @Output() readonly submitIssue = new EventEmitter<string | null>();

  state: ErpErrorDialogState = 'prompt';
  description = '';
  ticketNumber: string | null = null;
  wasDeduplicated = false;

  onSubmit(): void {
    this.state = 'submitting';
    this.cdr.markForCheck();
    this.submitIssue.emit(this.description.trim() || null);
  }

  /** Called by the notification service once the API answers. */
  setTicketResult(ticketNumber: string | null, wasDeduplicated: boolean): void {
    this.ticketNumber = ticketNumber;
    this.wasDeduplicated = wasDeduplicated;
    this.state = ticketNumber ? 'submitted' : 'failed';
    this.cdr.markForCheck();
  }

  onBackdrop(_event: MouseEvent): void {
    if (this.closeOnBackdrop && this.state !== 'submitting') this.close.emit();
  }
}

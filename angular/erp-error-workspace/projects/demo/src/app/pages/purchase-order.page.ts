import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Component, inject } from '@angular/core';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ErpFormErrorService } from 'erp-error-management';

/**
 * A deliberately ordinary ERP screen.
 *
 * Read the imports: it pulls in ErpFormErrorService and NOTHING else from the
 * framework, and that one service is only used for the two cases that are not
 * exceptions (failed validation, failed LOV).  Every other failure below is
 * captured with no participation from this file at all - no try/catch, no
 * subscribe error callback, no error handler.
 */
@Component({
  selector: 'demo-purchase-order',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  template: `
    <section class="panel">
      <header>
        <div>
          <h1>Purchase Order Entry</h1>
          <p class="sub">Module MM &middot; every button below fails on purpose</p>
        </div>
        <span class="env">Demo environment</span>
      </header>

      <form [formGroup]="form" class="grid">
        <label>
          Supplier code
          <input formControlName="supplierCode" placeholder="SUP-0001" />
        </label>
        <label>
          Cost centre
          <select formControlName="costCentre">
            <option value="">Select...</option>
            @for (option of costCentres; track option) {
              <option [value]="option">{{ option }}</option>
            }
          </select>
          <button type="button" class="link" (click)="loadCostCentreLov()">Reload LOV</button>
        </label>
        <label>
          Order value
          <input formControlName="orderValue" type="number" />
        </label>
        <label class="wide">
          Reference
          <input formControlName="reference" maxlength="20" />
        </label>
      </form>

      <div class="actions">
        <button class="primary" data-erp-action="save-order" (click)="save()">Save order</button>
      </div>
    </section>

    <section class="panel">
      <h2>Trigger a failure at each layer</h2>
      <p class="sub">
        These are the error classes listed in the brief. None of the handlers below
        catch anything.
      </p>

      <div class="triggers">
        <button data-erp-action="trigger-angular" (click)="angularRuntimeError()">
          <strong>Angular runtime</strong>
          <span>Uncaught TypeError in a component method</span>
        </button>

        <button data-erp-action="trigger-promise" (click)="unhandledRejection()">
          <strong>Unhandled promise</strong>
          <span>An async save nobody awaited</span>
        </button>

        <button data-erp-action="trigger-http500" (click)="apiUnhandled()">
          <strong>Web API exception</strong>
          <span>HTTP 500 &rarr; .NET NullReferenceException</span>
        </button>

        <button data-erp-action="trigger-deadlock" (click)="sqlDeadlock()">
          <strong>SQL Server deadlock</strong>
          <span>Error 1205 in usp_PostJournal &mdash; press twice</span>
        </button>

        <button data-erp-action="trigger-lov" (click)="lovServerFailure()">
          <strong>Stored procedure error</strong>
          <span>Invalid column in usp_GetCostCentreLov</span>
        </button>

        <button data-erp-action="trigger-timeout" (click)="gatewayTimeout()">
          <strong>Timeout</strong>
          <span>HTTP 504 from the API gateway</span>
        </button>

        <button data-erp-action="trigger-network" (click)="networkFailure()">
          <strong>Connection failure</strong>
          <span>Host unreachable &mdash; status 0</span>
        </button>

        <button data-erp-action="trigger-ok" (click)="successfulCall()">
          <strong>A call that works</strong>
          <span>Proves the interceptor is passive</span>
        </button>
      </div>
    </section>
  `,
  styles: [
    `
      :host { display: grid; gap: 16px; }
      .panel {
        background: #fff; border: 1px solid #e4e7ec; border-radius: 10px; padding: 18px 20px;
      }
      header { display: flex; justify-content: space-between; align-items: flex-start; }
      h1 { margin: 0; font-size: 18px; }
      h2 { margin: 0 0 4px; font-size: 15px; }
      .sub { margin: 4px 0 14px; color: #667085; font-size: 13px; }
      .env {
        font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em;
        background: #eef4ff; color: #2d5bd7; border-radius: 999px; padding: 4px 10px;
      }
      .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px 16px; }
      label { display: grid; gap: 5px; font-size: 12px; font-weight: 600; color: #344054; }
      label.wide { grid-column: span 3; }
      input, select {
        font: inherit; font-size: 13px; padding: 7px 9px; border: 1px solid #d0d5dd;
        border-radius: 6px; font-weight: 400;
      }
      input:focus, select:focus { outline: 2px solid #2d5bd7; outline-offset: 1px; border-color: transparent; }
      .link {
        justify-self: start; background: none; border: none; padding: 0;
        color: #2d5bd7; font-size: 11px; font-weight: 600; cursor: pointer; text-decoration: underline;
      }
      .actions { margin-top: 16px; display: flex; gap: 8px; }
      button.primary {
        font: inherit; font-size: 13px; font-weight: 600; background: #1f2329; color: #fff;
        border: none; border-radius: 6px; padding: 9px 18px; cursor: pointer;
      }
      .triggers { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
      .triggers button {
        font: inherit; text-align: left; display: grid; gap: 3px; cursor: pointer;
        background: #fbfcfd; border: 1px solid #e4e7ec; border-radius: 8px; padding: 10px 12px;
      }
      .triggers button:hover { border-color: #b7c2d0; background: #f4f7fb; }
      .triggers strong { font-size: 12.5px; color: #1f2329; }
      .triggers span { font-size: 11.5px; color: #667085; line-height: 1.35; }
      @media (max-width: 1000px) {
        .grid { grid-template-columns: 1fr 1fr; }
        label.wide { grid-column: span 2; }
        .triggers { grid-template-columns: 1fr 1fr; }
      }
    `,
  ],
})
export class PurchaseOrderPage {
  private readonly http = inject(HttpClient);
  private readonly fb = inject(FormBuilder);
  private readonly formErrors = inject(ErpFormErrorService);

  costCentres = ['CC-1000 Head Office', 'CC-2000 Warehouse'];

  form = this.fb.group({
    supplierCode: ['', [Validators.required, Validators.pattern(/^SUP-\d{4}$/)]],
    costCentre: ['', Validators.required],
    orderValue: [0, [Validators.required, Validators.min(1)]],
    reference: ['', Validators.maxLength(20)],
  });

  /** The single line that covers every form in an ERP with a shared save helper. */
  save(): void {
    if (this.form.invalid) {
      this.form.markAllAsTouched();
      this.formErrors.reportInvalidForm(this.form, 'PurchaseOrderHeader', 'save');
      return;
    }
    this.http.get('/api/demo/ok').subscribe();
  }

  /** Not a thrown error - a LOV that came back empty is still a fault worth logging. */
  loadCostCentreLov(): void {
    this.http.get<string[]>('/api/demo/lov-failure').subscribe({
      next: (rows) => {
        if (!rows?.length) {
          this.formErrors.reportLovFailure(new Error('LOV returned no rows'), 'COST_CENTRE', {
            requestedCode: 'COST_CENTRE',
            resolvedCount: 0,
          });
        }
      },
      // Deliberately empty: the interceptor already captured the HTTP failure.
      // This callback exists only to stop rxjs printing its own unhandled error.
      error: () => undefined,
    });
  }

  angularRuntimeError(): void {
    const order = undefined as unknown as { header: { netAmount: number } };
    // Throws. Nothing here catches it; ErpGlobalErrorHandler does.
    console.log(order.header.netAmount);
  }

  unhandledRejection(): void {
    // No .catch(), no await. This is the most common silent failure in an
    // Angular app and window.onunhandledrejection is the only thing that sees it.
    void Promise.reject(new Error('Purchase order draft could not be persisted to local storage'));
  }

  apiUnhandled(): void {
    this.http.get('/api/demo/server-error').subscribe({ error: () => undefined });
  }

  sqlDeadlock(): void {
    this.http.get('/api/demo/sql-deadlock').subscribe({ error: () => undefined });
  }

  lovServerFailure(): void {
    this.http.get('/api/demo/lov-failure').subscribe({ error: () => undefined });
  }

  gatewayTimeout(): void {
    this.http.get('/api/demo/slow-timeout').subscribe({ error: () => undefined });
  }

  networkFailure(): void {
    this.http.get('http://127.0.0.1:59999/unreachable').subscribe({ error: () => undefined });
  }

  successfulCall(): void {
    this.http.get('/api/demo/ok').subscribe();
  }
}

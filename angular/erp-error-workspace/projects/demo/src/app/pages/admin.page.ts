import { CommonModule, DatePipe } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';

/**
 * The ERP Administration / Support panel from the brief: error history,
 * recurring-problem analysis, the ticket queue, and the full audit trail with
 * the operational metrics.
 *
 * Reads the same endpoints a production console would; in production those are
 * usp_Error_Search, usp_Error_RecurringProblems, usp_Ticket_Search and
 * usp_Ticket_GetDetail.
 */
@Component({
  selector: 'demo-admin',
  standalone: true,
  imports: [CommonModule, FormsModule, DatePipe],
  template: `
    <section class="cards">
      <div class="card">
        <span class="label">Errors captured</span>
        <span class="value">{{ dashboard()?.errorsCaptured ?? '-' }}</span>
      </div>
      <div class="card">
        <span class="label">Distinct problems</span>
        <span class="value">{{ dashboard()?.distinctProblems ?? '-' }}</span>
      </div>
      <div class="card accent">
        <span class="label">Deduplication ratio</span>
        <span class="value">{{ dashboard()?.deduplicationRatio ?? '-' }}&times;</span>
        <span class="hint">errors per ticket-able problem</span>
      </div>
      <div class="card">
        <span class="label">Tickets created</span>
        <span class="value">{{ dashboard()?.ticketsCreated ?? '-' }}</span>
      </div>
      <div class="card">
        <span class="label">Open tickets</span>
        <span class="value">{{ dashboard()?.openTickets ?? '-' }}</span>
      </div>
    </section>

    <nav class="tabs">
      @for (t of tabs; track t.id) {
        <button [class.active]="tab() === t.id" (click)="tab.set(t.id); refresh()">{{ t.label }}</button>
      }
      <span class="spacer"></span>
      <button class="ghost" (click)="refresh()">Refresh</button>
    </nav>

    @switch (tab()) {
      @case ('problems') {
        <section class="panel">
          <h2>Recurring problems</h2>
          <p class="sub">
            One row per distinct fault. The count is every occurrence that collapsed onto it -
            this is the list that tells you what is worth fixing permanently.
          </p>
          <table>
            <thead>
              <tr>
                <th>Occurrences</th><th>Users</th><th>Severity</th><th>Layer</th>
                <th>Normalised signature</th><th>Location</th><th>Last seen</th><th>Ticket</th>
              </tr>
            </thead>
            <tbody>
              @for (p of problems(); track p.fingerprintHash) {
                <tr>
                  <td><span class="count" [class.hot]="p.occurrenceCount >= 5">{{ p.occurrenceCount }}</span></td>
                  <td>{{ p.distinctUserCount }}</td>
                  <td><span class="sev" [class]="p.severity">{{ p.severity }}</span></td>
                  <td><code>{{ p.layer }}</code></td>
                  <td class="msg">{{ p.normalizedMessage }}</td>
                  <td class="dim">{{ location(p) }}</td>
                  <td class="dim">{{ p.lastSeenUtc | date: 'dd MMM HH:mm' }}</td>
                  <td>
                    @if (p.openTicketNumber) {
                      <code class="tkt">{{ p.openTicketNumber }}</code>
                    } @else {
                      <span class="dim">-</span>
                    }
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </section>
      }

      @case ('errors') {
        <section class="panel">
          <h2>Error history</h2>
          <p class="sub">Every captured occurrence, across all layers.</p>
          <table>
            <thead>
              <tr>
                <th>Reference</th><th>When</th><th>Sev</th><th>Layer</th><th>Type</th>
                <th>Message</th><th>Where</th><th>User</th><th>Ticket</th>
              </tr>
            </thead>
            <tbody>
              @for (e of errors(); track e.errorReference) {
                <tr (click)="openCorrelation(e.correlationId)" class="clickable">
                  <td><code>{{ e.errorReference }}</code></td>
                  <td class="dim">{{ e.occurredUtc | date: 'dd MMM HH:mm:ss' }}</td>
                  <td><span class="sev" [class]="e.severity">{{ e.severity }}</span></td>
                  <td><code>{{ e.layer }}</code></td>
                  <td class="dim">{{ shortType(e.exceptionType) }}</td>
                  <td class="msg">{{ e.message }}</td>
                  <td class="dim">
                    {{ e.sqlObjectName ? e.sqlObjectName + ':' + e.sqlLineNumber
                       : (e.apiController ? e.apiController + '/' + e.apiAction : e.screen) }}
                  </td>
                  <td class="dim">{{ e.userName }}</td>
                  <td>
                    @if (e.ticketNumber) { <code class="tkt">{{ e.ticketNumber }}</code> }
                    @else { <span class="dim">-</span> }
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </section>
      }

      @case ('tickets') {
        <section class="split">
          <div class="panel">
            <h2>Support queue</h2>
            <p class="sub">Click a ticket to see its audit trail and change its status.</p>
            <table>
              <thead>
                <tr><th>Ticket</th><th>Status</th><th>Sev</th><th>Title</th><th>Linked</th><th>Elapsed</th><th>SLA</th></tr>
              </thead>
              <tbody>
                @for (t of tickets(); track t.ticketNumber) {
                  <tr (click)="selectTicket(t.ticketNumber)"
                      [class.selected]="selected()?.ticketNumber === t.ticketNumber" class="clickable">
                    <td><code class="tkt">{{ t.ticketNumber }}</code></td>
                    <td><span class="status" [class]="t.statusCode">{{ t.statusName }}</span></td>
                    <td><span class="sev" [class]="t.severityCode">{{ t.severityCode }}</span></td>
                    <td class="msg">{{ t.title }}</td>
                    <td>
                      <span class="count" [class.hot]="t.linkedOccurrenceCount > 1">
                        {{ t.linkedOccurrenceCount }}
                      </span>
                    </td>
                    <td class="dim">{{ t.totalElapsedMinutes }}m</td>
                    <td>
                      @if (t.slaFirstResponseBreached || t.slaResolutionBreached) {
                        <span class="breach">breached</span>
                      } @else {
                        <span class="dim">ok</span>
                      }
                    </td>
                  </tr>
                }
                @if (!tickets().length) {
                  <tr><td colspan="7" class="empty">
                    No tickets yet. Trigger an error on the Purchase Order screen and press
                    &ldquo;Report issue&rdquo; in the dialog.
                  </td></tr>
                }
              </tbody>
            </table>
          </div>

          @if (selected(); as t) {
            <div class="panel detail">
              <h2>{{ t.ticketNumber }}</h2>
              <p class="sub">{{ t.title }}</p>

              <dl class="meta">
                <div><dt>Status</dt><dd><span class="status" [class]="t.statusCode">{{ t.statusName }}</span></dd></div>
                <div><dt>Severity</dt><dd><span class="sev" [class]="t.severityCode">{{ t.severityCode }}</span></dd></div>
                <div><dt>Queue</dt><dd>{{ t.queue }}</dd></div>
                <div><dt>Raised by</dt><dd>{{ t.reportedBy }} ({{ t.createdVia }})</dd></div>
                <div><dt>Assigned to</dt><dd>{{ t.assignedTo || '-' }}</dd></div>
                <div><dt>Created</dt><dd>{{ t.createdUtc | date: 'dd MMM HH:mm' }}</dd></div>
                <div><dt>First response</dt><dd>{{ (t.firstResponseUtc | date: 'dd MMM HH:mm') || '-' }}</dd></div>
                <div><dt>Resolved</dt><dd>{{ (t.resolvedUtc | date: 'dd MMM HH:mm') || '-' }}</dd></div>
                <div><dt>Total elapsed</dt><dd>{{ t.totalElapsedMinutes }} min</dd></div>
                <div><dt>Active processing</dt><dd>{{ t.activeProcessingMinutes }} min</dd></div>
                <div><dt>Linked errors</dt><dd>{{ t.linkedOccurrenceCount }}</dd></div>
                <div><dt>Primary error</dt><dd><code>{{ t.primaryErrorReference }}</code></dd></div>
              </dl>

              @if (t.userDescription) {
                <blockquote>&ldquo;{{ t.userDescription }}&rdquo;</blockquote>
              }

              <h3>Move to</h3>
              <div class="transitions">
                @for (tr of t.allowedTransitions; track tr.to) {
                  <button (click)="move(t.ticketNumber, tr)">
                    {{ tr.display }}@if (tr.requiresComment) { <em> (needs note)</em> }
                  </button>
                }
                @if (!t.allowedTransitions.length) {
                  <span class="dim">Terminal status - no further transitions.</span>
                }
              </div>
              @if (transitionError()) {
                <p class="error">{{ transitionError() }}</p>
              }

              <h3>Audit trail</h3>
              <ol class="history">
                @for (h of t.history; track h.sequenceNo) {
                  <li>
                    <div class="row">
                      <strong>{{ h.fromStatusName || 'Created' }} &rarr; {{ h.toStatusName }}</strong>
                      <span class="dim">{{ h.changedUtc | date: 'dd MMM HH:mm:ss' }}</span>
                    </div>
                    <div class="row dim">
                      by {{ h.changedBy }}
                      @if (h.minutesInFromStatus !== null && h.minutesInFromStatus !== undefined) {
                        &middot; {{ h.minutesInFromStatus }} min in previous status
                      }
                    </div>
                    @if (h.comments) { <p class="note">{{ h.comments }}</p> }
                  </li>
                }
              </ol>

              @if (t.timeInStatus?.length) {
                <h3>Time in each status</h3>
                <table class="mini">
                  <tbody>
                    @for (s of t.timeInStatus; track s.statusCode) {
                      <tr>
                        <td>{{ s.statusName }}</td>
                        <td class="num">{{ s.minutesInStatus }} min</td>
                        <td class="dim">
                          {{ s.countsTowardActiveTime ? 'counts toward active time' : 'paused - excluded' }}
                        </td>
                      </tr>
                    }
                  </tbody>
                </table>
              }

              @if (t.linkedOccurrences?.length > 1) {
                <h3>Deduplicated occurrences ({{ t.linkedOccurrences.length }})</h3>
                <table class="mini">
                  <tbody>
                    @for (o of t.linkedOccurrences; track o.errorReference) {
                      <tr>
                        <td><code>{{ o.errorReference }}</code></td>
                        <td class="dim">{{ o.occurredUtc | date: 'HH:mm:ss' }}</td>
                        <td class="dim">{{ o.userName }}</td>
                        <td class="dim">{{ o.linkReason }}</td>
                      </tr>
                    }
                  </tbody>
                </table>
              }
            </div>
          }
        </section>
      }

      @case ('trail') {
        <section class="panel">
          <h2>Correlation trail</h2>
          <p class="sub">
            Everything recorded under one correlation id, deepest layer first. This is how
            &ldquo;the save button failed&rdquo; becomes &ldquo;a deadlock in usp_PostJournal&rdquo;.
          </p>
          <div class="trailbar">
            <input [(ngModel)]="correlationInput" placeholder="paste a correlation id" />
            <button (click)="openCorrelation(correlationInput)">Trace</button>
          </div>
          @if (trail().length) {
            <ol class="trail">
              @for (t of trail(); track t.errorReference) {
                <li>
                  <span class="layer">{{ t.layer }}</span>
                  <div>
                    <div class="row">
                      <strong>{{ shortType(t.exceptionType) }}</strong>
                      <code>{{ t.errorReference }}</code>
                    </div>
                    <p class="msg">{{ t.message }}</p>
                    <p class="dim">
                      {{ t.sqlObjectName ? 'in ' + t.sqlObjectName + ' line ' + t.sqlLineNumber
                         : (t.apiController ? t.apiController + '/' + t.apiAction : t.component) }}
                    </p>
                  </div>
                </li>
              }
            </ol>
          } @else {
            <p class="dim">Click any row in Error history to trace its correlation id.</p>
          }
        </section>
      }
    }
  `,
  styles: [
    `
      :host { display: grid; gap: 14px; }
      .panel { background: #fff; border: 1px solid #e4e7ec; border-radius: 10px; padding: 16px 18px; }
      h2 { margin: 0; font-size: 15px; }
      h3 { margin: 18px 0 6px; font-size: 12px; text-transform: uppercase;
           letter-spacing: .05em; color: #667085; }
      .sub { margin: 4px 0 12px; color: #667085; font-size: 12.5px; line-height: 1.45; }
      .dim { color: #98a2b3; }

      .cards { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
      .card {
        background: #fff; border: 1px solid #e4e7ec; border-radius: 10px;
        padding: 12px 14px; display: grid; gap: 2px;
      }
      .card.accent { background: #f6f9ff; border-color: #ccdcff; }
      .card .label { font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: #667085; }
      .card .value { font-size: 24px; font-weight: 700; letter-spacing: -0.02em; }
      .card .hint { font-size: 11px; color: #98a2b3; }

      .tabs { display: flex; gap: 6px; align-items: center; }
      .tabs button {
        font: inherit; font-size: 13px; font-weight: 600; border: 1px solid #e4e7ec;
        background: #fff; border-radius: 7px; padding: 7px 13px; cursor: pointer; color: #475467;
      }
      .tabs button.active { background: #1f2329; border-color: #1f2329; color: #fff; }
      .tabs .spacer { flex: 1; }
      .tabs .ghost { color: #667085; }

      table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
      th {
        text-align: left; font-size: 10.5px; text-transform: uppercase; letter-spacing: .05em;
        color: #667085; border-bottom: 1px solid #e4e7ec; padding: 6px 8px; font-weight: 700;
      }
      td { padding: 7px 8px; border-bottom: 1px solid #f2f4f7; vertical-align: top; }
      tr.clickable { cursor: pointer; }
      tr.clickable:hover td { background: #f8fafc; }
      tr.selected td { background: #eef4ff; }
      td.msg { max-width: 360px; }
      td.num { text-align: right; font-variant-numeric: tabular-nums; }
      td.empty { text-align: center; color: #98a2b3; padding: 22px; }
      table.mini td { font-size: 12px; padding: 5px 8px; }

      code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11.5px; }
      code.tkt { font-weight: 700; color: #2d5bd7; }

      .count {
        display: inline-block; min-width: 26px; text-align: center; font-weight: 700;
        background: #f2f4f7; border-radius: 5px; padding: 1px 6px; font-variant-numeric: tabular-nums;
      }
      .count.hot { background: #fde8e8; color: #b3261e; }

      .sev {
        display: inline-block; font-size: 10.5px; font-weight: 700; text-transform: uppercase;
        letter-spacing: .04em; border-radius: 4px; padding: 2px 6px;
      }
      .sev.critical { background: #fde8e8; color: #9f1d15; }
      .sev.high { background: #fff1e0; color: #97500b; }
      .sev.medium { background: #fff8e1; color: #7a5200; }
      .sev.low { background: #eef2f6; color: #475467; }
      .sev.info { background: #eef2f6; color: #667085; }

      .status {
        display: inline-block; font-size: 11px; font-weight: 700; border-radius: 4px; padding: 2px 7px;
        background: #eef2f6; color: #475467;
      }
      .status.new { background: #eef4ff; color: #2d5bd7; }
      .status.assigned { background: #e8f2ff; color: #1d4ed8; }
      .status.in_progress { background: #e7f6ec; color: #1b7f3b; }
      .status.waiting_info { background: #fff8e1; color: #7a5200; }
      .status.resolved { background: #e7f6ec; color: #12703a; }
      .status.closed { background: #eef2f6; color: #475467; }
      .status.reopened { background: #fde8e8; color: #9f1d15; }

      .breach { font-size: 11px; font-weight: 700; color: #b3261e; }

      .split { display: grid; grid-template-columns: 1.15fr 1fr; gap: 14px; align-items: start; }
      .detail dl.meta {
        display: grid; grid-template-columns: 1fr 1fr; gap: 6px 14px; margin: 10px 0 0;
      }
      .detail dl.meta div { display: flex; justify-content: space-between; gap: 10px; align-items: baseline; }
      .detail dt { font-size: 11px; color: #667085; margin: 0; }
      .detail dd { margin: 0; font-size: 12.5px; text-align: right; }

      blockquote {
        margin: 12px 0 0; padding: 8px 12px; background: #f8fafc;
        border-left: 3px solid #d0d5dd; font-size: 12.5px; color: #475467;
      }

      .transitions { display: flex; flex-wrap: wrap; gap: 6px; }
      .transitions button {
        font: inherit; font-size: 12px; font-weight: 600; border: 1px solid #d0d5dd;
        background: #fff; border-radius: 6px; padding: 6px 11px; cursor: pointer;
      }
      .transitions button:hover { background: #f4f7fb; border-color: #b7c2d0; }
      .transitions em { font-style: normal; font-weight: 400; color: #98a2b3; }

      .error { color: #b3261e; font-size: 12.5px; margin: 8px 0 0; }

      ol.history { list-style: none; margin: 0; padding: 0; display: grid; gap: 9px; }
      ol.history li { border-left: 2px solid #e4e7ec; padding: 0 0 0 11px; }
      .row { display: flex; justify-content: space-between; gap: 10px; font-size: 12.5px; }
      .note { margin: 3px 0 0; font-size: 12px; color: #475467; }

      .trailbar { display: flex; gap: 6px; margin-bottom: 12px; }
      .trailbar input {
        flex: 1; font: inherit; font-size: 12.5px; padding: 7px 9px;
        border: 1px solid #d0d5dd; border-radius: 6px;
      }
      .trailbar button {
        font: inherit; font-size: 12.5px; font-weight: 600; background: #1f2329; color: #fff;
        border: none; border-radius: 6px; padding: 7px 14px; cursor: pointer;
      }

      ol.trail { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
      ol.trail li { display: grid; grid-template-columns: 92px 1fr; gap: 12px; align-items: start;
                    border: 1px solid #e4e7ec; border-radius: 8px; padding: 10px 12px; }
      .layer {
        font-size: 10.5px; font-weight: 700; text-transform: uppercase; letter-spacing: .05em;
        background: #1f2329; color: #fff; border-radius: 4px; padding: 3px 7px; text-align: center;
      }
      ol.trail p { margin: 3px 0 0; font-size: 12.5px; }

      @media (max-width: 1100px) {
        .cards { grid-template-columns: repeat(3, 1fr); }
        .split { grid-template-columns: 1fr; }
      }
    `,
  ],
})
export class AdminPage {
  private readonly http = inject(HttpClient);

  tabs = [
    { id: 'problems', label: 'Recurring problems' },
    { id: 'errors', label: 'Error history' },
    { id: 'tickets', label: 'Ticket queue' },
    { id: 'trail', label: 'Correlation trail' },
  ];

  tab = signal<string>('problems');
  dashboard = signal<any>(null);
  problems = signal<any[]>([]);
  errors = signal<any[]>([]);
  tickets = signal<any[]>([]);
  selected = signal<any>(null);
  trail = signal<any[]>([]);
  transitionError = signal<string | null>(null);
  correlationInput = '';

  constructor() {
    this.refresh();
  }

  refresh(): void {
    this.http.get<any>('/api/error-management/admin/dashboard').subscribe((d) => this.dashboard.set(d));
    this.http.get<any>('/api/error-management/admin/problems').subscribe((d) => this.problems.set(d.items));
    this.http.get<any>('/api/error-management/admin/errors').subscribe((d) => this.errors.set(d.items));
    this.http.get<any>('/api/error-management/tickets').subscribe((d) => {
      this.tickets.set(d.items);
      const current = this.selected()?.ticketNumber;
      if (current) this.selectTicket(current);
    });
  }

  selectTicket(ticketNumber: string): void {
    this.transitionError.set(null);
    this.http
      .get<any>(`/api/error-management/tickets/${ticketNumber}`)
      .subscribe((t) => this.selected.set(t));
  }

  move(ticketNumber: string, transition: { to: string; display: string; requiresComment: boolean }): void {
    let comments: string | null = null;
    if (transition.requiresComment) {
      comments = prompt(`Note for "${transition.display}"`, '');
      // A cancelled prompt must not be sent as an empty comment - the server
      // would reject it and the user would see a confusing validation error
      // for something they deliberately abandoned.
      if (comments === null) return;
    }

    this.http
      .post<any>(`/api/error-management/tickets/${ticketNumber}/status`, {
        toStatus: transition.to,
        comments,
        assignTo: transition.to === 'assigned' ? 'sam.ops' : null,
      })
      .subscribe({
        next: () => this.refresh(),
        error: (e) => this.transitionError.set(e?.error?.message ?? 'The status change was rejected.'),
      });
  }

  openCorrelation(correlationId: string): void {
    if (!correlationId) return;
    this.correlationInput = correlationId;
    this.tab.set('trail');
    this.http
      .get<any>(`/api/error-management/admin/correlation/${correlationId}`)
      .subscribe((d) => this.trail.set(d.items));
  }

  /** Best available "where did this happen" label for a problem row. */
  location(p: any): string {
    if (p.sqlObjectName) return p.sqlObjectName;
    if (p.component) return p.component;
    if (p.screen) return p.screen;
    if (p.apiEndpoint) return p.apiEndpoint;
    return p.erpModule || '-';
  }

  shortType(type: string | null): string {
    if (!type) return '-';
    const parts = type.split('.');
    return parts[parts.length - 1];
  }
}

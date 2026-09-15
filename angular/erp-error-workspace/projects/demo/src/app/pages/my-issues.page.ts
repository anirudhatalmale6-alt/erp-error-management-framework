import { CommonModule, DatePipe } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Component, inject, signal } from '@angular/core';

/**
 * The end user's view: "the user should be able to see the current ticket
 * status and keep receiving updates until it is closed."
 *
 * Note what is NOT here - no stack trace, no SQL object, no exception type, no
 * assignee, no internal notes.  Production serves this from
 * usp_Ticket_GetDetail with @ForEndUser = 1, which filters the history to
 * customer-visible rows and nulls the diagnostic columns at the database, not
 * in the UI.  Filtering in the template would still have sent the data to the
 * browser.
 */
@Component({
  selector: 'demo-my-issues',
  standalone: true,
  imports: [CommonModule, DatePipe],
  template: `
    <section class="panel">
      <h1>My reported issues</h1>
      <p class="sub">Every issue you have reported, and where it has got to.</p>

      @if (!tickets().length) {
        <p class="empty">
          You have not reported any issues. Trigger an error on the Purchase Order screen
          and press &ldquo;Report issue&rdquo; in the dialog.
        </p>
      }

      <ul class="list">
        @for (t of tickets(); track t.ticketNumber) {
          <li>
            <div class="head">
              <code>{{ t.ticketNumber }}</code>
              <span class="status" [class]="t.statusCode">{{ t.statusName }}</span>
            </div>
            <p class="title">{{ t.title }}</p>
            <p class="dim">
              Reported {{ t.createdUtc | date: 'dd MMM yyyy, HH:mm' }}
              @if (t.resolvedUtc) { &middot; resolved {{ t.resolvedUtc | date: 'dd MMM, HH:mm' }} }
            </p>
            @if (latestUpdate(t); as note) {
              <p class="note">Latest update: {{ note }}</p>
            }
          </li>
        }
      </ul>
    </section>
  `,
  styles: [
    `
      .panel { background: #fff; border: 1px solid #e4e7ec; border-radius: 10px; padding: 18px 20px; }
      h1 { margin: 0; font-size: 18px; }
      .sub { margin: 4px 0 16px; color: #667085; font-size: 13px; }
      .empty { color: #98a2b3; font-size: 13px; }
      .list { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
      .list li { border: 1px solid #e4e7ec; border-radius: 8px; padding: 12px 14px; }
      .head { display: flex; justify-content: space-between; align-items: center; }
      code { font-family: ui-monospace, Menlo, Consolas, monospace; font-weight: 700; color: #2d5bd7; }
      .title { margin: 7px 0 3px; font-size: 13.5px; }
      .dim { margin: 0; color: #98a2b3; font-size: 12px; }
      .note { margin: 7px 0 0; font-size: 12.5px; color: #475467;
              background: #f8fafc; border-left: 3px solid #d0d5dd; padding: 6px 10px; }
      .status { font-size: 11px; font-weight: 700; border-radius: 4px; padding: 2px 8px;
                background: #eef2f6; color: #475467; }
      .status.new { background: #eef4ff; color: #2d5bd7; }
      .status.assigned { background: #e8f2ff; color: #1d4ed8; }
      .status.in_progress { background: #e7f6ec; color: #1b7f3b; }
      .status.waiting_info { background: #fff8e1; color: #7a5200; }
      .status.resolved { background: #e7f6ec; color: #12703a; }
      .status.closed { background: #eef2f6; color: #475467; }
    `,
  ],
})
export class MyIssuesPage {
  private readonly http = inject(HttpClient);
  tickets = signal<any[]>([]);

  constructor() {
    this.http
      .get<any>('/api/error-management/tickets')
      .subscribe((d) => this.tickets.set(d.items ?? []));
  }

  latestUpdate(ticket: any): string | null {
    return ticket.latestUpdate ?? null;
  }
}

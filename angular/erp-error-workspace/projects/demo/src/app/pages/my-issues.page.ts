import { CommonModule, DatePipe } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';

/**
 * The end user's "My Tickets" panel.
 *
 * Scoped server-side to the caller's identity - this component does not send a
 * user name and could not ask for someone else's list if it wanted to. In
 * production the identity comes from the validated JWT; here the demo API
 * stands in with a header.
 *
 * Note what is absent: no stack trace, no SQL object, no exception type, no
 * assignee, no SLA figures, no elapsed metrics. Those are removed by
 * usp_Ticket_GetForUser, not by this template - filtering in the UI would still
 * have sent them to the browser, where anyone can read them in the network tab.
 */
@Component({
  selector: 'demo-my-issues',
  standalone: true,
  imports: [CommonModule, FormsModule, DatePipe],
  template: `
    <section class="layout">
      <div class="panel list">
        <header>
          <div>
            <h1>My reported issues</h1>
            <p class="sub">Signed in as <strong>{{ user }}</strong></p>
          </div>
          <div class="head-actions">
            <label class="toggle">
              <input type="checkbox" [(ngModel)]="onlyOpen" (change)="load()" />
              Open only
            </label>
            <button class="new" (click)="toggleCreate()">
              {{ creating() ? 'Cancel' : '+ New issue' }}
            </button>
          </div>
        </header>

        @if (creating()) {
          <form class="create" (ngSubmit)="submitNew()">
            <p class="sub">
              Raise an issue directly &mdash; no error needed. Use this when nothing
              crashed but something is still wrong.
            </p>

            <label>
              What is the problem?
              <select [(ngModel)]="draft.requestCategory" name="cat">
                @for (c of categories(); track c.code) {
                  <option [ngValue]="c.code">{{ c.displayName }}</option>
                }
              </select>
            </label>

            <label>
              Short summary
              <input [(ngModel)]="draft.title" name="title" maxlength="200"
                     placeholder="e.g. Totals on the monthly GL report look wrong" />
            </label>

            <label>
              Details
              <textarea rows="3" maxlength="4000" [(ngModel)]="draft.description" name="desc"
                        placeholder="What you expected, what happened, and which record or screen"></textarea>
            </label>

            <div class="two">
              <label>
                Module <span>(optional)</span>
                <input [(ngModel)]="draft.erpModule" name="mod" maxlength="40" placeholder="FI" />
              </label>
              <label>
                Screen <span>(optional)</span>
                <input [(ngModel)]="draft.reportedScreen" name="scr" maxlength="80"
                       placeholder="GL Trial Balance" />
              </label>
            </div>

            <div class="actions">
              <button type="submit" [disabled]="!draft.title.trim() || submitting()">
                {{ submitting() ? 'Creating...' : 'Create issue' }}
              </button>
              <span class="dim">
                Priority is set from the category, so support can triage consistently.
              </span>
            </div>
            @if (createError()) { <p class="error">{{ createError() }}</p> }
          </form>
        }

        @if (!tickets().length) {
          <p class="empty">
            You have not reported any issues. Either trigger an error on the
            Purchase Order screen and press &ldquo;Report issue&rdquo;, or use
            <strong>+ New issue</strong> above to raise one directly.
          </p>
        }

        <ul class="items">
          @for (t of tickets(); track t.ticketNumber) {
            <li
              [class.selected]="selected()?.ticketNumber === t.ticketNumber"
              [class.attention]="t.awaitingYourReply"
              (click)="open(t.ticketNumber)"
            >
              <div class="row">
                <code>{{ t.ticketNumber }}</code>
                <span class="status" [class]="t.statusCode">{{ t.statusName }}</span>
              </div>
              <p class="title">{{ t.title }}</p>
              <p class="dim">
                {{ t.erpModule || 'General' }} &middot; reported
                {{ t.createdUtc | date: 'dd MMM, HH:mm' }}
              </p>
              @if (t.awaitingYourReply) {
                <p class="waiting">Support is waiting for your reply</p>
              }
            </li>
          }
        </ul>
      </div>

      @if (selected(); as t) {
        <div class="panel detail">
          <header>
            <div>
              <h2>{{ t.ticketNumber }}</h2>
              <p class="sub">{{ t.title }}</p>
            </div>
            <span class="status" [class]="t.statusCode">{{ t.statusName }}</span>
          </header>

          <dl class="meta">
            <div><dt>Reported</dt><dd>{{ t.createdUtc | date: 'dd MMM yyyy, HH:mm' }}</dd></div>
            <div>
              <dt>First response</dt>
              <dd>{{ (t.firstResponseUtc | date: 'dd MMM, HH:mm') || 'Not yet' }}</dd>
            </div>
            <div><dt>Module</dt><dd>{{ t.erpModule || '-' }}</dd></div>
            <div><dt>Error reference</dt><dd><code>{{ t.errorReference }}</code></dd></div>
          </dl>

          @if (t.yourDescription) {
            <h3>What you told us</h3>
            <blockquote>{{ t.yourDescription }}</blockquote>
          }

          @if (t.resolutionNotes) {
            <h3>Resolution</h3>
            <div class="resolution">{{ t.resolutionNotes }}</div>
          }

          <h3>Progress</h3>
          <ol class="timeline">
            @for (h of t.history; track h.sequenceNo) {
              <li>
                <div class="row">
                  <strong>{{ h.statusName }}</strong>
                  <span class="dim">{{ h.changedUtc | date: 'dd MMM, HH:mm' }}</span>
                </div>
                @if (h.comments) { <p class="note">{{ h.comments }}</p> }
              </li>
            }
          </ol>

          @if (t.comments?.length) {
            <h3>Messages</h3>
            <ul class="thread">
              @for (c of t.comments; track c.createdUtc) {
                <li [class.mine]="c.authorRole === 'reporter'">
                  <div class="row">
                    <strong>{{ c.authorName }}</strong>
                    <span class="dim">{{ c.createdUtc | date: 'dd MMM, HH:mm' }}</span>
                  </div>
                  <p>{{ c.commentText }}</p>
                </li>
              }
            </ul>
          }

          @if (t.canComment) {
            <h3>{{ t.awaitingYourReply ? 'Reply to support' : 'Add a message' }}</h3>
            <div class="reply">
              <textarea
                rows="3"
                maxlength="2000"
                [(ngModel)]="replyText"
                [placeholder]="t.awaitingYourReply
                  ? 'Answer the question above so support can continue'
                  : 'Add anything else that might help'"
              ></textarea>
              <button [disabled]="!replyText.trim() || sending()" (click)="send(t.ticketNumber)">
                {{ sending() ? 'Sending...' : 'Send' }}
              </button>
            </div>
            @if (replyError()) { <p class="error">{{ replyError() }}</p> }
          } @else {
            <p class="dim closed-note">
              This ticket is closed. Reply is disabled - raise a new issue if the problem returns.
            </p>
          }
        </div>
      }
    </section>
  `,
  styles: [
    `
      .layout { display: grid; grid-template-columns: 380px 1fr; gap: 14px; align-items: start; }
      .panel { background: #fff; border: 1px solid #e4e7ec; border-radius: 10px; padding: 16px 18px; }
      header { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
      h1 { margin: 0; font-size: 17px; }
      h2 { margin: 0; font-size: 15px; font-family: ui-monospace, Menlo, Consolas, monospace; }
      h3 { margin: 18px 0 6px; font-size: 11px; text-transform: uppercase;
           letter-spacing: .05em; color: #667085; }
      .sub { margin: 4px 0 0; color: #667085; font-size: 12.5px; }
      .dim { color: #98a2b3; }
      .empty { color: #98a2b3; font-size: 13px; margin-top: 14px; }

      .head-actions { display: flex; gap: 10px; align-items: center; }
      .new {
        font: inherit; font-size: 12.5px; font-weight: 600; background: #1f2329; color: #fff;
        border: none; border-radius: 6px; padding: 7px 13px; cursor: pointer; white-space: nowrap;
      }

      form.create {
        margin-top: 14px; padding: 14px; border: 1px solid #ccdcff; background: #f6f9ff;
        border-radius: 8px; display: grid; gap: 10px;
      }
      form.create .sub { margin: 0; }
      form.create label { display: grid; gap: 4px; font-size: 12px; font-weight: 600; color: #344054; }
      form.create label span { font-weight: 400; color: #98a2b3; }
      form.create input, form.create select, form.create textarea {
        font: inherit; font-size: 12.5px; padding: 7px 9px; border: 1px solid #d0d5dd;
        border-radius: 6px; font-weight: 400; width: 100%; box-sizing: border-box; resize: vertical;
      }
      form.create .two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
      form.create .actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
      form.create .actions button {
        font: inherit; font-size: 12.5px; font-weight: 600; background: #2d5bd7; color: #fff;
        border: none; border-radius: 6px; padding: 8px 16px; cursor: pointer;
      }
      form.create .actions button:disabled { opacity: .5; cursor: default; }
      form.create .dim { font-size: 11.5px; }

      .toggle { font-size: 12px; color: #475467; display: flex; gap: 5px; align-items: center;
                white-space: nowrap; }

      ul.items { list-style: none; margin: 14px 0 0; padding: 0; display: grid; gap: 8px; }
      ul.items li { border: 1px solid #e4e7ec; border-radius: 8px; padding: 10px 12px; cursor: pointer; }
      ul.items li:hover { background: #f8fafc; border-color: #b7c2d0; }
      ul.items li.selected { background: #eef4ff; border-color: #a8c4ff; }
      ul.items li.attention { border-left: 3px solid #d97706; }
      .row { display: flex; justify-content: space-between; gap: 10px; align-items: baseline; }
      .title { margin: 6px 0 3px; font-size: 13px; line-height: 1.35; }
      ul.items .dim { margin: 0; font-size: 11.5px; }
      .waiting { margin: 6px 0 0; font-size: 11.5px; font-weight: 700; color: #b45309; }

      code { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 11.5px;
             font-weight: 700; color: #2d5bd7; }

      .status { font-size: 11px; font-weight: 700; border-radius: 4px; padding: 2px 8px;
                background: #eef2f6; color: #475467; white-space: nowrap; }
      .status.new { background: #eef4ff; color: #2d5bd7; }
      .status.assigned { background: #e8f2ff; color: #1d4ed8; }
      .status.in_progress { background: #e7f6ec; color: #1b7f3b; }
      .status.waiting_info { background: #fff4e0; color: #b45309; }
      .status.resolved { background: #e7f6ec; color: #12703a; }
      .status.closed { background: #eef2f6; color: #475467; }
      .status.reopened { background: #fde8e8; color: #9f1d15; }

      dl.meta { display: grid; grid-template-columns: 1fr 1fr; gap: 6px 16px; margin: 14px 0 0; }
      dl.meta div { display: flex; justify-content: space-between; gap: 10px; align-items: baseline; }
      dt { font-size: 11px; color: #667085; margin: 0; }
      dd { margin: 0; font-size: 12.5px; text-align: right; }

      blockquote { margin: 0; padding: 8px 12px; background: #f8fafc;
                   border-left: 3px solid #d0d5dd; font-size: 12.5px; color: #475467; }
      .resolution { padding: 9px 12px; background: #eefaf1; border: 1px solid #bfe6cd;
                    border-radius: 6px; font-size: 12.5px; color: #12703a; }

      ol.timeline { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
      ol.timeline li { border-left: 2px solid #e4e7ec; padding: 0 0 0 11px; font-size: 12.5px; }
      .note { margin: 3px 0 0; font-size: 12px; color: #475467; }

      ul.thread { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
      ul.thread li { border: 1px solid #e4e7ec; border-radius: 8px; padding: 9px 11px; font-size: 12.5px; }
      ul.thread li.mine { background: #f6f9ff; border-color: #ccdcff; }
      ul.thread p { margin: 4px 0 0; }

      .reply { display: flex; gap: 8px; align-items: flex-start; }
      .reply textarea { flex: 1; font: inherit; font-size: 12.5px; padding: 8px 10px;
                        border: 1px solid #d0d5dd; border-radius: 6px; resize: vertical; }
      .reply button { font: inherit; font-size: 12.5px; font-weight: 600; background: #1f2329;
                      color: #fff; border: none; border-radius: 6px; padding: 8px 16px; cursor: pointer; }
      .reply button:disabled { opacity: .5; cursor: default; }
      .error { color: #b3261e; font-size: 12.5px; margin: 8px 0 0; }
      .closed-note { font-size: 12.5px; margin-top: 14px; }

      @media (max-width: 1000px) { .layout { grid-template-columns: 1fr; } }
    `,
  ],
})
export class MyIssuesPage {
  private readonly http = inject(HttpClient);

  /** Stands in for the JWT subject in the demo. */
  readonly user = 'fatima.saeed';

  tickets = signal<any[]>([]);
  selected = signal<any>(null);
  sending = signal(false);
  replyError = signal<string | null>(null);
  onlyOpen = false;
  replyText = '';

  creating = signal(false);
  submitting = signal(false);
  createError = signal<string | null>(null);
  categories = signal<any[]>([]);

  draft = {
    title: '', description: '', requestCategory: 'wrong_data',
    erpModule: '', reportedScreen: '',
  };

  constructor() {
    this.load();
    // Categories are rows in ERM.ERM_RequestCategory, not a hard-coded enum,
    // so support can change the list without a front-end release.
    this.http
      .get<any>('/api/error-management/request-categories')
      .subscribe((d) => this.categories.set(d.items ?? []));
  }

  toggleCreate(): void {
    this.creating.set(!this.creating());
    this.createError.set(null);
  }

  submitNew(): void {
    if (!this.draft.title.trim()) return;

    this.submitting.set(true);
    this.createError.set(null);

    // No owner is sent: the server takes it from the token, so nobody can
    // raise a ticket in someone else's name.
    this.http
      .post<any>('/api/error-management/tickets/manual', {
        title: this.draft.title.trim(),
        description: this.draft.description?.trim() || null,
        requestCategory: this.draft.requestCategory,
        erpModule: this.draft.erpModule?.trim() || null,
        reportedScreen: this.draft.reportedScreen?.trim() || null,
      })
      .subscribe({
        next: (r) => {
          this.submitting.set(false);
          this.creating.set(false);
          this.draft = {
            title: '', description: '', requestCategory: 'wrong_data',
            erpModule: '', reportedScreen: '',
          };
          this.load();
          if (r?.ticketNumber) this.open(r.ticketNumber);
        },
        error: (e) => {
          this.submitting.set(false);
          this.createError.set(e?.error?.message ?? 'The issue could not be created.');
        },
      });
  }

  load(): void {
    this.http
      .get<any>(`/api/error-management/tickets/mine?onlyOpen=${this.onlyOpen}`)
      .subscribe((d) => {
        this.tickets.set(d.items ?? []);
        const current = this.selected()?.ticketNumber;
        if (current) this.open(current);
        else if (d.items?.length) this.open(d.items[0].ticketNumber);
      });
  }

  open(ticketNumber: string): void {
    this.replyError.set(null);
    this.http
      .get<any>(`/api/error-management/my-tickets/${ticketNumber}`)
      .subscribe({
        next: (t) => this.selected.set(t),
        // A 404 here means "not yours or not there" - the two are deliberately
        // indistinguishable, so there is nothing more useful to say.
        error: () => this.selected.set(null),
      });
  }

  send(ticketNumber: string): void {
    const text = this.replyText.trim();
    if (!text) return;

    this.sending.set(true);
    this.replyError.set(null);

    this.http
      .post<any>(`/api/error-management/my-tickets/${ticketNumber}/comments`, { commentText: text })
      .subscribe({
        next: () => {
          this.sending.set(false);
          this.replyText = '';
          // Reload rather than patch locally: the reply may have moved the
          // ticket out of "Waiting for Information", and the list ordering
          // depends on that.
          this.load();
        },
        error: () => {
          this.sending.set(false);
          this.replyError.set('Your message could not be sent. Please try again.');
        },
      });
  }
}

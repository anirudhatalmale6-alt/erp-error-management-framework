import { DestroyRef, Injectable, inject } from '@angular/core';
import { ActivatedRoute, NavigationEnd, Router } from '@angular/router';
import { filter } from 'rxjs/operators';
import {
  ERP_NO_USER,
  ErpErrorBreadcrumb,
  ErpErrorClientInfo,
  ErpErrorUserContext,
  normalizeUserProfileId,
} from '../models/error-envelope';
import { ERP_ERROR_CONFIG, ErpErrorRouteContext } from '../config/erp-error-config';
import { scrubText } from './redaction';

/**
 * Ambient context: who, where, and what just happened.
 *
 * The brief is explicit that no page should have to declare any of this.  So
 * the module/screen come from route data (declared once per route, where the
 * routes already live), the correlation id is generated here, and the
 * breadcrumb trail builds itself from router events plus whatever the HTTP
 * interceptor records.
 */
@Injectable({ providedIn: 'root' })
export class ErpErrorContextService {
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly router = inject(Router, { optional: true });
  private readonly route = inject(ActivatedRoute, { optional: true });
  private readonly destroyRef = inject(DestroyRef);

  /**
   * One correlation id per browser session, rotated on each top-level
   * navigation.  Per-session alone is too coarse (a day's work under one id);
   * per-request is too fine (the Angular error and its HTTP cause would not
   * share one).  Per-navigation is the unit a user actually reports: "it broke
   * when I opened the invoice and pressed save".
   */
  private correlationId = newGuid();

  private module: string | undefined;
  private screen: string | undefined;

  private readonly breadcrumbs: ErpErrorBreadcrumb[] = [];

  /** Component name set by the ErrorHandler just before it reports. */
  activeComponent: string | null = null;

  constructor() {
    this.module = this.config.defaultErpModule;

    if (this.router) {
      const sub = this.router.events
        .pipe(filter((e): e is NavigationEnd => e instanceof NavigationEnd))
        .subscribe((e) => {
          this.correlationId = newGuid();
          this.applyRouteContext();
          this.addBreadcrumb({
            kind: 'navigation',
            message: e.urlAfterRedirects,
          });
        });
      this.destroyRef.onDestroy(() => sub.unsubscribe());
    }
  }

  getCorrelationId(): string {
    return this.correlationId;
  }

  /** Called by the interceptor so a retry gets a fresh request id. */
  newRequestId(): string {
    return newGuid();
  }

  getModule(): string | null {
    return this.module ?? this.config.defaultErpModule ?? null;
  }

  getScreen(): string | null {
    return this.screen ?? null;
  }

  getRouteUrl(): string | null {
    return this.router?.url ?? (typeof location !== 'undefined' ? location.pathname : null);
  }

  /** Escape hatch for a feature that wants to name itself more precisely. */
  setContext(ctx: ErpErrorRouteContext): void {
    if (ctx.module) this.module = ctx.module;
    if (ctx.screen) this.screen = ctx.screen;
  }

  /**
   * The user, with `profileId` always a number.
   *
   * Anything the host returns that is not a positive integer becomes -1. That
   * matters more than it looks: `GetUserProfileKey()` returns 0, undefined or
   * an empty string at various points before login completes, and letting any
   * of those through would either crash the shredding in SQL or, worse, file
   * the error against user 0.
   */
  getUser(): ErpErrorUserContext | null {
    if (!this.config.userProvider) return { profileId: ERP_NO_USER };
    try {
      const supplied = this.config.userProvider();
      if (!supplied) return { profileId: ERP_NO_USER };
      return { ...supplied, profileId: normalizeUserProfileId(supplied.profileId) };
    } catch {
      // A broken user provider must never stop an error being reported - that
      // is exactly the moment the identity service is likely to be the thing
      // that is broken.
      return { profileId: ERP_NO_USER };
    }
  }

  addBreadcrumb(crumb: Omit<ErpErrorBreadcrumb, 'at'>): void {
    this.breadcrumbs.push({
      at: new Date().toISOString(),
      kind: crumb.kind,
      message: scrubText(crumb.message, 300) ?? '',
      data: crumb.data,
    });
    const max = this.config.maxBreadcrumbs;
    if (this.breadcrumbs.length > max) {
      this.breadcrumbs.splice(0, this.breadcrumbs.length - max);
    }
  }

  getBreadcrumbs(): ErpErrorBreadcrumb[] {
    return this.breadcrumbs.slice();
  }

  getClientInfo(): ErpErrorClientInfo {
    if (typeof navigator === 'undefined') return {};
    const ua = navigator.userAgent ?? '';
    return {
      browserName: browserName(ua),
      browserVersion: browserVersion(ua),
      osName: osName(ua),
      deviceType: /Mobi|Android|iPhone/i.test(ua)
        ? 'mobile'
        : /iPad|Tablet/i.test(ua)
          ? 'tablet'
          : 'desktop',
      screenResolution:
        typeof screen !== 'undefined' ? `${screen.width}x${screen.height}` : null,
      locale: navigator.language ?? null,
    };
  }

  private applyRouteContext(): void {
    if (!this.route) return;
    // Walk to the deepest activated route so a lazy child's context wins over
    // its parent's - which is what you want when a shell route declares the
    // module and the child declares the screen.
    let r = this.route.snapshot;
    let found: ErpErrorRouteContext | undefined;
    while (r) {
      const ctx = r.data?.['erpErrorContext'] as ErpErrorRouteContext | undefined;
      if (ctx) found = { ...found, ...ctx };
      if (!r.firstChild) break;
      r = r.firstChild;
    }
    this.module = found?.module ?? this.config.defaultErpModule;
    this.screen = found?.screen;
  }
}

/** RFC 4122 v4.  crypto.randomUUID where available, Math.random fallback otherwise. */
export function newGuid(): string {
  if (typeof crypto !== 'undefined') {
    if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
    if (typeof crypto.getRandomValues === 'function') {
      const b = crypto.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }
  }
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function browserName(ua: string): string {
  if (/Edg\//.test(ua)) return 'Edge';
  if (/OPR\//.test(ua)) return 'Opera';
  if (/Chrome\//.test(ua)) return 'Chrome';
  if (/Firefox\//.test(ua)) return 'Firefox';
  if (/Safari\//.test(ua)) return 'Safari';
  if (/Trident\//.test(ua)) return 'Internet Explorer';
  return 'Unknown';
}

function browserVersion(ua: string): string | null {
  const m = /(?:Edg|OPR|Chrome|Firefox|Version)\/(\d+(\.\d+)?)/.exec(ua);
  return m ? m[1] : null;
}

function osName(ua: string): string {
  if (/Windows NT 10/.test(ua)) return 'Windows 10/11';
  if (/Windows NT/.test(ua)) return 'Windows';
  if (/Android/.test(ua)) return 'Android';
  if (/iPhone|iPad|iPod/.test(ua)) return 'iOS';
  if (/Mac OS X/.test(ua)) return 'macOS';
  if (/Linux/.test(ua)) return 'Linux';
  return 'Unknown';
}

/*
 * Public API of @erp/error-management.
 *
 * Anything not exported here is an implementation detail and may change
 * between framework versions without a major bump.
 */

/* ---- integration ---- */
export * from './lib/provide-erp-error-management';
export * from './lib/config/erp-error-config';

/* ---- capture ---- */
export * from './lib/capture/erp-global-error-handler';
export * from './lib/capture/erp-http-error.interceptor';
export * from './lib/capture/erp-legacy-http-error.interceptor';
export * from './lib/capture/handled-failures';
export * from './lib/capture/erp-error-reporter.service';

/* ---- context and classification ---- */
export * from './lib/core/erp-error-context.service';
export * from './lib/core/classifier';
export * from './lib/core/fingerprint';
export * from './lib/core/redaction';
export { sha256Hex } from './lib/core/sha256';

/* ---- transport ---- */
export * from './lib/transport/erp-error-transport.service';

/* ---- user experience ---- */
export * from './lib/ui/erp-error-notification.service';
export * from './lib/ui/erp-error-dialog.component';

/* ---- forms, LOVs, submit actions ---- */
export * from './lib/forms/erp-form-error.service';

/* ---- contracts ---- */
export * from './lib/models/error-envelope';

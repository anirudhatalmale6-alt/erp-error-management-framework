/**
 * The wire contract between every capture point (Angular, Web API 2, ASP.NET
 * Core) and ERM.usp_Error_Capture.
 *
 * Keep this file and Erp.ErrorManagement.Core/ErrorEnvelope.cs in step - they
 * are two spellings of the same JSON document, and the stored procedure shreds
 * exactly these property names.
 */

export type ErpErrorLayer =
  | 'angular'
  | 'http'
  | 'webapi'
  | 'business'
  | 'data'
  | 'database'
  | 'integration'
  | 'infrastructure';

export type ErpErrorSeverity = 'critical' | 'high' | 'medium' | 'low' | 'info';

/** Matches ERM.ERM_ErrorCategory.Code.  New codes are a row in that table, not a code change. */
export type ErpErrorCategory =
  | 'angular_runtime'
  | 'angular_render'
  | 'validation'
  | 'submit_action'
  | 'lov_lookup'
  | 'client_network'
  | 'chunk_load'
  | 'http_client'
  | 'http_server'
  | 'http_timeout'
  | 'auth'
  | 'api_unhandled'
  | 'business_rule'
  | 'concurrency'
  | 'serialization'
  | 'sql_error'
  | 'sql_procedure'
  | 'sql_constraint'
  | 'sql_deadlock'
  | 'sql_timeout'
  | 'db_connection'
  | 'integration'
  | 'configuration'
  | 'unclassified';

export interface ErpErrorUserContext {
  id?: string | null;
  name?: string | null;
  displayName?: string | null;
  tenantId?: string | null;
  sessionId?: string | null;
  /** Filled in server-side from the connection; never trusted from the client. */
  clientIp?: string | null;
}

export interface ErpErrorClientInfo {
  browserName?: string | null;
  browserVersion?: string | null;
  osName?: string | null;
  deviceType?: string | null;
  screenResolution?: string | null;
  locale?: string | null;
}

export interface ErpErrorBreadcrumb {
  /** ISO-8601 UTC. */
  at: string;
  kind: 'navigation' | 'http' | 'click' | 'form' | 'lov' | 'console' | 'custom';
  message: string;
  data?: Record<string, unknown>;
}

export interface ErpValidationErrorItem {
  /** Reactive-forms control path, e.g. 'header.customerCode'. */
  control: string;
  /** The failing validator key, e.g. 'required', 'maxlength', 'erpCreditLimit'. */
  rule: string;
  /**
   * Validator metadata only (limits, patterns, expected lengths).
   * The value the user typed is never included - see redaction.ts.
   */
  detail?: Record<string, unknown>;
}

export interface ErpSqlErrorInfo {
  number?: number | null;
  severity?: number | null;
  state?: number | null;
  /** Procedure, function or trigger name, straight from SqlException.Procedure. */
  objectName?: string | null;
  lineNumber?: number | null;
  serverName?: string | null;
  databaseName?: string | null;
  schemaName?: string | null;
  statement?: string | null;
}

export interface ErpErrorEnvelope {
  /** SHA-256 of signatureText, lower-case hex.  Computed client-side. */
  fingerprintHash: string;
  /** The human-readable string the hash was taken over. */
  signatureText: string;

  layer: ErpErrorLayer;
  category: ErpErrorCategory;
  severity: ErpErrorSeverity;

  exceptionType?: string | null;
  message?: string | null;
  /** Message with volatile fragments replaced by placeholders. */
  normalizedMessage?: string | null;

  /** ISO-8601 UTC. */
  occurredUtc: string;
  /** ISO-8601 without offset - the user's wall clock. */
  occurredLocal?: string | null;
  clientUtcOffsetMinutes?: number | null;

  erpModule?: string | null;
  screen?: string | null;
  routeUrl?: string | null;
  component?: string | null;
  actionName?: string | null;
  formName?: string | null;
  lovName?: string | null;

  apiApplication?: string | null;
  apiController?: string | null;
  apiAction?: string | null;
  apiEndpoint?: string | null;
  httpMethod?: string | null;
  httpStatusCode?: number | null;
  durationMs?: number | null;

  sql?: ErpSqlErrorInfo | null;
  user?: ErpErrorUserContext | null;
  client?: ErpErrorClientInfo | null;

  correlationId: string;
  requestId?: string | null;
  /** Set when this error is the visible consequence of one already reported. */
  parentErrorReference?: string | null;

  environment: string;
  appVersion?: string | null;
  machineName?: string | null;

  stackTrace?: string | null;
  innerExceptionChain?: string | null;

  requestPayload?: unknown;
  responsePayload?: unknown;
  validationErrors?: ErpValidationErrorItem[] | null;
  breadcrumbs?: ErpErrorBreadcrumb[] | null;
  customData?: Record<string, unknown> | null;
}

/** What usp_Error_Capture returns, surfaced through POST /api/errors. */
export interface ErpErrorCaptureResult {
  errorReference: string | null;
  occurrenceId: number | null;
  fingerprintId: number | null;
  /** false when the problem is muted or the occurrence was sampled out. */
  shouldNotifyUser: boolean;
  /** Non-null when an auto-ticket rule fired or an open ticket already existed. */
  autoTicketNumber: string | null;
  isKnownIssue: boolean;
}

export interface ErpTicketCreateRequest {
  errorReference: string;
  userDescription?: string | null;
}

export interface ErpTicketCreateResult {
  ticketNumber: string;
  ticketId: number;
  /** true when the report attached to an existing open ticket for the same problem. */
  wasDeduplicated: boolean;
}

export interface ErpTicketSummary {
  ticketNumber: string;
  title: string;
  statusCode: string;
  statusName: string;
  isOpen: boolean;
  severityName: string;
  createdUtc: string;
  resolvedUtc?: string | null;
  closedUtc?: string | null;
  erpModule?: string | null;
  latestUpdate?: string | null;
}

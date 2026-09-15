import { Injectable, inject } from '@angular/core';
import { AbstractControl, FormArray, FormGroup } from '@angular/forms';
import { ErpErrorReporterService } from '../capture/erp-error-reporter.service';
import { ErpErrorContextService } from '../core/erp-error-context.service';
import { ErpValidationErrorItem } from '../models/error-envelope';

/**
 * Form, LOV and submit-action capture.
 *
 * These three are the only categories in the brief that are NOT exceptions.  A
 * form that fails validation does not throw; a LOV that returns an empty list
 * does not throw; a Save button that is disabled because a rule was not met
 * does not throw.  So there is nothing for the global ErrorHandler to catch, and
 * the brief still asks for them.
 *
 * The compromise, and I want to be explicit about it because it is the one
 * place the framework is not fully automatic: capturing a validation failure
 * requires ONE call at the point of submit.  Not per field, not per form - one
 * line in whatever base class or shared submit handler the ERP already has:
 *
 *     if (this.form.invalid) {
 *       this.formErrors.reportInvalidForm(this.form, 'PurchaseOrderHeader');
 *       return;
 *     }
 *
 * If the ERP has a common base component or a shared save() helper - most
 * in-house ERPs do - that single line covers every form in the system.
 *
 * Validation captures are severity 'low' and never raise a dialog.  They exist
 * so that "which field do our users fail most often, on which screen" is a
 * query rather than a guess.  That is worth having; interrupting the user over
 * their own typo is not.
 */
@Injectable({ providedIn: 'root' })
export class ErpFormErrorService {
  private readonly reporter = inject(ErpErrorReporterService);
  private readonly context = inject(ErpErrorContextService);

  /**
   * Record a failed form submission.  Returns the flattened error list so the
   * caller can also use it to drive its own UI if it wants.
   */
  reportInvalidForm(form: FormGroup, formName: string, actionName = 'submit'): ErpValidationErrorItem[] {
    const errors = collectErrors(form);

    this.context.addBreadcrumb({
      kind: 'form',
      message: `${formName}: ${errors.length} validation error(s) on ${actionName}`,
    });

    void this.reporter.report(new Error(`Validation failed on ${formName} (${errors.length} field(s))`), {
      category: 'validation',
      formName,
      actionName,
      validationErrors: errors,
      silent: true,
    });

    return errors;
  }

  /** A submit/save action that failed for a reason other than validation. */
  reportSubmitFailure(error: unknown, formName: string, actionName: string): void {
    this.context.addBreadcrumb({ kind: 'form', message: `${formName}: ${actionName} failed` });
    void this.reporter.report(error, { category: 'submit_action', formName, actionName });
  }

  /**
   * A List of Values failed to load or resolve.
   *
   * `resolvedCount === 0` on a lookup the user selected from is a real fault -
   * it means the LOV and the record it is validating against disagree, which in
   * an ERP usually means a data or permission problem, not a user error.
   */
  reportLovFailure(
    error: unknown,
    lovName: string,
    detail?: { requestedCode?: string | null; resolvedCount?: number | null },
  ): void {
    this.context.addBreadcrumb({ kind: 'lov', message: `LOV ${lovName} failed` });
    void this.reporter.report(error, {
      category: 'lov_lookup',
      lovName,
      customData: detail
        ? {
            // The code itself is a business key, not personal data, and it is
            // the single most useful thing for reproducing a LOV fault.
            requestedCode: detail.requestedCode ?? null,
            resolvedCount: detail.resolvedCount ?? null,
          }
        : null,
    });
  }

  /** Manual report from anywhere, for cases the automatic hooks cannot see. */
  report(error: unknown, options?: { component?: string; actionName?: string }): void {
    void this.reporter.report(error, options);
  }
}

/**
 * Flatten a form tree into control-path + failing-rule pairs.
 *
 * The VALUE is never included.  For `required` there is nothing to include; for
 * `maxlength` we keep the validator's own metadata (the limit and the actual
 * length) but not the text.  That is enough to diagnose and impossible to leak
 * a national ID with.
 */
export function collectErrors(
  control: AbstractControl,
  path = '',
  out: ErpValidationErrorItem[] = [],
): ErpValidationErrorItem[] {
  if (control.errors) {
    for (const [rule, detail] of Object.entries(control.errors)) {
      out.push({
        control: path || '(root)',
        rule,
        detail: sanitiseValidatorDetail(rule, detail),
      });
    }
  }

  if (control instanceof FormGroup) {
    for (const [name, child] of Object.entries(control.controls)) {
      collectErrors(child, path ? `${path}.${name}` : name, out);
    }
  } else if (control instanceof FormArray) {
    control.controls.forEach((child, i) => collectErrors(child, `${path}[${i}]`, out));
  }

  return out;
}

function sanitiseValidatorDetail(rule: string, detail: unknown): Record<string, unknown> | undefined {
  if (detail === null || detail === undefined || detail === true) return undefined;
  if (typeof detail !== 'object') return undefined;

  const d = detail as Record<string, unknown>;

  switch (rule) {
    case 'minlength':
    case 'maxlength':
      return { requiredLength: d['requiredLength'], actualLength: d['actualLength'] };
    case 'min':
    case 'max':
      // Numeric bounds on an ERP form are quantities and limits, not secrets.
      return { [rule]: d[rule], actual: d['actual'] };
    case 'pattern':
      return { requiredPattern: d['requiredPattern'] };
    default:
      // An unknown custom validator may put anything in here, including the
      // rejected value.  Record only that it fired.
      return undefined;
  }
}

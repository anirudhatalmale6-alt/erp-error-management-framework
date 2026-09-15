import { Routes } from '@angular/router';

/**
 * Note the `erpErrorContext` on each route.  That one line per route - in a
 * file the ERP already maintains - is how every error raised anywhere under
 * that route gets stamped with its ERP module and screen, without a single
 * component knowing the error framework exists.
 */
export const routes: Routes = [
  { path: '', redirectTo: 'purchase-order', pathMatch: 'full' },
  {
    path: 'purchase-order',
    loadComponent: () => import('./pages/purchase-order.page').then((m) => m.PurchaseOrderPage),
    data: { erpErrorContext: { module: 'MM', screen: 'Purchase Order Entry' } },
  },
  {
    path: 'admin',
    loadComponent: () => import('./pages/admin.page').then((m) => m.AdminPage),
    data: { erpErrorContext: { module: 'SYS', screen: 'Error Management Console' } },
  },
  {
    path: 'my-issues',
    loadComponent: () => import('./pages/my-issues.page').then((m) => m.MyIssuesPage),
    data: { erpErrorContext: { module: 'SYS', screen: 'My Issues' } },
  },
];

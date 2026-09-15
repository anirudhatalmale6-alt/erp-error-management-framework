import { Component } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive],
  template: `
    <header class="topbar">
      <div class="brand">
        <span class="mark">EM</span>
        <div>
          <strong>ERP Error Management Framework</strong>
          <span>Angular 20 &middot; ASP.NET Web API 2 / .NET 8 &middot; SQL Server</span>
        </div>
      </div>
      <nav>
        <a routerLink="/purchase-order" routerLinkActive="active">Purchase Order</a>
        <a routerLink="/admin" routerLinkActive="active">Support console</a>
        <a routerLink="/my-issues" routerLinkActive="active">My issues</a>
      </nav>
    </header>
    <main><router-outlet /></main>
  `,
  styles: [`
    :host { display: block; min-height: 100vh; background: #f5f7fa; }
    .topbar {
      display: flex; justify-content: space-between; align-items: center;
      background: #1f2329; color: #fff; padding: 12px 22px;
    }
    .brand { display: flex; gap: 11px; align-items: center; }
    .mark {
      display: grid; place-items: center; width: 32px; height: 32px; border-radius: 7px;
      background: #2d5bd7; font-weight: 800; font-size: 12px; letter-spacing: .04em;
    }
    .brand div { display: grid; }
    .brand strong { font-size: 14px; }
    .brand span { font-size: 11px; color: #98a2b3; }
    nav { display: flex; gap: 4px; }
    nav a {
      color: #cfd6de; text-decoration: none; font-size: 13px; font-weight: 600;
      padding: 7px 13px; border-radius: 7px;
    }
    nav a:hover { background: #2b3038; color: #fff; }
    nav a.active { background: #fff; color: #1f2329; }
    main { padding: 18px 22px 40px; max-width: 1400px; margin: 0 auto; }
  `],
})
export class App {}

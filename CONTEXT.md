# LDT v6.0 — Project Context & Guardrails

> This file is the single source of truth for the LDT project.
> Every developer, AI assistant, and contributor must read this before making any changes.
> Last updated: 2026-02-19

---

## 1. Project Overview

| Field | Value |
|-------|-------|
| **Name** | Laptop Diagnostic Toolkit (LDT) |
| **Version** | 6.0.0 |
| **Purpose** | USB-portable diagnostic and repair automation for Lenovo ThinkPad fleets |
| **Users** | IT technicians, field engineers, fleet managers (limited developer experience) |
| **Platform** | Windows 10/11 on Lenovo ThinkPad hardware |
| **Deployment** | USB drive (8GB+), fully offline, zero installation on target machine |
| **Core Script** | `Laptop_Diagnostic_Suite.ps1` (378KB, PowerShell) |
| **Launcher** | `Laptop_Master_Diagnostic.bat` (right-click → Run as Administrator) |
| **Config** | `Config\config.ini` (23 sections, 200+ tuneable parameters) |
| **Modules** | 45 diagnostic/repair modules across 8 categories, 48 menu options |

---

## 2. Architecture Rules (Non-Negotiable)

These rules define what LDT is. Violating any of these breaks the product.

| # | Rule | Reason |
|---|------|--------|
| 1 | **Fully offline** — zero internet dependencies at runtime | Technicians work in environments with no network access |
| 2 | **USB-portable** — everything runs from USB, nothing installed on target | Target machines may be unstable, infected, or pre-deployment |
| 3 | **Single entry point** — `Laptop_Master_Diagnostic.bat` is the only file users touch | Simplicity for non-technical users |
| 4 | **Self-contained** — all tools, fonts, configs, docs ship on the USB | No external downloads, no CDNs, no package managers at runtime |
| 5 | **Config-driven** — all thresholds live in `config.ini`, not hardcoded | Fleet managers customize without editing code |
| 6 | **Non-destructive by default** — Tier 1 (auto) fixes are safe; Tier 2 (guided) requires Y/N confirmation | Prevent accidental damage to production machines |
| 7 | **Audit trail** — every run produces timestamped logs + HTML reports on USB | Compliance, ITSM integration, management reporting |
| 8 | **No frameworks** — vanilla PowerShell for scripts, vanilla JS/CSS for docs | No Node.js, no React, no Python, no build tools required on USB |

---

## 3. File Structure

```
E:\LDT-v6.0\
├── Laptop_Master_Diagnostic.bat    ← Launcher (user entry point, options 0-49)
├── Laptop_Diagnostic_Suite.ps1     ← Core engine (45 modules)
├── Team_Issue_Detector.ps1         ← Option 49: BSOD + Reset + VPN detector + auto-fix
├── config.ini                      ← Root config (copy of Config\config.ini)
├── CONTEXT.md                      ← THIS FILE
├── Config\
│   └── config.ini                  ← Master configuration (23 sections)
├── Docs\
│   ├── fonts\                      ← Bebas Neue, DM Sans, JetBrains Mono (woff2)
│   ├── LDT_Step_by_Step_Guide.html ← Visual step-by-step guide (v1.0)
│   ├── Laptop_Toolkit_v6_Team_Guide.html
│   └── Laptop_Toolkit_v6_Team_Guide.pdf
├── Tools\
│   ├── CPU-Z\
│   ├── LenovoThinInstaller\
│   └── VPNInstaller\
├── Logs\                           ← Auto-generated per-session logs
├── Reports\                        ← Auto-generated HTML reports
├── Results\                        ← Fleet CSV exports
├── Temp\                           ← Working directory (cleared between runs)
├── Backups\                        ← Restore points before repairs
└── Data\                           ← Reference data files
```

---

## 4. Design System (Documentation Files)

All documentation HTML files (guides, reports) must follow these tokens.

### Colors
| Token | Value | Usage |
|-------|-------|-------|
| `--red` | `#E2231A` | Lenovo brand red, alerts, escalation |
| `--dark` | `#0A0F1A` | Page background |
| `--navy` | `#0F1E35` | Card deep background |
| `--navy2` | `#162840` | Secondary dark surface |
| `--blue` | `#1A5DCC` | Primary accent, links, active states |
| `--blue-light` | `#4A8BEF` | Highlights, nav active, focus outlines |
| `--green` | `#00C875` | Success, auto-fix, pass states |
| `--amber` | `#F59E0B` | Warnings, guided actions |
| `--white` | `#F5F7FA` | Primary text |
| `--muted` | `#7A8BA8` | Secondary text, labels |
| `--border` | `rgba(255,255,255,0.07)` | Card borders |
| `--card` | `rgba(255,255,255,0.04)` | Card backgrounds |
| `--glass-bg` | `rgba(255,255,255,0.04)` | Glassmorphism background |
| `--glass-border` | `rgba(255,255,255,0.08)` | Glassmorphism border |
| `--glass-blur` | `12px` | Backdrop blur radius |

### Typography
| Element | Font | Weight | Size |
|---------|------|--------|------|
| Headings (h1, titles) | Bebas Neue | 400 | clamp(52px, 8vw, 100px) |
| Section titles | Bebas Neue | 400 | 36px |
| Body text | DM Sans | 300–400 | 14–15px |
| Code, labels, badges | JetBrains Mono | 400–600 | 10–12px |

### Interaction Standards
| Element | Hover Effect |
|---------|-------------|
| Cards (step, achieve) | translateY(-4px) or translateX(4px) + glow shadow |
| Pills | scale(1.05) + color-matched glow |
| Badges | scale(1.06) |
| Step numbers | scale(1.08) |
| All transitions | `cubic-bezier(0.16, 1, 0.3, 1)` at 0.3s |

---

## 5. Coding Standards

### PowerShell (`.ps1` scripts)
- Target PowerShell 5.1 (ships with Windows 10/11)
- No external modules — use only built-in cmdlets
- All file paths relative to USB root (detect drive letter at runtime)
- Every module must: (1) log start/end, (2) handle errors gracefully, (3) save output to Logs\ and Reports\
- Read all thresholds from `config.ini` — never hardcode values
- Tier 1 auto-fix: no user prompt needed
- Tier 2 guided-fix: always prompt Y/N before applying
- Tier 3 escalation: report only, never attempt physical fixes

### Batch (`.bat` launcher)
- Keep minimal — launcher only, no business logic
- Auto-detect USB drive letter
- Auto-elevate to Administrator if not already
- Pass control to PowerShell script immediately

### HTML/CSS/JS (documentation files)
- Single self-contained HTML file (embedded CSS + inline JS)
- Zero external dependencies (no CDNs, no imports, no fetch calls)
- Fonts loaded from local `fonts/` folder (woff2 format)
- Vanilla JavaScript only — no frameworks, no libraries
- CSS custom properties (variables) for all colors and spacing
- Must work fully offline when opened from USB
- Must include `@media print` stylesheet
- Must include `@media (prefers-reduced-motion: reduce)`
- Must include semantic HTML (`<header>`, `<main>`, `<footer>`, `<nav>`)
- Must include skip-link and focus-visible outlines

---

## 6. Guardrails — What We NEVER Do

| # | Never | Why |
|---|-------|-----|
| 1 | Never add internet-dependent features to the core toolkit | Breaks offline requirement |
| 2 | Never auto-fix BIOS, firmware, or GPU drivers without user confirmation | Risk of bricking hardware |
| 3 | Never collect or transmit user personal data | Privacy, GDPR, trust |
| 4 | Never require software installation on the target machine | Core product promise |
| 5 | Never use frameworks (React, Node, Python) in shipped files | USB simplicity, no runtime dependencies |
| 6 | Never hardcode thresholds — always read from config.ini | Fleet managers need customization |
| 7 | Never overwrite previous logs/reports — always use timestamps | Audit trail integrity |
| 8 | Never run destructive operations without creating a restore point first | Safety net for repairs |
| 9 | Never make cosmetic changes that hurt readability or usability | Enterprise tool, not a portfolio piece |
| 10 | Never ship without testing on a real Lenovo ThinkPad | Simulator ≠ reality |

---

## 7. Decision Log

Documenting WHY we made key choices. Future contributors: read this before questioning decisions.

| Date | Decision | Alternatives Considered | Why We Chose This |
|------|----------|------------------------|-------------------|
| 2026-02-13 | PowerShell 5.1 as core engine | Python, Node.js, C# | Ships with every Windows 10/11 machine. Zero install. |
| 2026-02-13 | Single .ps1 file (378KB) | Multiple module files | Simpler USB deployment. One file to manage. |
| 2026-02-13 | INI config format | JSON, YAML, XML | Non-developers can edit INI in Notepad. No parsing complexity. |
| 2026-02-13 | BAT launcher → PowerShell | Direct .ps1 execution | BAT handles admin elevation reliably. Double-click friendly. |
| 2026-02-19 | Single-file HTML docs (embedded CSS/JS) | Separate files, static site generator | Offline USB portability. No build step. Open in any browser. |
| 2026-02-19 | Glassmorphism + dark theme for docs | Light theme, minimal design | Enterprise-grade appearance. Matches modern IT tooling aesthetic. |
| 2026-02-19 | IntersectionObserver for scroll animations | Fire-on-load animations | Performance. Elements animate when visible, not all at page load. |
| 2026-02-19 | 4 responsive breakpoints (480/768/1024/1440) | Single 768px breakpoint | Real-world: technicians use tablets, phones, and large monitors. |
| 2026-02-19 | Vanilla JS (~80 lines) for interactivity | No JS, jQuery, Alpine.js | Minimal footprint. No dependencies. Progressive enhancement. |
| 2026-02-19 | Team Issue Detector as standalone PS1 | Add to main 378KB PS1, or Node script | Separate PS1 is lower risk — no touching the core engine. Same parameter conventions. |
| 2026-02-19 | Detect + Auto-Fix (not detect-only) | Detect only, Detect + Recommend | Full value — one script scans AND fixes. Technician runs once, walks away. |
| 2026-02-19 | Option 49 in BAT menu (not standalone) | Standalone script, Part of Option 1 | Consistent UX — technicians already know the menu. One entry point. |

---

## 8. Version History

| Version | Date | What Changed |
|---------|------|-------------|
| 6.0.0 | 2026-02-13 | Initial LDT v6.0 — 45 modules, 8 categories, config.ini, BAT launcher |
| docs-1.0 | 2026-02-19 | Step-by-Step Guide: 12 enterprise visual enhancements (glassmorphism, nav, accessibility, responsive, print, scroll animations, footer, progress bar, back-to-top) |
| detect-1.0 | 2026-02-19 | Team Issue Detector (Option 49): BSOD + Reset + VPN detection, terminal output, HTML report, auto-fix launcher. New file: Team_Issue_Detector.ps1. BAT updated with Option 49. |

---

## 9. Testing Checklist

Before deploying any change, manually verify ALL of the following.

### PowerShell Script (`Laptop_Diagnostic_Suite.ps1`)
- [ ] Launches via BAT file with admin elevation
- [ ] Detects USB drive letter correctly
- [ ] Menu displays all 48 options
- [ ] At least 3 different options run without error
- [ ] Logs created in `Logs\` with correct timestamp
- [ ] HTML report created in `Reports\` and opens in browser
- [ ] Config values from `config.ini` are respected (change one, verify)
- [ ] Runs fully offline (disconnect Wi-Fi, test)

### Documentation HTML Files
- [ ] Opens in Chrome from USB drive (file:// protocol)
- [ ] All fonts load (Bebas Neue, DM Sans, JetBrains Mono)
- [ ] Sticky nav appears on scroll
- [ ] Nav links scroll to correct sections
- [ ] Back-to-top button appears after scrolling
- [ ] Scroll progress bar tracks position
- [ ] Resize to 480px — mobile layout works
- [ ] Resize to 768px — tablet layout works
- [ ] Resize to 1440px+ — wide layout works
- [ ] Ctrl+P — print preview shows clean white layout, no nav/progress/back-to-top
- [ ] Tab through page — skip-link appears, focus outlines visible
- [ ] No console errors in DevTools

---

## 10. Deployment Process

### Current Process (Manual)
1. Make changes to files on development machine
2. Run through Testing Checklist (Section 9)
3. Update Version History (Section 8 of this file)
4. Copy changed files to USB drive (`E:\LDT-v6.0\`)
5. Verify files on USB with hash comparison
6. Test from USB on a real Lenovo ThinkPad

### File Locations (Keep in Sync)
| File | Development Location | USB Location |
|------|---------------------|-------------|
| Step-by-Step Guide | `C:\Users\LENOVO\Downloads\LDT_Step_by_Step_Guide.html` | `E:\LDT-v6.0\Docs\LDT_Step_by_Step_Guide.html` |
| Core Script | — | `E:\LDT-v6.0\Laptop_Diagnostic_Suite.ps1` |
| Config | — | `E:\LDT-v6.0\Config\config.ini` |

### Future Process (Target)
1. All files in a Git repository
2. Changes made on a branch
3. Testing checklist completed
4. Version bumped in config.ini + CONTEXT.md
5. Merge to main
6. Build script copies to USB + verifies hashes
7. Test from USB on real hardware

---

## 11. Roadmap — What's Next

### Completed
| # | Item | Status | Type |
|---|------|--------|------|
| 1 | Issue Detector Script (BSOD, Reset, VPN) | DONE — Option 49, detect + auto-fix, terminal + HTML | New feature |

### Agreed / In Discussion
| # | Item | Status | Type |
|---|------|--------|------|
| 2 | Initialize Git repository | Agreed — not yet done | Process |
| 3 | Add version number to HTML guide footer | Agreed — not yet done | Quick fix |
| 4 | Test Issue Detector on laptop with known issues | Needed — validate detection accuracy | Testing |

---

## 12. Team Context

- We are a **startup** with limited developer experience
- Technicians using the tool are **non-technical** — they follow steps, not debug code
- USB-first deployment is a hard business requirement (not all sites have network)
- The tool must work on **any Lenovo ThinkPad running Windows 10 or 11**
- Config customization is important — different clients have different thresholds
- Professional reporting matters — reports are shown to management and filed in ITSM systems

---

## 13. AI Assistant Instructions

When working on this project with Claude Code or any AI assistant:

1. **Read this file first** before making any changes
2. **Never break offline capability** — no CDN links, no fetch(), no external URLs
3. **Never add frameworks** — vanilla only (PS, JS, CSS, HTML)
4. **Always preserve existing content** — design changes must not alter text/data
5. **Always deploy to both locations** — development + USB
6. **Always verify with hash comparison** after deployment
7. **Update the Version History** in this file after every change
8. **Follow the Design System** (Section 4) for any new HTML/CSS work
9. **Follow the Coding Standards** (Section 5) for any code changes
10. **Run the Testing Checklist** (Section 9) or remind the user to do so

# Website

The official TaskMenu site is static HTML served from this directory. Keep the
homepage dependency-free and preserve the existing public routes.

- `index.html` — product homepage, real app tour, download and installation.
- `styles.css` — responsive homepage layout and accessible interaction styles.
- `tokens.css` — homepage color, typography, spacing, and motion tokens.
- `assets/` — app icon and content-only app screenshots captured with
  `--testing-window --capture list|task`; preserve transparency when cropping
  the reported titlebar, and never use a real account's tasks. `assets/fonts/`
  contains self-hosted Geist and Bricolage Grotesque with their OFL licenses.
- `privacy.html`, `terms.html`, `support.html` — existing policy/support pages.
- `RELEASING.md` — app distribution and signing guide.
- `.hallmark/` — homepage design findings and history.

Preview from the repository root with `python3 -m http.server 8765 --directory docs`
and open `http://localhost:8765/`. Check 320, 375, 414, 768, and desktop widths,
keyboard focus, installation disclosure, and asset loading after changes.

The homepage uses no JavaScript, analytics, or third-party font requests. The
direct-download links point to the latest GitHub release; do not hardcode a
version. Both download areas also link to TaskMenu on the Mac App Store.

"""Renderiza POSTMORTEM.md a PDF (A4) con pandoc + Chromium (Playwright). Uso: python tools/render_pdf.py"""
import subprocess, sys
from pathlib import Path
from playwright.sync_api import sync_playwright
root = Path(__file__).resolve().parents[1]
html = root / "salidas" / "POSTMORTEM.html"
subprocess.run(["pandoc", str(root / "POSTMORTEM.md"), "-s", "--embed-resources", "--resource-path", str(root),
                "-c", str(root / "tools" / "style.css"), "-o", str(html), "--metadata", "lang=es"], check=True)
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(); pg.goto(html.as_uri())
    pg.pdf(path=str(root / "POSTMORTEM.pdf"), format="A4", prefer_css_page_size=True, print_background=True)
    b.close()
print("ok", root / "POSTMORTEM.pdf")

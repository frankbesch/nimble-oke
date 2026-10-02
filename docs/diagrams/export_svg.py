#!/usr/bin/env python3
"""Export a fixed-theme SVG from a delivered Archify HTML page.

Usage: export_svg.py <in.html> <light|dark> <out.svg> [--keep-fonts]
Runs the page's own SVG export in headless Chrome and captures the result.
Embedded font files are dropped unless --keep-fonts is given, so the SVG
falls back to the reader's monospace font.
"""
import html, re, subprocess, sys, tempfile, pathlib
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
src, theme, out = sys.argv[1:4]
h = pathlib.Path(src).read_text()
n = 0
def sub(a, b):
    global h, n
    assert a in h, a
    h = h.replace(a, b); n += 1
sub("window.matchMedia('(prefers-color-scheme: light)').matches", "true" if theme == "light" else "false")
sub("serializeSvg(1, { autoTheme: true })", "serializeSvg(1, {})")
sub("download(blob, base + '.svg');",
    "blob.text().then(function(t){var p=document.createElement('pre');p.id='svg-out';p.textContent=t;document.body.appendChild(p);});")
sub("</body>", "<script>window.addEventListener('load',function(){setTimeout(function(){"
    "document.querySelector('.export-menu button[data-format=\"svg\"]').click();},400);});</script></body>")
with tempfile.TemporaryDirectory() as d:
    f = pathlib.Path(d) / "x.html"; f.write_text(h)
    dom = subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--virtual-time-budget=6000",
                          "--dump-dom", f"file://{f}"], capture_output=True, text=True).stdout
m = re.search(r'<pre id="svg-out">(.*?)</pre>', dom, re.S)
assert m, "export did not run"
svg = html.unescape(m.group(1))
if "--keep-fonts" not in sys.argv:
    svg = re.sub(r"@font-face\s*\{[^}]*\}", "", svg)
pathlib.Path(out).write_text(svg)
print(pathlib.Path(out).name, len(svg), "bytes")

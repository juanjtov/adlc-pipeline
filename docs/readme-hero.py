#!/usr/bin/env python3
"""README hero image — generator.

Builds docs/readme-hero-dark.png, the image the README shows, from an HTML layout and a capture of
Mission Control. A light variant exists for other uses (--theme light); the README always shows the dark one.

Run:   python3 docs/readme-hero.py              # re-render the dark hero from the stored capture
       python3 docs/readme-hero.py --capture    # first refresh docs/readme-hero-mc.png from a running
                                                #   demo server (adlc-mission-control --demo), then render
Needs: pip install playwright pillow && python3 -m playwright install chromium (once). Rendering
loads the Inter font from Google Fonts; offline it falls back to the system sans.

Every sentence in the picture is a claim about the plugin. Check it against the code and the
explainer (docs/adlc-pipeline-explained.md) before changing it; say "may not", not "never can".
"""
import argparse, asyncio, base64, io, os, sys
from playwright.async_api import async_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
MC = os.path.join(HERE, "readme-hero-mc.png")
W, H = 1280, 924              # canvas; GitHub shows it at about 900px wide, so type is sized for that
DEMO_URL = "http://localhost:4319/?demo=1"
CAPTURE_VIEWPORT = (1440, 900)                 # at 2x
LINE_CROP = (43, 137, 2837, 936)               # the "Assembly line" panel inside that capture

# station colours: Mission Control's default "Cool revival" palette, light set (mission-control/web/styles.css),
# so the numbered circles match the stations in the capture below them
COL = dict(request="#526C7A", analyst="#00A870", architect="#0090DB", builder="#00B53A", reviewer="#5560E6", qa="#00A8B8")

THEMES = {
    "light": dict(bg="linear-gradient(180deg,#FFFFFF 0%,#F1F7FA 100%)", eyebrow="#0090DB", h1="#06202B", p="#3F5866",
                  rail="#D6E4EC", ring="#FFFFFF", name="#06202B", desc="#526C7A", gate="#7A4E00", gatebg="#FAB219",
                  shadow="0 2px 8px rgba(6,32,43,.14)", frame="rgba(6,32,43,.12)", frameshadow="0 30px 80px -30px rgba(6,32,43,.45)",
                  cap="#3F5866", capb="#06202B"),
    "dark":  dict(bg="linear-gradient(180deg,#0A1A26 0%,#061018 100%)", eyebrow="#5FB8D6", h1="#F4FCFF", p="#A6C6D4",
                  rail="#1B3545", ring="#0A1A26", name="#EAFBFF", desc="#8FB0BE", gate="#FFD56A", gatebg="#FAB219",
                  shadow="0 2px 10px rgba(0,0,0,.5)", frame="rgba(160,230,255,.14)", frameshadow="0 30px 80px -30px rgba(0,0,0,.9)",
                  cap="#A6C6D4", capb="#F4FCFF"),
}

STEPS = [("1", "Request",   "an idea, a PRD or a ticket becomes one GitHub issue",   COL["request"]),
         ("2", "Analyst",   "user stories with pass/fail checks, plus a lane",        COL["analyst"]),
         (None, "Gate 1",   "you approve the plan and pick the lane, or opt in to autopilot", None),
         ("3", "Architect", "design record and the files each task may touch",        COL["architect"]),
         ("4", "Builder",   "code and a test per check, on its own branch",           COL["builder"]),
         ("5", "Review",    "one agent tries to break it, one checks the design",     COL["reviewer"]),
         ("6", "QA",        "full test suite, security pass, action card",            COL["qa"]),
         (None, "Gate 2",   "you merge and deploy. Agents may not.",                   None)]

PERSON = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#3D2800" stroke-width="2.4" stroke-linecap="round"><circle cx="12" cy="8" r="4"/><path d="M4.5 21a7.5 7.5 0 0 1 15 0"/></svg>'

def html(t):
    steps = "".join(
        f'<div class="step gate"><div class="n">{PERSON}</div><b>{name}</b><span>{d}</span></div>' if n is None else
        f'<div class="step"><div class="n" style="background:{col}">{n}</div><b>{name}</b><span>{d}</span></div>'
        for n, name, d, col in STEPS)
    return f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
*{{box-sizing:border-box;margin:0;padding:0}} html,body{{background:transparent}}
body{{font-family:Inter,-apple-system,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}}
.hero{{position:relative;width:{W}px;height:{H}px;overflow:hidden;background:{t['bg']}}}
.head{{position:absolute;left:0;right:0;top:54px;text-align:center}}
.eyebrow{{font-size:12px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;color:{t['eyebrow']}}}
h1{{margin:16px auto 0;font-size:40px;line-height:1.1;font-weight:800;letter-spacing:-.035em;color:{t['h1']};max-width:860px}}
.head p{{margin:16px auto 0;font-size:17px;line-height:1.5;color:{t['p']};max-width:680px}}
.steps{{position:absolute;left:44px;right:44px;top:272px;display:flex;justify-content:space-between}}
.steps:before{{content:"";position:absolute;left:24px;right:24px;top:20px;height:2px;background:{t['rail']}}}
.step{{position:relative;width:148px;text-align:center}}
.step .n{{width:40px;height:40px;border-radius:50%;margin:0 auto;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:15px;color:#fff;border:4px solid {t['ring']};box-shadow:{t['shadow']}}}
.step.gate .n{{border-radius:13px;background:{t['gatebg']};width:46px;height:46px;margin-top:-3px}}
.step b{{display:block;margin-top:13px;font-size:15px;font-weight:700;color:{t['name']};letter-spacing:-.01em}}
.step.gate b{{color:{t['gate']}}}
.step span{{display:block;margin-top:5px;font-size:14px;line-height:1.38;color:{t['desc']};padding:0 2px}}
.fast{{position:absolute;left:0;right:0;top:418px;text-align:center;font-size:14px;color:{t['desc']}}}
.fast i{{display:inline-block;width:30px;border-top:2px dashed #FAB219;vertical-align:middle;margin-right:10px}}
.fast b{{color:{t['name']};font-weight:700}}
.mc{{position:absolute;left:0;right:0;top:476px;text-align:center}}
.mc .cap{{font-size:14px;color:{t['cap']};font-weight:500;max-width:1000px;margin:0 auto;line-height:1.4}}
.mc .cap b{{color:{t['capb']};font-weight:700}}
.frame{{width:1180px;margin:16px auto 0;border-radius:14px;overflow:hidden;background:#061018;border:1px solid {t['frame']};box-shadow:{t['frameshadow']}}}
.bar{{height:32px;display:flex;align-items:center;gap:8px;padding:0 14px;background:#0B1720}}
.bar i{{width:10px;height:10px;border-radius:50%;display:block}}
.bar i:nth-child(1){{background:#FF5F57}}.bar i:nth-child(2){{background:#FEBC2E}}.bar i:nth-child(3){{background:#28C840}}
.bar span{{margin:0 auto;font-size:11.5px;color:#7FA0AE;font-weight:500}}
.frame img{{display:block;width:100%}}
</style></head><body><div class="hero" id="hero">
<div class="head"><div class="eyebrow">ADLC Pipeline · a Claude Code plugin</div>
<h1>An AI delivery team for any codebase, with you at the two gates that matter.</h1>
<p>A team of AI agents turns a request into a reviewed, tested pull request. Agents carry work up to a gate, never through it.</p></div>
<div class="steps">{steps}</div>
<div class="fast"><i></i>Small, low-risk fixes you approve take a <b>fast lane</b>: Builder, a size check and one reviewer, then straight to Gate 2.</div>
<div class="mc"><div class="cap"><b>Mission Control</b> · a live, read-only view of the line on your own machine: where each request is, what each agent on this machine is doing and, with telemetry on, what it costs.</div>
<div class="frame"><div class="bar"><i></i><i></i><i></i><span>Mission Control · localhost:4319 · demo data</span></div><img src="{mc_uri()}"></div></div>
</div></body></html>"""

def mc_uri():
    with open(MC, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")

async def capture(b):
    from PIL import Image
    ctx = await b.new_context(viewport=dict(width=CAPTURE_VIEWPORT[0], height=CAPTURE_VIEWPORT[1]), device_scale_factor=2)
    pg = await ctx.new_page(); await pg.goto(DEMO_URL); await pg.wait_for_timeout(3500)
    png = await pg.screenshot(); await ctx.close()
    Image.open(io.BytesIO(png)).crop(LINE_CROP).save(MC); print("captured", MC)

async def main(do_capture, themes):
    async with async_playwright() as p:
        b = await p.chromium.launch()
        if do_capture: await capture(b)
        for name in themes:
            t = THEMES[name]
            pg = await b.new_page(viewport=dict(width=W, height=H), device_scale_factor=2)
            await pg.set_content(html(t), wait_until="load")
            await pg.evaluate("document.fonts.ready")
            if not await pg.evaluate('document.fonts.check("800 40px Inter")'):
                sys.exit("Inter did not load (offline?); the layout would rewrap. Connect and run again.")
            out = os.path.join(HERE, f"readme-hero-{name}.png")
            await (await pg.query_selector("#hero")).screenshot(path=out)
            await pg.close(); print("wrote", out)
        await b.close()

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--capture", action="store_true", help="refresh docs/readme-hero-mc.png from a running demo server first")
    ap.add_argument("--theme", choices=["dark", "light", "all"], default="dark", help="which variant to render (default: dark, the one the README shows)")
    a = ap.parse_args()
    asyncio.run(main(a.capture, list(THEMES) if a.theme == "all" else [a.theme]))

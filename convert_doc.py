#!/usr/bin/env python3
import re


def slugify(title):
        """GitHub-style anchor slug for a heading title."""
        slug = re.sub(r"[^a-z0-9\- ]", "", title.lower())
        return slug.replace(" ", "-")


def parse_inline(text):
        # Escape HTML special chars
        text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        # Temporary placeholder for code blocks to avoid conflict with other styles
        code_placeholders = []

        def code_repl(match):
                code_placeholders.append(match.group(1))
                return f"__CODE_PLACEHOLDER_{len(code_placeholders) - 1}__"

        text = re.sub(r"`([^`]+)`", code_repl, text)
        text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", text)
        # Inline markdown links (not images)
        text = re.sub(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)

        # Restore code blocks
        for i, code_val in enumerate(code_placeholders):
                text = text.replace(
                        f"__CODE_PLACEHOLDER_{i}__", f"<code>{code_val}</code>"
                )
        return text


def split_table_row(line):
        """Split a markdown table row on unescaped pipes.

        A backslash-escaped pipe (\\|) is a literal pipe inside the cell
        (GFM table rule), so it must not start a new column. A naive
        split("|") broke rows whose code spans contain '\\|'
        (e.g. `dmesg \\| grep ...`).
        """
        s = line.strip()
        parts = []
        cur = []
        i = 0
        while i < len(s):
                if s[i] == "\\" and i + 1 < len(s) and s[i + 1] == "|":
                        cur.append("|")
                        i += 2
                elif s[i] == "|":
                        parts.append("".join(cur).strip())
                        cur = []
                        i += 1
                else:
                        cur.append(s[i])
                        i += 1
        parts.append("".join(cur).strip())
        # Drop the empty entries produced by the leading/trailing pipes.
        if parts and parts[0] == "":
                parts = parts[1:]
        if parts and parts[-1] == "":
                parts = parts[:-1]
        return parts


def convert_md_to_html(md_path, html_path):
        try:
                with open(md_path, encoding="utf-8") as f:
                        md_content = f.read()
        except OSError as e:
                raise SystemExit(f"error: cannot read {md_path}: {e}") from e

        # Split into lines
        lines = md_content.splitlines()

        # We want to parse sections
        html_body = []
        toc_items = []

        # First, let's scan for headers to build a dynamic TOC
        step_num = 1
        for line in lines:
                if line.startswith("## "):
                        title = line[3:].strip()
                        s_id = slugify(title)
                        if "Prerequisites" in title:
                                toc_items.append((s_id, "•", "Prerequisites"))
                        elif "Platform Validation" in title:
                                toc_items.append((s_id, "•", "Platform Validation"))
                        elif "Step" in title:
                                # e.g., "Step 1 — Check host capabilities"
                                match = re.search(r"Step (\d+)\s*—\s*(.+)", title)
                                if match:
                                        s_text = match.group(2).strip()
                                        toc_items.append((s_id, match.group(1), s_text))
                                else:
                                        toc_items.append((s_id, str(step_num), title))
                                        step_num += 1
                        elif "Quick reference" in title:
                                toc_items.append((s_id, "★", "Quick reference"))
                        elif "Troubleshooting" in title:
                                toc_items.append((s_id, "!", "Troubleshooting"))
                        elif "Visual Overview" in title:
                                toc_items.append((s_id, "◈", "Visual Overview"))
                        elif "Glossary" in title:
                                toc_items.append((s_id, "Aa", "Glossary"))
                        elif "Appendix" in title:
                                toc_items.append((s_id, "§", "Appendix"))

        # State machine for rendering main content
        in_code = False
        code_lines = []

        in_table = False
        table_rows = []

        in_list = False
        list_type = None  # "ul" or "ol"
        list_items = []

        in_step = False
        in_contents = False

        # To parse paragraphs, callouts and blockquotes
        p_lines = []
        q_lines = []

        def flush_paragraph():
                nonlocal p_lines
                if not p_lines:
                        return
                text = " ".join(p_lines).strip()
                p_lines = []

                # Check if it's a callout or specific pattern
                if text.startswith("The whole process has two sides:"):
                        # Format as two sides callout
                        text_html = parse_inline(text)
                        html_body.append(
                                f'<div class="callout info">\n  <span class="tag">Two sides to this process</span>\n  {text_html}\n</div>\n'
                        )
                elif text.startswith("If BIOS TDX is off"):
                        text_html = parse_inline(text)
                        html_body.append(
                                f'<div class="callout warn">\n  <span class="tag">Warning</span>\n  {text_html}\n</div>\n'
                        )
                elif text.startswith("⚠️"):
                        text_html = parse_inline(text[1:].strip())
                        html_body.append(
                                f'<div class="callout warn">\n  <span class="tag">Warning</span>\n  {text_html}\n</div>\n'
                        )
                elif text.startswith(("Note:", "*Why", "- *Why")):
                        text_html = parse_inline(text)
                        html_body.append(
                                f'<div class="callout info">\n  {text_html}\n</div>\n'
                        )
                elif re.fullmatch(r"\*\*.+:\*\*", text):
                        # Standalone bold label line (e.g. a figure caption)
                        html_body.append(
                                f'<p class="caption">{parse_inline(text)}</p>\n'
                        )
                else:
                        text_html = parse_inline(text)
                        html_body.append(f"<p>{text_html}</p>\n")

        def flush_quote():
                nonlocal q_lines
                if not q_lines:
                        return
                text = " ".join(q_lines).strip()
                q_lines = []
                plain = text.replace("**", "")
                if plain.startswith("Note:"):
                        body = text
                        if body.startswith("**Note:**"):
                                body = body[len("**Note:**") :].strip()
                        html_body.append(
                                f'<div class="callout info">\n  <span class="tag">Note</span>\n  {parse_inline(body)}\n</div>\n'
                        )
                elif plain.startswith(("Warning", "⚠️")):
                        html_body.append(
                                f'<div class="callout warn">\n  <span class="tag">Warning</span>\n  {parse_inline(text)}\n</div>\n'
                        )
                else:
                        html_body.append(
                                f'<div class="callout info">\n  {parse_inline(text)}\n</div>\n'
                        )

        def flush_list():
                nonlocal in_list, list_type, list_items
                if not in_list:
                        return
                html_body.append(f"<{list_type}>\n")
                for item in list_items:
                        # Handle list item text and potential nested parts
                        item_parsed = parse_inline(item)
                        html_body.append(f"  <li>{item_parsed}</li>\n")
                html_body.append(f"</{list_type}>\n")
                list_items = []
                in_list = False
                list_type = None

        def flush_table():
                nonlocal in_table, table_rows
                if not in_table or not table_rows:
                        return
                html_body.append("<table>\n")

                # Check if first row is headers
                has_header = len(table_rows) > 1

                for idx, row in enumerate(table_rows):
                        # Row is list of columns
                        cols = [col.strip() for col in row]
                        if idx == 0 and has_header:
                                html_body.append("  <tr>")
                                for col in cols:
                                        html_body.append(
                                                f"<th>{parse_inline(col)}</th>"
                                        )
                                html_body.append("</tr>\n")
                        else:
                                html_body.append("  <tr>")
                                for col in cols:
                                        html_body.append(
                                                f"<td>{parse_inline(col)}</td>"
                                        )
                                html_body.append("</tr>\n")

                html_body.append("</table>\n")
                table_rows = []
                in_table = False

        # Hero and title parsing (at beginning of file)
        hero_title = "Intel TDX Attestation — Step-by-Step Guide"
        hero_desc = ""
        hero_images = []  # (alt, src) tuples found in the intro block

        def render_figure(alt, src):
                fig = f'<figure class="graph"><img src="{src}" alt="{alt}">'
                if alt:
                        fig += f"<figcaption>{parse_inline(alt)}</figcaption>"
                fig += "</figure>\n"
                return fig

        i = 0
        while i < len(lines):
                line = lines[i]

                # Blockquote handling (> lines become callouts)
                if line.strip().startswith(">"):
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        q_lines.append(re.sub(r"^>\s?", "", line.strip()))
                        i += 1
                        continue
                if q_lines:
                        flush_quote()

                # Skip the markdown Contents section (the sidebar TOC replaces it)
                if in_contents:
                        if line.startswith("## "):
                                in_contents = False
                        else:
                                i += 1
                                continue

                # Code block handling
                if line.strip().startswith("```"):
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        if in_code:
                                # End of code block
                                code_text = "\n".join(code_lines)
                                # If code text has box drawing characters, render as diagram
                                if any(char in code_text for char in "┌┐└┘├┤┼─│┬┴"):
                                        escaped_diagram = (
                                                code_text.replace("&", "&amp;")
                                                .replace("<", "&lt;")
                                                .replace(">", "&gt;")
                                        )
                                        html_body.append(
                                                f'<pre class="diagram">{escaped_diagram}</pre>\n'
                                        )
                                else:
                                        # Escape HTML in code blocks
                                        escaped_code = (
                                                code_text.replace("&", "&amp;")
                                                .replace("<", "&lt;")
                                                .replace(">", "&gt;")
                                        )
                                        html_body.append(f"<pre>{escaped_code}</pre>\n")
                                code_lines = []
                                in_code = False
                        else:
                                in_code = True
                        i += 1
                        continue

                if in_code:
                        code_lines.append(line)
                        i += 1
                        continue

                # Header 1 - Hero title
                if line.startswith("# "):
                        hero_title = line[2:].strip()
                        # The next non-empty paragraph will be the hero description
                        desc_lines = []
                        i += 1
                        while i < len(lines) and not lines[i].strip():
                                i += 1
                        while (
                                i < len(lines)
                                and lines[i].strip()
                                and not lines[i].startswith("##")
                                and not lines[i].startswith("#")
                        ):
                                img_m = re.match(
                                        r"^!\[([^\]]*)\]\(([^)]+)\)\s*$",
                                        lines[i].strip(),
                                )
                                if img_m:
                                        hero_images.append(img_m.groups())
                                else:
                                        desc_lines.append(lines[i].strip())
                                i += 1
                        hero_desc = " ".join(desc_lines)
                        continue

                # Header 2 - Section or Step
                if line.startswith("## "):
                        flush_paragraph()
                        flush_list()
                        flush_table()

                        title = line[3:].strip()
                        h2_id = slugify(title)

                        if in_step:
                                html_body.append("</div>\n\n")
                                in_step = False

                        if title == "Contents":
                                in_contents = True
                                i += 1
                                continue
                        elif "Prerequisites" in title:
                                html_body.append(
                                        f'<h2 id="{h2_id}">Prerequisites <span>(before any script command)</span></h2>\n'
                                )
                        elif "Platform Validation" in title:
                                html_body.append(
                                        f'<h2 id="{h2_id}">{parse_inline(title)}</h2>\n'
                                )
                        elif "Step" in title:
                                match = re.search(r"Step (\d+)\s*—\s*(.+)", title)
                                if match:
                                        s_num = match.group(1)
                                        s_text = match.group(2).strip()
                                        html_body.append(
                                                f"<!-- ============ STEP {s_num} ============ -->\n"
                                        )
                                        html_body.append(
                                                f'<div class="step" id="{h2_id}">\n'
                                        )
                                        html_body.append(
                                                f'<h2><span class="step-badge">Step {s_num}</span>{parse_inline(s_text)}</h2>\n'
                                        )
                                        in_step = True
                                else:
                                        html_body.append(
                                                f'<div class="step" id="{h2_id}">\n'
                                        )
                                        html_body.append(
                                                f"<h2>{parse_inline(title)}</h2>\n"
                                        )
                                        in_step = True
                        elif ("Quick reference" in title) or (
                                "Troubleshooting" in title
                        ):
                                html_body.append(
                                        f'<h2 id="{h2_id}">{parse_inline(title)}</h2>\n'
                                )
                        else:
                                html_body.append(
                                        f'<h2 id="{h2_id}">{parse_inline(title)}</h2>\n'
                                )
                        i += 1
                        continue

                # Header 3
                if line.startswith("### "):
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        title = line[4:].strip()
                        h3_id = slugify(title)

                        # Detect step headings and wrap with badge
                        match = re.search(r"Step (\d+)\s*—\s*(.+)", title)
                        if match:
                                # Close previous step div if open
                                if in_step:
                                        html_body.append("</div>\n\n")
                                        in_step = False
                                s_num = match.group(1)
                                s_text = match.group(2).strip()
                                html_body.append(f'<div class="step" id="{h3_id}">\n')
                                html_body.append(
                                        f'<h3><span class="step-badge">Step {s_num}</span>{parse_inline(s_text)}</h3>\n'
                                )
                                in_step = True
                        else:
                                html_body.append(
                                        f'<h3 id="{h3_id}">{parse_inline(title)}</h3>\n'
                                )
                        i += 1
                        continue

                # Header 4
                if line.startswith("#### "):
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        title = line[5:].strip()
                        html_body.append(f"<h4>{parse_inline(title)}</h4>\n")
                        i += 1
                        continue

                # Tables
                if line.strip().startswith("|"):
                        flush_paragraph()
                        flush_list()
                        # Parse table line (escaped pipes stay inside the cell)
                        parts = split_table_row(line)
                        # Check if it's separator
                        if parts and all(re.match(r"^:?-+:?$", p) for p in parts):
                                # Separator line, ignore
                                pass
                        else:
                                if not in_table:
                                        in_table = True
                                        table_rows = []
                                table_rows.append(parts)
                        i += 1
                        continue
                elif in_table:
                        flush_table()

                # Lists (Ordered or Unordered)
                match_ol = re.match(r"^(\d+)\.\s+(.*)", line.strip())
                match_ul = re.match(r"^([-\*])\s+(.*)", line.strip())
                list_match = match_ol or match_ul

                if list_match:
                        flush_paragraph()
                        l_type = "ol" if match_ol else "ul"
                        l_text = list_match.group(2)

                        if in_list and list_type != l_type:
                                flush_list()

                        if not in_list:
                                in_list = True
                                list_type = l_type
                                list_items = []

                        list_items.append(l_text)
                        i += 1
                        continue
                elif in_list:
                        # If line is indented, append to the last item
                        if line.startswith(("   ", "  ", "\t")):
                                if list_items:
                                        list_items[-1] += " " + line.strip()
                                i += 1
                                continue
                        else:
                                flush_list()

                # Images
                img_match = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$", line.strip())
                if img_match:
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        html_body.append(render_figure(*img_match.groups()))
                        i += 1
                        continue

                # Horizontal rule
                if re.fullmatch(r"-{3,}", line.strip()):
                        flush_paragraph()
                        flush_list()
                        flush_table()
                        html_body.append("<hr>\n")
                        i += 1
                        continue

                # Paragraphs and blank lines
                if not line.strip():
                        flush_paragraph()
                else:
                        p_lines.append(line)
                i += 1

        # End of file flushing
        flush_paragraph()
        flush_list()
        flush_table()
        flush_quote()
        if in_step:
                html_body.append("</div>\n\n")

        # Generate TOC markup
        toc_html = []
        toc_html.append('<nav class="toc">\n  <h2>Contents</h2>\n')
        for s_id, s_num, s_text in toc_items:
                toc_html.append(
                        f'  <a href="#{s_id}"><span class="n">{s_num}</span>{s_text}</a>\n'
                )
        toc_html.append("</nav>\n")

        toc_str = "".join(toc_html)
        body_str = "".join(html_body)
        hero_figures_str = "".join(render_figure(alt, src) for alt, src in hero_images)

        # Read base template styles/header/footer from the original file (if exists) or write default
        style_content = """@import url('https://fonts.googleapis.com/css2?family=SUSE:wght@100..800&family=Roboto+Mono:ital,wght@0,100..700;1,100..700&display=swap');

  :root {
    --bg: #efefef; /* SUSE Fog */
    --card: #ffffff; /* Pure White */
    --ink: #0c322c; /* SUSE Pine (Deep green/black) for text and titles */
    --muted: #525252; /* Fog Shade */
    --accent: #30ba78; /* SUSE Jungle (Vibrant Green) */
    --accent-dark: #0c322c; /* SUSE Pine (Deep forest green) */
    --code-bg: #0c322c; /* SUSE Pine for code block backgrounds */
    --code-ink: #c0efde; /* Jungle Shade */
    --border: #dcdbdc; /* Fog Shade */
    --ok: #30ba78; /* SUSE Jungle */
    --warn-bg: #ffefe9; /* Persimmon Shade */
    --warn-border: #fe7c3f; /* SUSE Persimmon (Orange) */
    --info-bg: #e6edfe; /* Waterhole Shade */
    --info-border: #2453ff; /* SUSE Waterhole (Blue) */

    /* SUSE Typography */
    --font-sans: 'SUSE', Verdana, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    --font-mono: 'SUSE Mono', 'Roboto Mono', ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: var(--font-sans);
    background: var(--bg);
    color: var(--ink);
    line-height: 1.6;
    text-align: left; /* Left align only as per SUSE guidelines */
  }
  .layout { display: flex; max-width: 1400px; margin: 0 auto; }
  /* ---------- Sidebar ---------- */
  nav.toc {
    width: 280px;
    flex-shrink: 0;
    position: sticky;
    top: 0;
    height: 100vh;
    overflow-y: auto;
    padding: 24px 16px;
    background: var(--card);
    border-right: 1px solid var(--border);
    font-size: 14px;
    font-family: var(--font-sans);
  }
  nav.toc h2 {
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--muted);
    margin: 0 0 12px;
    font-weight: 500; /* SUSE Headlines must be Medium weight */
  }
  nav.toc a {
    display: block;
    padding: 5px 10px;
    color: var(--ink);
    text-decoration: none;
    border-radius: 6px;
  }
  nav.toc a:hover { background: var(--bg); color: var(--accent); }
  nav.toc a .n {
    display: inline-block;
    width: 22px;
    color: var(--muted);
    font-variant-numeric: tabular-nums;
  }
  /* ---------- Main ---------- */
  main { flex: 1; min-width: 0; padding: 40px 48px 80px; text-align: left; }
  header.hero {
    background: linear-gradient(135deg, var(--accent-dark), var(--accent));
    color: #fff;
    border-radius: 12px;
    padding: 32px 36px;
    margin-bottom: 36px;
  }
  header.hero h1 {
    margin: 0 0 8px;
    font-size: 30px;
    font-weight: 500; /* SUSE Headlines must be Medium weight */
  }
  header.hero p { margin: 6px 0; opacity: 0.92; max-width: 850px; }
  h2 {
    font-size: 24px;
    margin: 48px 0 16px;
    padding-bottom: 8px;
    border-bottom: 2px solid var(--border);
    scroll-margin-top: 24px;
    color: var(--accent-dark);
    font-weight: 500; /* SUSE Headlines must be Medium weight */
  }
  h3 {
    font-size: 18px;
    margin: 28px 0 10px;
    color: var(--accent-dark);
    font-weight: 500; /* SUSE Headlines must be Medium weight */
  }
  h4 {
    font-size: 15px;
    margin: 20px 0 8px;
    color: var(--accent-dark);
    font-weight: 500;
  }
  p { max-width: 900px; text-align: left; }
  strong { color: var(--accent-dark); }
  /* ---------- Cards (steps) ---------- */
  .step {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 24px 28px;
    margin: 24px 0;
    scroll-margin-top: 24px;
  }
  .step > h2 { margin-top: 0; border: none; padding: 0; }
  .step-badge {
    display: inline-block;
    background: var(--accent);
    color: #fff;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.06em;
    padding: 3px 10px;
    border-radius: 999px;
    margin-right: 10px;
    vertical-align: middle;
    text-transform: uppercase;
  }
  /* ---------- Code ---------- */
  pre {
    background: var(--code-bg);
    color: var(--code-ink);
    padding: 16px 18px;
    border-radius: 8px;
    overflow-x: auto;
    font-size: 13.5px;
    line-height: 1.5;
    max-width: 900px;
    font-family: var(--font-mono);
  }
  code {
    font-family: var(--font-mono);
  }
  p code, li code, td code {
    background: #eafaf4; /* SUSE Jungle shade for inline code background */
    color: var(--accent-dark); /* Pine */
    padding: 2px 6px;
    border-radius: 5px;
    font-size: 0.9em;
  }
  /* ---------- Tables ---------- */
  table {
    border-collapse: collapse;
    width: 100%;
    max-width: 940px;
    margin: 16px 0;
    font-size: 14px;
    background: var(--card);
  }
  th, td {
    border: 1px solid var(--border);
    padding: 9px 12px;
    text-align: left;
    vertical-align: top;
  }
  th {
    background: #eafaf4; /* SUSE Jungle shade */
    font-weight: 500; /* SUSE Headings */
    color: var(--accent-dark);
  }
  tr:nth-child(even) td { background: #fafbfc; }
  /* ---------- Callouts ---------- */
  .callout {
    border-radius: 8px;
    padding: 14px 18px;
    margin: 16px 0;
    max-width: 900px;
    font-size: 14.5px;
  }
  .callout.warn { background: var(--warn-bg); border-left: 4px solid var(--warn-border); }
  .callout.info { background: var(--info-bg); border-left: 4px solid var(--info-border); }
  .callout .tag { font-weight: 700; text-transform: uppercase; font-size: 12px; letter-spacing: 0.05em; display: block; margin-bottom: 4px; }
  .callout.warn .tag { color: #8e2810; /* SUSE Persimmon deep shade */ }
  .callout.info .tag { color: #192072; /* SUSE Midnight */ }
  /* ---------- Diagram ---------- */
  .diagram {
    background: var(--code-bg);
    color: #90ebcd; /* SUSE Mint for diagram lines/text */
    padding: 20px 24px;
    border-radius: 8px;
    overflow-x: auto;
    font-size: 13.5px;
    line-height: 1.45;
    max-width: 900px;
    font-family: var(--font-mono);
  }
  /* ---------- Figures (rendered graphs) ---------- */
  figure.graph {
    margin: 20px 0;
    max-width: 960px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px;
  }
  figure.graph img { width: 100%; height: auto; display: block; }
  figure.graph figcaption {
    color: var(--muted);
    font-size: 13px;
    margin-top: 8px;
  }
  /* ---------- Captions & links ---------- */
  p.caption { color: var(--muted); font-size: 14px; margin: 28px 0 6px; }
  p.caption strong { color: var(--ink); }
  main a { color: #192072; text-decoration: none; }
  main a:hover { text-decoration: underline; }
  /* ---------- Misc ---------- */
  .ok { color: var(--ok); font-weight: 600; }
  hr { border: none; border-top: 1px solid var(--border); margin: 40px 0; }
  footer { color: var(--muted); font-size: 13px; text-align: left; margin-top: 60px; }
  @media (max-width: 900px) {
    nav.toc { display: none; }
    main { padding: 20px; }
  }"""

        final_html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{hero_title}</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="layout">

{toc_str}

<main>

<header class="hero">
  <h1>{hero_title}</h1>
  <p>{parse_inline(hero_desc)}</p>
</header>

{hero_figures_str}

{body_str}

<footer>Generated dynamically from README.md — Intel TDX attestation on SLES 16.1</footer>

</main>
</div>
</body>
</html>
"""

        # Write CSS to external file (CSP-compliant: no inline <style>)
        css_path = "style.css"
        try:
                with open(css_path, "w", encoding="utf-8") as f:
                        f.write(style_content)
        except OSError as e:
                raise SystemExit(f"error: cannot write {css_path}: {e}") from e

        try:
                with open(html_path, "w", encoding="utf-8") as f:
                        f.write(final_html)
        except OSError as e:
                raise SystemExit(f"error: cannot write {html_path}: {e}") from e


if __name__ == "__main__":
        convert_md_to_html("README.md", "README.html")
        print("README.html generated successfully from README.md.")

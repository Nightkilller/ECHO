#!/usr/bin/env python3
"""
Echo Documentation PDF Generator
Compiles all markdown documentation files into a single, professionally formatted PDF.
"""

import os
import re
import textwrap
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.colors import HexColor, Color
from reportlab.lib.units import inch, mm
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle,
    Flowable, KeepTogether, HRFlowable, Preformatted
)
from reportlab.lib import colors
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus.frames import Frame
from reportlab.platypus.doctemplate import PageTemplate, BaseDocTemplate
from io import BytesIO


# ─── Color Palette ───────────────────────────────────────────────────────────

COLORS = {
    'primary':      HexColor('#1a1a2e'),    # Deep navy
    'secondary':    HexColor('#16213e'),    # Dark blue
    'accent':       HexColor('#0f3460'),    # Medium blue
    'highlight':    HexColor('#e94560'),    # Coral red accent
    'text':         HexColor('#2c3e50'),    # Dark slate
    'text_light':   HexColor('#7f8c8d'),    # Muted gray
    'code_bg':      HexColor('#f8f9fa'),    # Light gray for code
    'code_border':  HexColor('#dee2e6'),    # Border gray
    'link':         HexColor('#2980b9'),    # Link blue
    'white':        HexColor('#ffffff'),
    'heading_1':    HexColor('#1a1a2e'),
    'heading_2':    HexColor('#0f3460'),
    'heading_3':    HexColor('#2c3e50'),
    'divider':      HexColor('#bdc3c7'),
}


# ─── Files to compile ────────────────────────────────────────────────────────

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MD_FILES = [
    'BEGINNER_GUIDE.md',
    'ARCHITECTURE.md',
    'FLOW_EXPLANATION.md',
    'API_GUIDE.md',
    'SECURITY_EXPLANATION.md',
    'DEBUGGING_GUIDE.md',
]
OUTPUT_FILE = os.path.join(BASE_DIR, 'Echo_Documentation.pdf')


# ─── Custom Flowables ────────────────────────────────────────────────────────

class GradientRect(Flowable):
    """A colored rectangle with text overlay for cover page sections."""
    def __init__(self, width, height, color, text='', text_color=None):
        Flowable.__init__(self)
        self.width = width
        self.height = height
        self.color = color
        self.text = text
        self.text_color = text_color or COLORS['white']

    def draw(self):
        self.canv.setFillColor(self.color)
        self.canv.roundRect(0, 0, self.width, self.height, 6, fill=1, stroke=0)
        if self.text:
            self.canv.setFillColor(self.text_color)
            self.canv.setFont('Helvetica', 10)
            self.canv.drawCentredString(self.width / 2, self.height / 2 - 4, self.text)


class CodeBlock(Flowable):
    """A styled code block with language label and rounded background."""
    def __init__(self, code_text, language='', max_width=440):
        Flowable.__init__(self)
        self.code_text = code_text
        self.language = language
        self.max_width = max_width
        self.padding = 12
        self.font_size = 7.5
        self.line_height = self.font_size * 1.45

        # Calculate dimensions
        lines = self.code_text.split('\n')
        # Wrap long lines
        wrapped_lines = []
        max_chars = int(self.max_width / (self.font_size * 0.52))
        for line in lines:
            if len(line) > max_chars:
                wrapped = textwrap.wrap(line, width=max_chars, subsequent_indent='  ')
                wrapped_lines.extend(wrapped if wrapped else [''])
            else:
                wrapped_lines.append(line)
        self.wrapped_lines = wrapped_lines
        self.height = len(wrapped_lines) * self.line_height + self.padding * 2 + (16 if self.language else 0)
        self.width = self.max_width + self.padding * 2

    def draw(self):
        canv = self.canv
        # Background
        canv.setFillColor(HexColor('#f1f3f5'))
        canv.setStrokeColor(HexColor('#dee2e6'))
        canv.setLineWidth(0.5)
        canv.roundRect(0, 0, self.width, self.height, 5, fill=1, stroke=1)

        # Language label
        y_offset = self.height - self.padding
        if self.language:
            canv.setFillColor(HexColor('#868e96'))
            canv.setFont('Helvetica-Bold', 7)
            canv.drawString(self.padding, y_offset - 4, self.language.upper())
            y_offset -= 16

        # Code text
        canv.setFillColor(HexColor('#212529'))
        canv.setFont('Courier', self.font_size)
        for line in self.wrapped_lines:
            canv.drawString(self.padding, y_offset - self.font_size, line)
            y_offset -= self.line_height


class ModuleDivider(Flowable):
    """A styled section divider between modules."""
    def __init__(self, width=460):
        Flowable.__init__(self)
        self.width = width
        self.height = 20

    def draw(self):
        canv = self.canv
        y = self.height / 2
        # Left gradient line
        for i in range(int(self.width)):
            alpha = min(i / (self.width * 0.3), 1.0) * 0.3
            if i > self.width * 0.7:
                alpha = (1.0 - (i - self.width * 0.7) / (self.width * 0.3)) * 0.3
            canv.setStrokeColor(Color(0.08, 0.08, 0.18, alpha))
            canv.setLineWidth(1.5)
            canv.line(i, y, i + 1, y)


# ─── Styles ──────────────────────────────────────────────────────────────────

def create_styles():
    styles = getSampleStyleSheet()

    styles.add(ParagraphStyle(
        name='CoverTitle',
        fontName='Helvetica-Bold',
        fontSize=36,
        leading=44,
        textColor=COLORS['primary'],
        alignment=TA_CENTER,
        spaceAfter=8,
    ))

    styles.add(ParagraphStyle(
        name='CoverSubtitle',
        fontName='Helvetica',
        fontSize=14,
        leading=20,
        textColor=COLORS['text_light'],
        alignment=TA_CENTER,
        spaceAfter=30,
    ))

    styles.add(ParagraphStyle(
        name='ModuleTitle',
        fontName='Helvetica-Bold',
        fontSize=24,
        leading=32,
        textColor=COLORS['heading_1'],
        spaceBefore=0,
        spaceAfter=6,
    ))

    styles.add(ParagraphStyle(
        name='ModuleSubtitle',
        fontName='Helvetica',
        fontSize=11,
        leading=16,
        textColor=COLORS['text_light'],
        spaceBefore=0,
        spaceAfter=20,
    ))

    styles.add(ParagraphStyle(
        name='H1',
        fontName='Helvetica-Bold',
        fontSize=20,
        leading=26,
        textColor=COLORS['heading_1'],
        spaceBefore=20,
        spaceAfter=10,
    ))

    styles.add(ParagraphStyle(
        name='H2',
        fontName='Helvetica-Bold',
        fontSize=16,
        leading=22,
        textColor=COLORS['heading_2'],
        spaceBefore=16,
        spaceAfter=8,
    ))

    styles.add(ParagraphStyle(
        name='H3',
        fontName='Helvetica-Bold',
        fontSize=13,
        leading=18,
        textColor=COLORS['heading_3'],
        spaceBefore=12,
        spaceAfter=6,
    ))

    styles.add(ParagraphStyle(
        name='H4',
        fontName='Helvetica-Bold',
        fontSize=11,
        leading=15,
        textColor=COLORS['heading_3'],
        spaceBefore=10,
        spaceAfter=4,
    ))

    styles.add(ParagraphStyle(
        name='BodyText2',
        fontName='Helvetica',
        fontSize=10,
        leading=16,
        textColor=COLORS['text'],
        spaceBefore=4,
        spaceAfter=6,
        alignment=TA_JUSTIFY,
    ))

    styles.add(ParagraphStyle(
        name='BulletItem',
        fontName='Helvetica',
        fontSize=10,
        leading=15,
        textColor=COLORS['text'],
        spaceBefore=2,
        spaceAfter=2,
        leftIndent=20,
        bulletIndent=8,
    ))

    styles.add(ParagraphStyle(
        name='SubBulletItem',
        fontName='Helvetica',
        fontSize=9.5,
        leading=14,
        textColor=COLORS['text'],
        spaceBefore=1,
        spaceAfter=1,
        leftIndent=36,
        bulletIndent=24,
    ))

    styles.add(ParagraphStyle(
        name='NumberedItem',
        fontName='Helvetica',
        fontSize=10,
        leading=15,
        textColor=COLORS['text'],
        spaceBefore=2,
        spaceAfter=2,
        leftIndent=20,
        bulletIndent=8,
    ))

    styles.add(ParagraphStyle(
        name='InlineCode',
        fontName='Courier',
        fontSize=9,
        leading=14,
        textColor=HexColor('#c0392b'),
        backColor=HexColor('#f8f9fa'),
    ))

    styles.add(ParagraphStyle(
        name='TOCEntry',
        fontName='Helvetica',
        fontSize=12,
        leading=22,
        textColor=COLORS['accent'],
        spaceBefore=4,
        spaceAfter=4,
        leftIndent=20,
    ))

    styles.add(ParagraphStyle(
        name='TOCTitle',
        fontName='Helvetica-Bold',
        fontSize=20,
        leading=28,
        textColor=COLORS['primary'],
        spaceBefore=20,
        spaceAfter=20,
        alignment=TA_CENTER,
    ))

    styles.add(ParagraphStyle(
        name='Footer',
        fontName='Helvetica',
        fontSize=8,
        textColor=COLORS['text_light'],
        alignment=TA_CENTER,
    ))

    return styles


# ─── Markdown Parser ─────────────────────────────────────────────────────────

def escape_xml(text):
    """Escape special XML characters for ReportLab paragraphs."""
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;')
    text = text.replace('>', '&gt;')
    return text


def format_inline(text):
    """Handle inline markdown formatting: bold, italic, code, links."""
    # Escape XML first
    text = escape_xml(text)

    # Bold + Italic
    text = re.sub(r'\*\*\*(.+?)\*\*\*', r'<b><i>\1</i></b>', text)
    # Bold
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    # Italic
    text = re.sub(r'\*(.+?)\*', r'<i>\1</i>', text)
    # Inline code - use courier font
    text = re.sub(r'`([^`]+)`', r'<font name="Courier" size="9" color="#c0392b">\1</font>', text)
    # Links [text](url) -> just show text in link color
    text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'<font color="#2980b9">\1</font>', text)

    return text


def parse_markdown_to_flowables(md_content, styles, module_num):
    """Convert markdown content into a list of ReportLab flowables."""
    flowables = []
    lines = md_content.split('\n')
    i = 0
    in_code_block = False
    code_lines = []
    code_language = ''
    first_heading = True

    # Extract the title and subtitle from the first H1
    title_line = ''
    subtitle_line = ''

    while i < len(lines):
        line = lines[i]

        # ── Code blocks ──────────────────────────────────────────────────
        if line.strip().startswith('```') and not in_code_block:
            in_code_block = True
            code_language = line.strip()[3:].strip()
            # Handle mermaid blocks as code display
            code_lines = []
            i += 1
            continue
        elif line.strip().startswith('```') and in_code_block:
            in_code_block = False
            code_text = '\n'.join(code_lines)
            if code_text.strip():
                flowables.append(Spacer(1, 4))
                flowables.append(CodeBlock(code_text, code_language, max_width=440))
                flowables.append(Spacer(1, 6))
            code_lines = []
            code_language = ''
            i += 1
            continue
        elif in_code_block:
            code_lines.append(line)
            i += 1
            continue

        # ── Horizontal Rules ─────────────────────────────────────────────
        if line.strip() == '---':
            flowables.append(Spacer(1, 6))
            flowables.append(HRFlowable(
                width="90%", thickness=0.5,
                color=COLORS['divider'], spaceAfter=6, spaceBefore=6
            ))
            i += 1
            continue

        # ── Headings ─────────────────────────────────────────────────────
        heading_match = re.match(r'^(#{1,4})\s+(.+)$', line)
        if heading_match:
            level = len(heading_match.group(1))
            text = heading_match.group(2).strip()

            if level == 1 and first_heading:
                first_heading = False
                # Module title page
                flowables.append(Spacer(1, 20))
                # Module number badge
                badge_text = f"MODULE {module_num}"
                flowables.append(Paragraph(
                    f'<font color="#e94560" size="10"><b>{badge_text}</b></font>',
                    styles['ModuleSubtitle']
                ))
                flowables.append(Paragraph(format_inline(text), styles['ModuleTitle']))
                # Extract subtitle if next line is non-empty and not a heading
                if i + 1 < len(lines) and lines[i + 1].strip() and not lines[i + 1].strip().startswith('#'):
                    subtitle = lines[i + 1].strip()
                    flowables.append(Paragraph(format_inline(subtitle), styles['ModuleSubtitle']))
                    i += 1
                flowables.append(Spacer(1, 8))
                i += 1
                continue

            style_name = f'H{min(level, 4)}'
            flowables.append(Paragraph(format_inline(text), styles[style_name]))
            i += 1
            continue

        # ── Bullet points ────────────────────────────────────────────────
        bullet_match = re.match(r'^(\s*)[-*]\s+(.+)$', line)
        if bullet_match:
            indent = len(bullet_match.group(1))
            text = bullet_match.group(2).strip()
            if indent >= 2:
                style = styles['SubBulletItem']
                bullet_char = '›'
            else:
                style = styles['BulletItem']
                bullet_char = '•'
            flowables.append(Paragraph(
                f'{bullet_char}  {format_inline(text)}', style
            ))
            i += 1
            continue

        # ── Numbered items ───────────────────────────────────────────────
        numbered_match = re.match(r'^(\s*)(\d+)\.\s+(.+)$', line)
        if numbered_match:
            indent = len(numbered_match.group(1))
            num = numbered_match.group(2)
            text = numbered_match.group(3).strip()
            style = styles['NumberedItem']
            flowables.append(Paragraph(
                f'<b>{num}.</b>  {format_inline(text)}', style
            ))
            i += 1
            continue

        # ── Regular paragraphs ───────────────────────────────────────────
        if line.strip():
            flowables.append(Paragraph(format_inline(line.strip()), styles['BodyText2']))

        i += 1

    return flowables


# ─── Page Templates ──────────────────────────────────────────────────────────

def add_page_number(canvas, doc):
    """Add page number and footer to each page."""
    canvas.saveState()
    page_num = canvas.getPageNumber()

    # Footer line
    canvas.setStrokeColor(COLORS['divider'])
    canvas.setLineWidth(0.5)
    canvas.line(50, 40, A4[0] - 50, 40)

    # Page number
    canvas.setFont('Helvetica', 8)
    canvas.setFillColor(COLORS['text_light'])
    canvas.drawCentredString(A4[0] / 2, 28, f"— {page_num} —")

    # Document title in footer
    canvas.setFont('Helvetica', 7)
    canvas.drawString(50, 28, "Echo Documentation")

    canvas.restoreState()


def add_cover_page_decor(canvas, doc):
    """Cover page decoration - no page number."""
    canvas.saveState()

    # Top accent bar
    canvas.setFillColor(COLORS['highlight'])
    canvas.rect(0, A4[1] - 6, A4[0], 6, fill=1, stroke=0)

    # Bottom accent bar
    canvas.setFillColor(COLORS['primary'])
    canvas.rect(0, 0, A4[0], 4, fill=1, stroke=0)

    canvas.restoreState()


# ─── Build PDF ───────────────────────────────────────────────────────────────

def build_cover_page(styles):
    """Generate the cover page flowables."""
    flowables = []
    flowables.append(Spacer(1, 120))

    # Title
    flowables.append(Paragraph(
        '<font color="#e94560">ECHO</font>',
        ParagraphStyle(
            'BigTitle', fontName='Helvetica-Bold', fontSize=52,
            leading=60, alignment=TA_CENTER, textColor=COLORS['primary']
        )
    ))
    flowables.append(Spacer(1, 4))
    flowables.append(Paragraph(
        'Complete Engineering Documentation',
        styles['CoverTitle']
    ))
    flowables.append(Spacer(1, 12))

    # Divider
    flowables.append(HRFlowable(
        width="40%", thickness=2,
        color=COLORS['highlight'], spaceAfter=16, spaceBefore=8
    ))

    # Subtitle
    flowables.append(Paragraph(
        'A comprehensive guide to the architecture, execution flow, API interfaces, '
        'security model, and debugging strategies of the Echo macOS desktop assistant.',
        styles['CoverSubtitle']
    ))
    flowables.append(Spacer(1, 40))

    # Module badges
    modules = [
        ('Module 1', 'Beginner\'s Engineering Guide'),
        ('Module 2', 'System Architecture Guide'),
        ('Module 3', 'End-to-End Execution Flow'),
        ('Module 4', 'API Interface & Routing Guide'),
        ('Module 5', 'Security & Permission Guide'),
        ('Module 6', 'Diagnostic & Debugging Handbook'),
    ]

    for mod_num, mod_title in modules:
        flowables.append(Paragraph(
            f'<font color="#e94560"><b>{mod_num}</b></font>'
            f'  —  {mod_title}',
            ParagraphStyle(
                f'ModBadge_{mod_num}', fontName='Helvetica', fontSize=11,
                leading=20, alignment=TA_CENTER, textColor=COLORS['text'],
                spaceBefore=3, spaceAfter=3,
            )
        ))

    flowables.append(Spacer(1, 60))

    # Footer info
    flowables.append(Paragraph(
        'Generated from project source documentation',
        ParagraphStyle(
            'CoverFooter', fontName='Helvetica', fontSize=9,
            leading=14, alignment=TA_CENTER, textColor=COLORS['text_light']
        )
    ))

    flowables.append(PageBreak())
    return flowables


def build_toc(styles, module_titles):
    """Generate a Table of Contents page."""
    flowables = []
    flowables.append(Spacer(1, 40))
    flowables.append(Paragraph('Table of Contents', styles['TOCTitle']))
    flowables.append(Spacer(1, 10))

    for i, title in enumerate(module_titles, 1):
        flowables.append(Paragraph(
            f'<b><font color="#e94560">Module {i}</font></b>'
            f'  &nbsp;&nbsp;  {escape_xml(title)}',
            styles['TOCEntry']
        ))

    flowables.append(Spacer(1, 20))
    flowables.append(HRFlowable(
        width="60%", thickness=1,
        color=COLORS['divider'], spaceAfter=10, spaceBefore=10
    ))
    flowables.append(PageBreak())
    return flowables


def main():
    print("🔧 Echo Documentation PDF Generator")
    print("=" * 50)

    styles = create_styles()
    all_flowables = []

    # ── Cover page ────────────────────────────────────────────────────────
    all_flowables.extend(build_cover_page(styles))

    # ── Read all files and extract titles ─────────────────────────────────
    module_titles = []
    module_contents = []
    for fname in MD_FILES:
        fpath = os.path.join(BASE_DIR, fname)
        print(f"  📖 Reading: {fname}")
        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()
        module_contents.append(content)

        # Extract title (first H1)
        title_match = re.search(r'^#\s+(.+)$', content, re.MULTILINE)
        if title_match:
            module_titles.append(title_match.group(1).strip())
        else:
            module_titles.append(fname.replace('.md', '').replace('_', ' ').title())

    # ── Table of Contents ─────────────────────────────────────────────────
    all_flowables.extend(build_toc(styles, module_titles))

    # ── Module content ────────────────────────────────────────────────────
    for i, (content, fname) in enumerate(zip(module_contents, MD_FILES), 1):
        print(f"  📄 Processing Module {i}: {fname}")

        if i > 1:
            all_flowables.append(PageBreak())

        module_flowables = parse_markdown_to_flowables(content, styles, i)
        all_flowables.extend(module_flowables)

    # ── Build PDF ─────────────────────────────────────────────────────────
    print(f"\n  📝 Generating PDF: {OUTPUT_FILE}")

    doc = SimpleDocTemplate(
        OUTPUT_FILE,
        pagesize=A4,
        topMargin=50,
        bottomMargin=55,
        leftMargin=55,
        rightMargin=55,
        title="Echo - Complete Engineering Documentation",
        author="Echo Development Team",
        subject="Echo macOS Desktop Assistant Documentation",
    )

    doc.build(all_flowables, onFirstPage=add_cover_page_decor, onLaterPages=add_page_number)

    file_size = os.path.getsize(OUTPUT_FILE)
    print(f"\n  ✅ PDF generated successfully!")
    print(f"  📁 Location: {OUTPUT_FILE}")
    print(f"  📏 Size: {file_size / 1024:.1f} KB")
    print("=" * 50)


if __name__ == '__main__':
    main()

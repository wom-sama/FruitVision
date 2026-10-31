"""Render the checked, local demo handout; no service or application mutation."""
from pathlib import Path
import re
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'server/docs/VAI_TRO_THAO_TAC_CONG_NGHE_2_6_1.md'
OUTPUT = ROOT / 'output/pdf/FruitVision_VaiTro_ThaoTac_CongNghe_2.6.1.pdf'
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
pdfmetrics.registerFont(TTFont('Arial', 'C:/Windows/Fonts/arial.ttf'))
pdfmetrics.registerFont(TTFont('ArialBold', 'C:/Windows/Fonts/arialbd.ttf'))
pdfmetrics.registerFontFamily('Arial', normal='Arial', bold='ArialBold')
BLUE = colors.HexColor('#07579A')
TEAL = colors.HexColor('#176851')
WIDTH = A4[0] - 30 * mm
styles = {
    'title': ParagraphStyle('title', fontName='ArialBold', fontSize=19, leading=24, textColor=BLUE, spaceAfter=10),
    'h1': ParagraphStyle('h1', fontName='ArialBold', fontSize=15, leading=19, textColor=BLUE, spaceBefore=4, spaceAfter=9, keepWithNext=True),
    'h2': ParagraphStyle('h2', fontName='ArialBold', fontSize=11.3, leading=15, textColor=TEAL, spaceBefore=8, spaceAfter=5, keepWithNext=True),
    'body': ParagraphStyle('body', fontName='Arial', fontSize=10.1, leading=13.2, spaceAfter=6),
    'cell': ParagraphStyle('cell', fontName='Arial', fontSize=9.6, leading=12.2, alignment=TA_LEFT),
    'th': ParagraphStyle('th', fontName='ArialBold', fontSize=9.8, leading=13, textColor=colors.white),
    'bullet': ParagraphStyle('bullet', fontName='Arial', fontSize=9.9, leading=13.1, leftIndent=9, firstLineIndent=-7, spaceAfter=4),
}

def markup(s):
    s = escape(s)
    s = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', s)
    return re.sub(r'`([^`]+)`', r'\1', s)

def p(s, style='body'):
    return Paragraph(markup(s), styles[style])

class Numbered(Canvas):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.states = []
    def showPage(self):
        self.states.append(dict(self.__dict__))
        self._startPage()
    def save(self):
        total = len(self.states)
        for state in self.states:
            self.__dict__.update(state)
            self.setStrokeColor(colors.HexColor('#C6D7E4'))
            self.line(15*mm, A4[1]-12*mm, A4[0]-15*mm, A4[1]-12*mm)
            self.setFont('Arial', 8)
            self.setFillColor(colors.HexColor('#466174'))
            self.drawString(15*mm, A4[1]-9*mm, 'FRUITVISION | Đồ án Lập trình trên thiết bị di động')
            self.drawString(15*mm, 10*mm, '2.6.1+6013 | 31/10/2026 | Vai trò, thao tác và công nghệ')
            self.setFillColor(BLUE)
            self.setFont('ArialBold', 9)
            self.drawRightString(A4[0]-15*mm, 10*mm, f'{self._pageNumber}/{total}')
            super().showPage()
        super().save()

lines = SOURCE.read_text(encoding='utf-8').splitlines()
story, i = [], 0
while i < len(lines):
    line = lines[i].strip()
    if not line:
        i += 1
        continue
    if line == '<!-- PAGE -->':
        story.append(PageBreak()); i += 1; continue
    if line.startswith('|'):
        rows = []
        while i < len(lines) and lines[i].strip().startswith('|'):
            cells = [c.strip() for c in lines[i].strip().strip('|').split('|')]
            if not all(re.fullmatch(r'[:\- ]+', c) for c in cells):
                rows.append(cells)
            i += 1
        n = len(rows[0])
        widths = [40, (WIDTH-40)*.49, (WIDTH-40)*.51] if n == 3 else [98, WIDTH-98]
        data = [[p(c, 'th' if r == 0 else 'cell') for c in row] for r, row in enumerate(rows)]
        table = Table(data, colWidths=widths, repeatRows=1, hAlign='LEFT')
        table.setStyle(TableStyle([
            ('BACKGROUND', (0,0), (-1,0), BLUE), ('VALIGN', (0,0), (-1,-1), 'TOP'),
            ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.HexColor('#F0F5F9'), colors.white]),
            ('LEFTPADDING', (0,0), (-1,-1), 7), ('RIGHTPADDING', (0,0), (-1,-1), 7),
            ('TOPPADDING', (0,0), (-1,-1), 4.5), ('BOTTOMPADDING', (0,0), (-1,-1), 4.5),
            ('LINEBELOW', (0,0), (-1,0), .6, BLUE),
            ('LINEBELOW', (0,1), (-1,-1), .25, colors.HexColor('#D6E2EA')),
        ]))
        story.extend([table, Spacer(1, 8)])
        continue
    if line.startswith('### '):
        story.append(p(line[4:], 'h2'))
    elif line.startswith('## '):
        story.append(p(line[3:], 'h1'))
    elif line.startswith('# '):
        story.append(p(line[2:], 'title'))
    elif line.startswith('- '):
        story.append(p('- ' + line[2:], 'bullet'))
    else:
        story.append(p(line))
    i += 1

doc = SimpleDocTemplate(str(OUTPUT), pagesize=A4, leftMargin=15*mm, rightMargin=15*mm,
    topMargin=17*mm, bottomMargin=17*mm, title='FruitVision - Vai trò, thao tác và công nghệ', author='FruitVision')
doc.build(story, canvasmaker=Numbered)
print(OUTPUT)

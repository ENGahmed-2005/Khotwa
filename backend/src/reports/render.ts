import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium, type Browser, type Page } from 'playwright-core';
import { AlignmentType, BorderStyle, Document, Header, HeadingLevel, ImageRun, Packer, PageNumber, Paragraph, Table, TableCell, TableRow, TextRun, WidthType, type ParagraphChild } from 'docx';
import { ApiError } from '../errors.js';
import { escapeHtml, goalCharts } from './charts.js';
import { accuracyLabel, percentLabel, reviewSafeText, statusLabel, supportLabel, titleForType, type InstitutionLogo, type ReportDocument, type ReportSettings } from './model.js';

let fontPromise: Promise<Buffer> | undefined;
function fontData() {
  fontPromise ??= readFile(process.env.KHOTWA_REPORT_FONT ?? fileURLToPath(new URL('./assets/NotoSansArabic.ttf', import.meta.url)));
  return fontPromise;
}
async function launchBrowser(): Promise<Browser> {
  try {
    const path = process.env.KHOTWA_CHROMIUM_EXECUTABLE;
    return await chromium.launch({ headless: true, ...(path ? { executablePath: path } : { channel: 'chrome' }) });
  } catch {
    throw new ApiError(503, 'REPORT_RENDERER_UNAVAILABLE', 'محرّك الطباعة العربي غير متاح حاليًا؛ احتفظي بالعمل وأعيدي المحاولة.');
  }
}
async function privatePage(browser: Browser): Promise<Page> {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 900, height: 700 } });
  await context.route('**/*', route => route.abort());
  return context.newPage();
}
function logoHtml(settings: ReportSettings) {
  return settings.logo ? `<img alt="شعار المؤسسة" width="78" height="${Math.min(45, 78 * settings.logo.height / settings.logo.width)}" src="data:image/png;base64,${settings.logo.base64}"/>` : '';
}
async function stylesheet() {
  return `@font-face{font-family:NotoSansArabic;src:url(data:font/ttf;base64,${(await fontData()).toString('base64')}) format('truetype');font-weight:100 900}
    *{box-sizing:border-box}html{font-family:NotoSansArabic,Arial,sans-serif;font-size:15px;color:#111;background:white}
    body{direction:rtl;line-height:1.8;margin:0}h1{font-size:23px;line-height:1.6;margin:0 0 12px;color:black}
    h2{font-size:19px;line-height:1.7;margin:22px 0 8px;break-after:avoid}h3{font-size:16px;line-height:1.7;margin:14px 0 6px;break-after:avoid}
    p{margin:7px 0;overflow-wrap:anywhere}bdi{direction:ltr;unicode-bidi:isolate}
    table{width:100%;border-collapse:collapse;margin:10px 0 16px;font-size:14px}
    th,td{border:1px solid #b9bfc1;padding:7px 8px;text-align:right;vertical-align:middle;overflow-wrap:anywhere}
    th{background:#eceff0;font-weight:700}thead{display:table-header-group}tr{break-inside:avoid}
    figure{margin:12px 0;break-inside:avoid}figure svg{display:block;width:100%;height:auto}.muted{font-size:12px;color:#333}
    .metric{font-weight:700}.manual{padding:9px 0;border-bottom:1px dotted #555}.section{margin:12px 0}.metadata{font-size:13px}
    .logo{float:left;max-height:48px;max-width:100px}ul,ol{padding-right:22px}li{margin:4px 0}@page{size:Letter}`;
}
function listHtml(values: string[]) {
  return values.length ? `<ul>${values.map(value => `<li>${escapeHtml(value)}</li>`).join('')}</ul>` : '<p>لم تسجل عناصر في الخطة المعتمدة.</p>';
}
function headerHtml(studentCode: string, serial: string, settings: ReportSettings) {
  return `<div style="font-family:Arial,sans-serif;font-size:13px;direction:rtl;width:100%;padding:0 16mm;line-height:1.7;color:black"><div style="float:left;margin-right:8px">${logoHtml(settings)}</div><div>${escapeHtml(settings.institutionTitle || 'خطوة')} | رمز الطالب <span dir="ltr">${escapeHtml(studentCode)}</span></div><div>رقم التقرير <span dir="ltr">${escapeHtml(serial)}</span> | صفحة <span class="pageNumber"></span> من <span class="totalPages"></span></div></div>`;
}
async function pdfFromPage(page: Page, bodyHtml: string, studentCode: string, serial: string, settings: ReportSettings): Promise<Buffer> {
  await page.setContent(`<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"/><style>${await stylesheet()}</style></head><body>${bodyHtml}</body></html>`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  return page.pdf({ format: 'Letter', printBackground: true, displayHeaderFooter: true,
    headerTemplate: headerHtml(studentCode, serial, settings), footerTemplate: '<div></div>',
    margin: { top: '27mm', bottom: '17mm', left: '16mm', right: '16mm' }, preferCSSPageSize: true });
}
export async function renderArabicPdf(input: { bodyHtml: string; studentCode: string; serial: string; settings: ReportSettings }): Promise<Buffer> {
  const browser = await launchBrowser();
  try { return await pdfFromPage(await privatePage(browser), input.bodyHtml, input.studentCode, input.serial, input.settings); }
  finally { await browser.close(); }
}
export function reportHtml(report: ReportDocument): string {
  const title = titleForType(report.type);
  const intro = report.type === 'parent'
    ? 'تعرض هذه المتابعة ما تدربت عليه المهارة وما سُجّل من أداء خلال الفترة. النسبة تعني الإجابات الصحيحة من فرص التدريب المسجلة، ولا تقارن أداء الطفل بأطفال آخرين.'
    : report.type === 'administration'
    ? 'يعرض هذا الملخص الأهداف المعتمدة والتدخلات والانتظام وبيانات الأداء المسجلة خلال الفترة المحددة.'
    : report.type === 'plan' ? 'نسخة الخطة التي راجعتها المختصة واعتمدتها؛ تعرض الأهداف ومعاييرها وخطوات المتابعة.'
    : 'يعرض التقرير الأهداف المعتمدة والتدخلات التربوية والجلسات المسجلة. دقة الجلسة هي الصحيح مقسومًا على المحاولات المنفذة، وتبقى نتائج التقييم الأولي منفصلة عنها.';
  const metadata = `<p class="metadata">رمز الطالب <bdi>${escapeHtml(report.studentCode)}</bdi>${report.grade === null ? '' : ' | الصف ' + escapeHtml(report.grade)}<br/>الفترة <bdi>${report.periodStart}</bdi> إلى <bdi>${report.periodEnd}</bdi> | التصدير <bdi>${report.exportedOn}</bdi></p>`;
  const overview = `<h2>ملخص الخطة المعتمدة</h2><p><strong>الهدف العام </strong>${escapeHtml(report.content.generalGoal)}</p><p><strong>نقاط القوة </strong>${escapeHtml(report.content.strengthsSummary)}</p><p><strong>الاحتياج التعليمي </strong>${escapeHtml(report.content.needsSummary)}</p><p><strong>مستوى الأداء الأولي </strong>${escapeHtml(report.content.baseline)}</p>`;
  const attendanceHtml = report.type === 'plan' ? '' : `<h2>الانتظام خلال الفترة</h2><p>${report.attendance.completed} جلسات منفذة من ${report.attendance.scheduled} جلسات تشمل الحضور والغياب. نسبة الانتظام <bdi class="metric">${percentLabel(report.attendance.percent)}</bdi>. الجلسات الملغاة خارج مقام الانتظام، والغياب والإلغاء لا ينتجان نسبة أداء.</p>`;
  const goals = report.goals.map((goal, index) => {
    const title = `<h2>الهدف ${index + 1}</h2><p>${escapeHtml(goal.behavior)} ${escapeHtml(goal.condition)}</p><p><strong>المعيار </strong>${escapeHtml(goal.criterion)} | الإطار الزمني ${goal.timeframeWeeks} أسابيع</p>`;
    if (report.type === 'plan') return title;
    const graphs = goalCharts(goal).map(panel => `<figure>${panel.svg}<figcaption class="muted">دقة الجلسات${panel.totalParts > 1 ? ` | جزء ${panel.part} من ${panel.totalParts}` : ''}. ${goal.targetPercent === null ? 'معيار الدعم موضح نصيًا أعلاه.' : 'الخط المتقطع يمثل النسبة المستهدفة.'} غ: غياب، أ: إلغاء؛ لا يحسبان أداءً صفرًا.</figcaption></figure>`).join('');
    const rows = goal.sessions.map(session => `<tr><td><bdi>${session.occurredOn}</bdi></td><td>${statusLabel(session.status)}</td><td>${session.status === 'completed' ? `<bdi>${session.correct} / ${session.total}</bdi>` : 'لا أداء مسجل'}</td><td><bdi>${accuracyLabel(session)}</bdi></td><td>${supportLabel(session.support)}</td></tr>`).join('');
    return `${title}${graphs}${goal.sessions.length ? `<table><thead><tr><th>التاريخ</th><th>الحالة</th><th>صحيح / محاولات</th><th>الدقة</th><th>الدعم</th></tr></thead><tbody>${rows}</tbody></table>` : '<p>لا توجد بيانات جلسات لهذا الهدف ضمن الفترة المحددة.</p>'}`;
  }).join('');
  const strategies = report.optionalSections.strategies ? `<h2>التدخلات التربوية</h2>${listHtml(report.content.strategies)}` : '';
  const recommendations = report.optionalSections.recommendations ? `<h2>توصيات المتابعة</h2>${listHtml(report.content.recommendations)}` : '';
  const schedule = report.optionalSections.sessionSchedule ? `<p>مدة الخطة ${report.content.durationWeeks} أسابيع | ${report.content.sessionsPerWeek} جلسات أسبوعيًا</p>` : '';
  return `${logoHtml(report.settings)}<h1>${title}</h1>${metadata}<p>${intro}</p><p class="manual">الاسم يكتب يدويًا بعد الطباعة أو في نسخة Word: ........................................</p>${overview}${attendanceHtml}${goals}${strategies}<h2>الوسائل وأدوات المتابعة</h2>${listHtml(report.content.tools)}${listHtml(report.content.measurementTools)}${schedule}${recommendations}<p><strong>المتابعة القادمة </strong><bdi>${report.content.nextFollowUp}</bdi></p>`;
}

function textRuns(text: string, bold = false, size = 24): TextRun[] {
  return text.split(/([A-Za-z0-9][A-Za-z0-9 .:/%+-]*)/).filter(Boolean).map(part => new TextRun({ text: part, font: 'Arial', size, color: '000000', bold, rightToLeft: !/^[A-Za-z0-9]/.test(part) }));
}
function paragraph(text: string, options: { heading?: boolean; title?: boolean; bold?: boolean } = {}) {
  return new Paragraph({ bidirectional: true, alignment: AlignmentType.RIGHT, spacing: { after: 130, line: 330 },
    ...(options.title ? { heading: HeadingLevel.TITLE } : options.heading ? { heading: HeadingLevel.HEADING_2 } : {}),
    children: textRuns(text, options.bold ?? !!(options.heading || options.title), options.title ? 38 : options.heading ? 30 : 24) });
}
function table(rows: string[][]): Table {
  const borders = Object.fromEntries(['top', 'left', 'bottom', 'right', 'insideHorizontal', 'insideVertical'].map(edge => [edge, { style: BorderStyle.SINGLE, size: 4, color: 'B9BFC1' }]));
  return new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, visuallyRightToLeft: true, borders,
    rows: rows.map((row, index) => new TableRow({ tableHeader: index === 0, cantSplit: true, children: row.map(value => new TableCell({
      margins: { top: 90, bottom: 90, left: 110, right: 110 }, ...(index === 0 ? { shading: { fill: 'ECEFF0' } } : {}),
      children: [paragraph(value, { bold: index === 0 })],
    })) })) });
}
async function chartPng(page: Page, svg: string): Promise<Buffer> {
  await page.setContent(`<!doctype html><html><head><meta charset="utf-8"/><style>${await stylesheet()}body{margin:0;direction:rtl}</style></head><body>${svg}</body></html>`);
  await page.evaluate(() => document.fonts.ready);
  return page.locator('svg').screenshot({ type: 'png', scale: 'css' });
}
export async function renderReport(report: ReportDocument, format: 'pdf' | 'docx'): Promise<Buffer> {
  const browser = await launchBrowser();
  try {
    const page = await privatePage(browser);
    if (format === 'pdf') return await pdfFromPage(page, reportHtml(report), report.studentCode, report.serial, report.settings);
    const children: (Paragraph | Table)[] = [paragraph(titleForType(report.type), { title: true }),
      paragraph(`رمز الطالب ${report.studentCode}${report.grade === null ? '' : ' | الصف ' + report.grade}`),
      paragraph(`الفترة ${report.periodStart} إلى ${report.periodEnd} | التصدير ${report.exportedOn}`),
      paragraph('الاسم يكتب بعد الطباعة أو في هذه النسخة خارج التطبيق: ........................................'),
      paragraph(report.type === 'parent' ? 'تعرض المتابعة ما سُجّل من تدريب وأداء. النسبة هي الصحيح من فرص التدريب، ولا تقارن الطفل بأطفال آخرين.' : 'تعرض الوثيقة الخطة المعتمدة وبيانات الجلسات المسجلة، مع فصلها عن نتائج التقييم الأولي.'),
      paragraph('ملخص الخطة المعتمدة', { heading: true }), paragraph(`الهدف العام ${report.content.generalGoal}`),
      paragraph(`نقاط القوة ${report.content.strengthsSummary}`), paragraph(`الاحتياج التعليمي ${report.content.needsSummary}`), paragraph(`مستوى الأداء الأولي ${report.content.baseline}`)];
    if (report.type !== 'plan') children.push(paragraph('الانتظام خلال الفترة', { heading: true }),
      paragraph(`${report.attendance.completed} جلسات منفذة من ${report.attendance.scheduled} جلسات حضور وغياب. الانتظام ${percentLabel(report.attendance.percent)}. الجلسات الملغاة خارج المقام، والغياب والإلغاء لا ينتجان نسبة أداء.`));
    for (const [index, goal] of report.goals.entries()) {
      children.push(paragraph(`الهدف ${index + 1}`, { heading: true }), paragraph(`${goal.behavior} ${goal.condition}`), paragraph(`المعيار ${goal.criterion} | الإطار الزمني ${goal.timeframeWeeks} أسابيع`));
      if (report.type === 'plan') continue;
      for (const panel of goalCharts(goal)) {
        const data = await chartPng(page, panel.svg);
        children.push(new Paragraph({ alignment: AlignmentType.CENTER, children: [new ImageRun({ type: 'png', data, transformation: { width: 630, height: 215.25 }, altText: { title: 'دقة الجلسات', description: goal.behavior, name: `goal-${index + 1}-${panel.part}` } })] }),
          paragraph(`دقة الجلسات${panel.totalParts > 1 ? ` | جزء ${panel.part} من ${panel.totalParts}` : ''}. ${goal.targetPercent === null ? 'معيار الدعم موضح نصيًا.' : 'الخط المتقطع يمثل النسبة المستهدفة.'} غ: غياب، أ: إلغاء؛ لا يحسبان أداءً صفرًا.`));
      }
      if (goal.sessions.length) children.push(table([['التاريخ', 'الحالة', 'صحيح / محاولات', 'الدقة', 'الدعم'], ...goal.sessions.map(session => [session.occurredOn, statusLabel(session.status), session.status === 'completed' ? `${session.correct} / ${session.total}` : 'لا أداء مسجل', accuracyLabel(session), supportLabel(session.support)])]));
    }
    if (report.optionalSections.strategies) children.push(paragraph('التدخلات التربوية', { heading: true }), ...report.content.strategies.map(value => paragraph(value)));
    children.push(paragraph('الوسائل وأدوات المتابعة', { heading: true }), ...[...report.content.tools, ...report.content.measurementTools].map(value => paragraph(value)));
    if (report.optionalSections.sessionSchedule) children.push(paragraph(`مدة الخطة ${report.content.durationWeeks} أسابيع | ${report.content.sessionsPerWeek} جلسات أسبوعيًا`));
    if (report.optionalSections.recommendations) children.push(paragraph('توصيات المتابعة', { heading: true }), ...report.content.recommendations.map(value => paragraph(value)));
    children.push(paragraph(`المتابعة القادمة ${report.content.nextFollowUp}`));
    const headerChildren: ParagraphChild[] = [...textRuns(`${report.settings.institutionTitle || 'خطوة'} | رمز الطالب ${report.studentCode}`, true)];
    if (report.settings.logo) headerChildren.push(new ImageRun({ type: 'png', data: Buffer.from(report.settings.logo.base64, 'base64'), transformation: { width: Math.min(78, 45 * report.settings.logo.width / report.settings.logo.height), height: Math.min(45, 78 * report.settings.logo.height / report.settings.logo.width) }, altText: { title: 'شعار المؤسسة', description: 'شعار المؤسسة', name: 'institution-logo' } }));
    const document = new Document({ creator: 'Khotwa', title: titleForType(report.type), description: 'تقرير تربوي برمز مجهّل دون بيانات تعريفية',
      styles: { default: { document: { run: { font: 'Arial', size: 24, color: '000000' }, paragraph: { alignment: AlignmentType.RIGHT } },
        title: { run: { font: 'Arial', size: 38, bold: true, color: '000000' }, paragraph: { spacing: { after: 200 } } },
        heading2: { run: { font: 'Arial', size: 30, bold: true, color: '000000' }, paragraph: { spacing: { before: 180, after: 120 }, keepNext: true } } } },
      sections: [{ properties: { page: { size: { width: 12240, height: 15840 }, margin: { top: 1700, bottom: 1000, left: 900, right: 900, header: 500, footer: 500 } } },
        headers: { default: new Header({ children: [new Paragraph({ bidirectional: true, alignment: AlignmentType.RIGHT, children: headerChildren }),
          new Paragraph({ bidirectional: true, alignment: AlignmentType.RIGHT, children: [...textRuns(`رقم التقرير ${report.serial} | صفحة `), new TextRun({ children: [PageNumber.CURRENT], font: 'Arial', size: 20 }), ...textRuns(' من '), new TextRun({ children: [PageNumber.TOTAL_PAGES], font: 'Arial', size: 20 })] })] }) }, children }] });
    return await Packer.toBuffer(document);
  } finally { await browser.close(); }
}

export interface ActivityPrintInput {
  studentCode: string; serial: string; goal: string; settings: ReportSettings; status?: 'draft' | 'approved';
  content: { title: string; steps: string[]; examples: string[]; feedback: string; measurement: string; preparation: string[]; tools: string[]; minutes: number; lowCostAlternatives: string[]; teacherNotes: string };
  optionalSections?: { title?: boolean; goal?: boolean; duration?: boolean; alternatives?: boolean; teacherNotes?: boolean };
}
export async function renderActivityPdf(input: ActivityPrintInput): Promise<Buffer> {
  const c = input.content, sections = input.optionalSections;
  reviewSafeText([input.goal, c.title, ...c.steps, ...c.examples, c.feedback, c.measurement, ...c.preparation, ...c.tools, ...c.lowCostAlternatives, c.teacherNotes]);
  const bodyHtml = `${logoHtml(input.settings)}<h1>${sections?.title === false ? 'نشاط تعليمي' : escapeHtml(c.title)}</h1>${input.status === 'approved' ? '' : '<p><strong>مقترح يحتاج مراجعة المختصة</strong></p>'}${sections?.goal === false ? '' : '<p>الهدف المرتبط ' + escapeHtml(input.goal) + '</p>'}<p>رمز الطالب <bdi>${escapeHtml(input.studentCode)}</bdi></p><h2>الأدوات المتاحة</h2>${listHtml(c.tools)}<h2>إعداد الوسيلة</h2>${listHtml(c.preparation)}<h2>خطوات التنفيذ</h2><ol>${c.steps.map(step => `<li>${escapeHtml(step)}</li>`).join('')}</ol><h2>أمثلة تطبيقية</h2>${listHtml(c.examples)}<h2>التغذية الراجعة</h2><p>${escapeHtml(c.feedback)}</p><h2>طريقة القياس</h2><p>${escapeHtml(c.measurement)}</p>${sections?.duration === false ? '' : `<p>الزمن المقترح ${c.minutes} دقيقة</p>`}${sections?.alternatives === false || !c.lowCostAlternatives.length ? '' : '<h2>بدائل منخفضة التكلفة</h2>' + listHtml(c.lowCostAlternatives)}${sections?.teacherNotes === false || !c.teacherNotes ? '' : '<h2>ملاحظات المختصة</h2><p>' + escapeHtml(c.teacherNotes) + '</p>'}`;
  return renderArabicPdf({ bodyHtml, studentCode: input.studentCode, serial: input.serial, settings: input.settings });
}

/** Decode and re-encode logo pixels; EXIF, comments and appended payloads are not retained. */
export async function normalizeLogo(logo: { mime: 'image/png' | 'image/jpeg'; base64: string }): Promise<InstitutionLogo> {
  const bytes = Buffer.from(logo.base64, 'base64');
  if (bytes.length > 300000 || bytes.length < 24 || bytes.toString('base64') !== logo.base64) throw new ApiError(400, 'INVALID_LOGO', 'الشعار يجب أن يكون PNG أو JPEG سليمًا أصغر من 300 كيلوبايت.');
  let width = 0, height = 0;
  if (logo.mime === 'image/png') {
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new ApiError(400, 'INVALID_LOGO', 'صيغة الشعار غير صالحة.');
    width = bytes.readUInt32BE(16); height = bytes.readUInt32BE(20);
  } else {
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new ApiError(400, 'INVALID_LOGO', 'صيغة الشعار غير صالحة.');
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) break;
      const marker = bytes[offset + 1]!;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) { height = bytes.readUInt16BE(offset + 5); width = bytes.readUInt16BE(offset + 7); break; }
      const length = bytes.readUInt16BE(offset + 2);
      if (length < 2) break;
      offset += 2 + length;
    }
  }
  if (!width || !height || width > 1600 || height > 1600 || width * height > 1500000) throw new ApiError(400, 'INVALID_LOGO', 'أبعاد الشعار أكبر من الحد المسموح أو غير صالحة.');
  const browser = await launchBrowser();
  try {
    const page = await privatePage(browser);
    const result = await page.evaluate(async input => {
      const response = await fetch(`data:${input.mime};base64,${input.base64}`);
      const image = await createImageBitmap(await response.blob());
      const factor = Math.min(1, 512 / Math.max(image.width, image.height));
      const canvas = new OffscreenCanvas(Math.max(1, Math.round(image.width * factor)), Math.max(1, Math.round(image.height * factor)));
      canvas.getContext('2d')!.drawImage(image, 0, 0, canvas.width, canvas.height);
      const data = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/png' })).arrayBuffer());
      image.close();
      return { bytes: [...data], width: canvas.width, height: canvas.height };
    }, logo);
    return { mime: 'image/png', base64: Buffer.from(result.bytes).toString('base64'), width: result.width, height: result.height };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, 'INVALID_LOGO', 'تعذر قراءة صورة شعار سليمة.');
  } finally { await browser.close(); }
}

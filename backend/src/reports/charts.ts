import { sessionAccuracy } from '../planning/domain.js';
import type { ReportGoal } from './model.js';

export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
export interface ChartPanel { svg: string; part: number; totalParts: number }

/** Each panel has at most twelve points; absence/cancellation is never rendered as zero accuracy. */
export function goalCharts(goal: ReportGoal): ChartPanel[] {
  const parts = Math.max(1, Math.ceil(goal.sessions.length / 12));
  return Array.from({ length: parts }, (_, part) => {
    const sessions = goal.sessions.slice(part * 12, (part + 1) * 12);
    const left = 55, top = 28, height = 170, width = 720, plotWidth = 640;
    const y = (value: number) => top + height - value / 100 * height;
    const grid = [0, 25, 50, 75, 100].map(value => `<line x1="${left}" x2="${left + plotWidth}" y1="${y(value)}" y2="${y(value)}" stroke="#c7cccf"/><text x="${left - 9}" y="${y(value) + 4}" text-anchor="end" font-size="12" direction="ltr">${value}%</text>`).join('');
    const target = goal.targetPercent === null ? '' : `<line x1="${left}" x2="${left + plotWidth}" y1="${y(goal.targetPercent)}" y2="${y(goal.targetPercent)}" stroke="#111" stroke-width="2" stroke-dasharray="7 5"/><text x="${left + plotWidth}" y="${Math.max(14, y(goal.targetPercent) - 6)}" text-anchor="end" font-size="12" direction="ltr">${Number(goal.targetPercent.toFixed(2))}%</text>`;
    const cell = plotWidth / Math.max(sessions.length, 1);
    const marks = sessions.map((session, index) => {
      const x = left + cell * (index + 0.5);
      const accuracy = sessionAccuracy(session);
      const barWidth = Math.min(34, cell * 0.55);
      const mark = accuracy === null
        ? `<circle cx="${x}" cy="${y(0) - 8}" r="7" fill="white" stroke="#333" stroke-width="2"/><text x="${x}" y="${y(0) - 22}" text-anchor="middle" font-size="14">${session.status === 'absent' ? 'غ' : 'أ'}</text>`
        : `<rect x="${x - barWidth / 2}" y="${y(accuracy)}" width="${barWidth}" height="${Math.max(1, accuracy / 100 * height)}" fill="#21717a" stroke="#123b40"/><text x="${x}" y="${Math.max(16, y(accuracy) - 5)}" text-anchor="middle" font-size="12" direction="ltr">${Number(accuracy.toFixed(1))}%</text>`;
      const year = session.occurredOn.slice(0, 4), monthDay = session.occurredOn.slice(5);
      return `${mark}<text x="${x}" y="${y(0) + 22}" text-anchor="middle" font-size="10" direction="ltr" aria-label="${escapeHtml(session.occurredOn)}"><tspan x="${x}">${escapeHtml(year)}</tspan><tspan x="${x}" dy="12">${escapeHtml(monthDay)}</tspan></text>`;
    }).join('');
    const empty = sessions.length ? '' : `<text x="${left + plotWidth / 2}" y="${top + height / 2}" text-anchor="middle" font-size="19" direction="rtl">لا توجد جلسات مسجلة ضمن الفترة</text>`;
    return { part: part + 1, totalParts: parts,
      svg: `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="246" viewBox="0 0 ${width} 246" role="img" aria-label="${escapeHtml('دقة الجلسات للهدف ' + goal.behavior)}"><title>${escapeHtml(goal.behavior)}</title><rect width="${width}" height="246" fill="white"/><g font-family="NotoSansArabic,Arial,sans-serif" fill="#111">${grid}${target}${marks}${empty}</g></svg>` };
  });
}

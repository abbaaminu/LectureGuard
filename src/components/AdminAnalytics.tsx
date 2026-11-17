import React, { useMemo, useState } from 'react';
import {
  AlertTriangle,
  Download,
  FileText,
  Search,
} from 'lucide-react';
import { Student, TeacherSubmissionLog } from '../types/attendance';

interface AdminAnalyticsProps {
  students: Student[];
  teacherLogs: TeacherSubmissionLog[];
  pendingSyncCount: number;
}

export const AdminAnalytics: React.FC<AdminAnalyticsProps> = ({
  students,
  teacherLogs,
  pendingSyncCount,
}) => {
  const [searchQuery, setSearchQuery] = useState('');
  const [onlyFlagged, setOnlyFlagged] = useState(false);

  const enrichedStudents = useMemo(() => {
    return students
      .map((s) => {
        const cumulativePct = Number(
          ((s.term1Pct + s.term2Pct + s.term3Pct) / 3).toFixed(1),
        );
        const isChronic = cumulativePct < 80;
        return {
          ...s,
          cumulativePct,
          isChronic,
        };
      })
      .sort((a, b) => a.cumulativePct - b.cumulativePct);
  }, [students]);

  const schoolMetrics = useMemo(() => {
    const avg =
      enrichedStudents.reduce((sum, s) => sum + s.cumulativePct, 0) /
      Math.max(1, enrichedStudents.length);
    const chronicCount = enrichedStudents.filter((s) => s.isChronic).length;
    const submittedCount = teacherLogs.filter((l) => l.syncState !== 'missing').length;
    return {
      schoolAvgPct: avg.toFixed(1),
      chronicCount,
      submittedCount,
      totalScheduledLogs: teacherLogs.length,
    };
  }, [enrichedStudents, teacherLogs]);

  const filteredStudents = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    return enrichedStudents.filter((s) => {
      const flagMatch = !onlyFlagged || s.isChronic;
      const queryMatch =
        q === '' ||
        `${s.firstName} ${s.lastName}`.toLowerCase().includes(q) ||
        `${s.lastName}, ${s.firstName}`.toLowerCase().includes(q) ||
        s.studentCode.toLowerCase().includes(q);
      return flagMatch && queryMatch;
    });
  }, [enrichedStudents, searchQuery, onlyFlagged]);

  const handleExportCsv = () => {
    const headers = [
      'Student Code',
      'Last Name',
      'First Name',
      'Grade',
      'Homeroom',
      'Term 1 %',
      'Term 2 %',
      'Term 3 %',
      'Cumulative %',
      'Unexcused Absences',
      'Chronic Absenteeism (<80%)',
    ];
    const rows = enrichedStudents.map((s) => [
      s.studentCode,
      s.lastName,
      s.firstName,
      String(s.gradeLevel),
      s.homeroom,
      String(s.term1Pct),
      String(s.term2Pct),
      String(s.term3Pct),
      String(s.cumulativePct),
      String(s.unexcusedAbsences),
      s.isChronic ? 'FLAGGED (<80%)' : 'Normal',
    ]);
    const csvContent = [headers, ...rows]
      .map((row) => row.map((cell) => `"${cell.replace(/"/g, '""')}"`).join(','))
      .join('\n');

    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'lectureguard-school-attendance-2026-11-17.csv';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  const handleExportPdf = () => {
    window.print();
  };

  return (
    <div className="space-y-6">
      {/* Header & Exports */}
      <div className="rounded-2xl border border-slate-200 bg-white p-6">
        <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
          <div>
            <p className="text-xs text-slate-500">
              Oakridge High School · Academic Year 2026–2027 · Supabase Analytics
            </p>
            <h1 className="mt-1 text-2xl font-bold tracking-tight text-slate-900">
              School-Wide Attendance & Compliance Reporting
            </h1>
          </div>

          <div className="flex flex-wrap items-center gap-2.5 no-print">
            <button
              type="button"
              onClick={handleExportCsv}
              className="h-11 inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 text-sm font-semibold text-slate-900 hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0"
            >
              <Download className="h-4 w-4" />
              <span>Export CSV</span>
            </button>
            <button
              type="button"
              onClick={handleExportPdf}
              className="h-11 inline-flex items-center gap-2 rounded-xl bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-800 transition-colors whitespace-nowrap shrink-0"
            >
              <FileText className="h-4 w-4" />
              <span>Print / PDF Summary</span>
            </button>
          </div>
        </div>

        {/* School-Wide KPI Strip */}
        <div className="mt-6 pt-5 border-t border-slate-100 grid grid-cols-2 lg:grid-cols-4 gap-6">
          <div>
            <p className="text-xs text-slate-500">Cumulative Attendance Rate</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-slate-900">
              {schoolMetrics.schoolAvgPct}%
            </p>
            <p className="mt-0.5 text-xs text-emerald-700">Target ≥ 92.0%</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Chronic Absenteeism (&lt;80%)</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-red-600">
              {schoolMetrics.chronicCount} students
            </p>
            <p className="mt-0.5 text-xs text-slate-500">Automatic intervention alert</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Teacher Submissions Today</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-slate-900">
              {schoolMetrics.submittedCount} / {schoolMetrics.totalScheduledLogs}
            </p>
            <p className="mt-0.5 text-xs text-slate-500">1 missing period audit</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Offline Device Queue</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-amber-700">
              {pendingSyncCount} records
            </p>
            <p className="mt-0.5 text-xs text-slate-500">Awaiting Wi-Fi batch sync</p>
          </div>
        </div>
      </div>

      {/* Chronic Absenteeism Watchlist (<80%) */}
      <div className="rounded-2xl border border-slate-200 bg-white p-6">
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-center gap-2.5">
            <AlertTriangle className="h-5 w-5 text-red-600 shrink-0" />
            <div>
              <h2 className="text-base font-bold text-slate-900">
                Chronic Absenteeism Watchlist (Below 80% Threshold)
              </h2>
              <p className="text-xs text-slate-500">
                Computed automatically by PostgreSQL view <span className="font-mono">v_student_attendance_summary</span>
              </p>
            </div>
          </div>
          <span className="text-xs font-semibold text-red-700 tabular-nums whitespace-nowrap">
            {schoolMetrics.chronicCount} Flagged
          </span>
        </div>

        <div className="mt-4 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          {enrichedStudents
            .filter((s) => s.isChronic)
            .map((student) => (
              <div
                key={student.id}
                className="rounded-xl border border-red-200 bg-red-50/40 p-4 flex flex-col justify-between gap-3"
              >
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="text-sm font-bold text-slate-900">
                      {student.lastName}, {student.firstName}
                    </p>
                    <p className="text-xs text-slate-500 font-mono tabular-nums">
                      {student.studentCode} · Grade {student.gradeLevel} · {student.homeroom}
                    </p>
                  </div>
                  <span className="text-sm font-bold tabular-nums text-red-700">
                    {student.cumulativePct}%
                  </span>
                </div>

                {/* Term 1 -> Term 2 -> Term 3 Trend Bars */}
                <div className="space-y-1.5">
                  <div className="grid grid-cols-3 gap-2 text-[11px] text-slate-600 tabular-nums">
                    <div>
                      <span>T1: {student.term1Pct}%</span>
                      <div className="mt-1 h-1.5 rounded-full bg-slate-200 overflow-hidden">
                        <div className="h-full bg-slate-600" style={{ width: `${student.term1Pct}%` }} />
                      </div>
                    </div>
                    <div>
                      <span>T2: {student.term2Pct}%</span>
                      <div className="mt-1 h-1.5 rounded-full bg-slate-200 overflow-hidden">
                        <div className="h-full bg-amber-600" style={{ width: `${student.term2Pct}%` }} />
                      </div>
                    </div>
                    <div>
                      <span>T3: {student.term3Pct}%</span>
                      <div className="mt-1 h-1.5 rounded-full bg-slate-200 overflow-hidden">
                        <div className="h-full bg-red-600" style={{ width: `${student.term3Pct}%` }} />
                      </div>
                    </div>
                  </div>
                  <p className="text-[11px] text-slate-500 truncate">
                    {student.unexcusedAbsences} unexcused absences · {student.guardianEmail}
                  </p>
                </div>
              </div>
            ))}
        </div>
      </div>

      {/* Teacher Submission Audit Logs */}
      <div className="rounded-2xl border border-slate-200 bg-white overflow-hidden">
        <div className="p-5 border-b border-slate-200">
          <h2 className="text-base font-bold text-slate-900">Teacher Submission Audit Logs</h2>
          <p className="text-xs text-slate-500">
            Verifies faculty attendance submission completeness and offline-to-Supabase sync status across departments.
          </p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-xs font-semibold text-slate-500">
                <th className="py-3 px-4">Date</th>
                <th className="py-3 px-4">Course</th>
                <th className="py-3 px-4">Teacher</th>
                <th className="py-3 px-4 text-right">Enrolled</th>
                <th className="py-3 px-4 text-right">Checked In</th>
                <th className="py-3 px-4 text-right">Absent</th>
                <th className="py-3 px-4 text-right">Submission & Sync</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 text-sm">
              {teacherLogs.map((log) => (
                <tr key={log.id} className="hover:bg-slate-50/70">
                  <td className="py-2.5 px-4 font-mono text-xs text-slate-500 tabular-nums whitespace-nowrap">
                    {log.sessionDate}
                  </td>
                  <td className="py-2.5 px-4 font-semibold text-slate-900 whitespace-nowrap">
                    {log.lectureTitle}
                  </td>
                  <td className="py-2.5 px-4 text-slate-700 whitespace-nowrap">
                    {log.teacherName} · <span className="text-xs text-slate-500">{log.department}</span>
                  </td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-700">{log.enrolledCount}</td>
                  <td className="py-2.5 px-4 text-right tabular-nums font-semibold text-emerald-700">{log.checkedInCount}</td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-red-600">{log.absentCount}</td>
                  <td className="py-2.5 px-4 text-right text-xs font-semibold whitespace-nowrap">
                    {log.syncState === 'synced' && (
                      <span className="text-emerald-700">Submitted · Synced</span>
                    )}
                    {log.syncState === 'offline_queued' && (
                      <span className="text-amber-700">Submitted · Offline Queued</span>
                    )}
                    {log.syncState === 'missing' && (
                      <span className="text-red-700">Not Yet Submitted</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Individual Student Term Attendance Trends */}
      <div className="rounded-2xl border border-slate-200 bg-white overflow-hidden">
        <div className="p-4 border-b border-slate-200 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div>
            <h2 className="text-base font-bold text-slate-900">
              Individual Student Term Attendance Trends
            </h2>
            <p className="text-xs text-slate-500">
              Sorted ascending by cumulative percentage to surface at-risk students first.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2 no-print">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search student..."
                className="h-9 rounded-xl border border-slate-200 bg-slate-50 pl-9 pr-3 text-xs text-slate-900 focus:border-slate-900 focus:bg-white focus:outline-none"
              />
            </div>
            <button
              type="button"
              onClick={() => setOnlyFlagged((v) => !v)}
              className={`h-9 rounded-xl border px-3 text-xs font-semibold transition-colors whitespace-nowrap ${
                onlyFlagged
                  ? 'border-red-300 bg-red-50 text-red-800'
                  : 'border-slate-200 bg-white text-slate-700 hover:bg-slate-50'
              }`}
            >
              {onlyFlagged ? 'Showing Flagged (<80%)' : 'Filter <80% Only'}
            </button>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-xs font-semibold text-slate-500">
                <th className="py-3 px-4">Student</th>
                <th className="py-3 px-4">Code</th>
                <th className="py-3 px-4 text-right">Term 1</th>
                <th className="py-3 px-4 text-right">Term 2</th>
                <th className="py-3 px-4 text-right">Term 3</th>
                <th className="py-3 px-4 text-right">Cumulative</th>
                <th className="py-3 px-4 text-right">Unexcused</th>
                <th className="py-3 px-4 text-right">Standing</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 text-sm">
              {filteredStudents.slice(0, 25).map((s) => (
                <tr key={s.id} className="hover:bg-slate-50/70">
                  <td className="py-2.5 px-4 font-semibold text-slate-900 whitespace-nowrap">
                    {s.lastName}, {s.firstName}
                  </td>
                  <td className="py-2.5 px-4 font-mono text-xs text-slate-500 tabular-nums whitespace-nowrap">
                    {s.studentCode}
                  </td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-600">{s.term1Pct}%</td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-600">{s.term2Pct}%</td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-600">{s.term3Pct}%</td>
                  <td className="py-2.5 px-4 text-right tabular-nums font-bold text-slate-900">
                    {s.cumulativePct}%
                  </td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-600">
                    {s.unexcusedAbsences}
                  </td>
                  <td className="py-2.5 px-4 text-right text-xs font-semibold whitespace-nowrap">
                    {s.isChronic ? (
                      <span className="text-red-700">Chronic Alert (&lt;80%)</span>
                    ) : (
                      <span className="text-emerald-700">Good Standing</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

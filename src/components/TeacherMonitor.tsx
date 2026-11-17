import React, { useMemo, useState } from 'react';
import {
  CloudUpload,
  KeyRound,
  Lock,
  Play,
  RotateCcw,
  Search,
  Signal,
  Users,
  Wifi,
  WifiOff,
} from 'lucide-react';
import {
  AttendanceRecord,
  AttendanceSession,
  AttendanceStatus,
  Lecture,
  NetworkTransport,
  Student,
  SyncBatchProgress,
  TeacherSubmissionLog,
} from '../types/attendance';

interface TeacherMonitorProps {
  lectures: Lecture[];
  activeLecture: Lecture;
  students: Student[];
  session: AttendanceSession;
  recordsByStudentId: Record<string, AttendanceRecord>;
  teacherLogs: TeacherSubmissionLog[];
  lecturerPin: string;
  networkTransport: NetworkTransport;
  isSyncing: boolean;
  syncProgress: SyncBatchProgress | null;
  pendingSyncCount: number;
  onSelectLecture: (lectureId: string) => void;
  onLaunchPassMode: () => void;
  onOverrideStatus: (student: Student, status: AttendanceStatus, reason: string) => void;
  onUpdatePin: (newPin: string) => void;
  onSimulateBulkCheckIn: (count: number) => void;
  onResetSession: () => void;
  onChangeTransport: (transport: NetworkTransport) => void;
  onSyncNow: () => void;
}

export const TeacherMonitor: React.FC<TeacherMonitorProps> = ({
  lectures,
  activeLecture,
  students,
  session,
  recordsByStudentId,
  teacherLogs,
  lecturerPin,
  networkTransport,
  isSyncing,
  syncProgress,
  pendingSyncCount,
  onSelectLecture,
  onLaunchPassMode,
  onOverrideStatus,
  onUpdatePin,
  onSimulateBulkCheckIn,
  onResetSession,
  onChangeTransport,
  onSyncNow,
}) => {
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<'all' | AttendanceStatus>('all');
  const [pinDraft, setPinDraft] = useState(lecturerPin);
  const [pinSavedMsg, setPinSavedMsg] = useState(false);
  const [overrideReasons, setOverrideReasons] = useState<Record<string, string>>({});
  const [visibleLimit, setVisibleLimit] = useState(50);

  const counts = useMemo(() => {
    let present = 0;
    let late = 0;
    let excused = 0;
    students.forEach((s) => {
      const status = recordsByStudentId[s.id]?.status ?? 'absent';
      if (status === 'present') present += 1;
      else if (status === 'late') late += 1;
      else if (status === 'excused') excused += 1;
    });
    const checkedIn = present + late;
    const absent = students.length - checkedIn - excused;
    return {
      enrolled: students.length,
      checkedIn,
      present,
      late,
      excused,
      absent,
    };
  }, [students, recordsByStudentId]);

  const filteredStudents = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    return students.filter((s) => {
      const recStatus: AttendanceStatus = recordsByStudentId[s.id]?.status ?? 'absent';
      const matchesStatus = statusFilter === 'all' || recStatus === statusFilter;
      const matchesQuery =
        q === '' ||
        `${s.firstName} ${s.lastName}`.toLowerCase().includes(q) ||
        `${s.lastName}, ${s.firstName}`.toLowerCase().includes(q) ||
        s.studentCode.toLowerCase().includes(q);
      return matchesStatus && matchesQuery;
    });
  }, [students, recordsByStudentId, statusFilter, searchQuery]);

  const handleSavePin = (e: React.FormEvent) => {
    e.preventDefault();
    if (/^\d{4}$/.test(pinDraft)) {
      onUpdatePin(pinDraft);
      setPinSavedMsg(true);
      setTimeout(() => setPinSavedMsg(false), 2200);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header & Session Controls */}
      <div className="rounded-2xl border border-slate-200 bg-white p-6">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
          <div>
            <div className="flex flex-wrap items-center gap-2 text-xs text-slate-500">
              <span>Teacher Command</span>
              <span aria-hidden="true">·</span>
              <span>{activeLecture.teacherName}</span>
              <span aria-hidden="true">·</span>
              <span>{activeLecture.roomNumber}</span>
              <span aria-hidden="true">·</span>
              <span className="tabular-nums">Late Threshold {activeLecture.lateGraceMinutes} min</span>
            </div>
            <h1 className="mt-1 text-2xl font-bold tracking-tight text-slate-900">
              {activeLecture.title}
            </h1>
          </div>

          <div className="flex flex-wrap items-center gap-2.5">
            <select
              aria-label="Select lecture"
              value={activeLecture.id}
              onChange={(e) => onSelectLecture(e.target.value)}
              className="h-11 rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm font-medium text-slate-900 focus:border-slate-900 focus:outline-none"
            >
              {lectures.map((lec) => (
                <option key={lec.id} value={lec.id}>
                  {lec.courseCode} — {lec.title} ({lec.enrolledStudentIds.length})
                </option>
              ))}
            </select>

            <button
              type="button"
              onClick={onLaunchPassMode}
              className="h-11 inline-flex items-center gap-2 rounded-xl bg-slate-900 px-4 text-sm font-semibold text-white hover:bg-slate-800 active:scale-[0.98] transition-all whitespace-nowrap shrink-0"
            >
              <Lock className="h-4 w-4" />
              <span>Lock &amp; Launch Pass Mode</span>
            </button>
          </div>
        </div>

        {/* Live Headcount Strip */}
        <div className="mt-6 pt-5 border-t border-slate-100 grid grid-cols-2 sm:grid-cols-5 gap-4">
          <div>
            <p className="text-xs text-slate-500">Enrolled</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-slate-900">{counts.enrolled}</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Checked In</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-emerald-600">{counts.checkedIn}</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Late</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-amber-600">{counts.late}</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Excused</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-slate-700">{counts.excused}</p>
          </div>
          <div>
            <p className="text-xs text-slate-500">Absent / Unmarked</p>
            <p className="mt-1 text-2xl font-bold tabular-nums text-red-600">{counts.absent}</p>
          </div>
        </div>
      </div>

      {/* Sync Engine, PIN Configuration & Large-Hall Simulation Bar */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        {/* Connection-Agnostic Offline SQLite & Chunked Cellular Sync */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 flex flex-col justify-between gap-4">
          <div>
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-bold text-slate-900">Cellular &amp; Wi-Fi Sync Queue</h2>
              <span className="text-xs font-mono tabular-nums text-slate-500">
                {pendingSyncCount} pending
              </span>
            </div>
            <p className="mt-1 text-xs text-slate-500 leading-relaxed">
              SQLite WAL writes locally. Auto-syncs in 50-record chunks on Mobile Data or Wi-Fi with retry backoff.
            </p>
            {syncProgress && (
              <p className="mt-2 text-xs font-semibold text-emerald-700 tabular-nums">
                Batch {syncProgress.currentBatch}/{syncProgress.totalBatches} ({syncProgress.uploadedCount}/{syncProgress.totalQueued} uploaded)
              </p>
            )}
          </div>
          <div className="space-y-2">
            <div className="grid grid-cols-3 gap-1 p-1 bg-slate-100 rounded-xl">
              <button
                type="button"
                onClick={() => onChangeTransport('offline')}
                className={`min-h-[34px] inline-flex items-center justify-center gap-1 rounded-lg text-[11px] font-semibold transition-colors ${
                  networkTransport === 'offline'
                    ? 'bg-white text-amber-700 shadow-sm'
                    : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                <WifiOff className="h-3 w-3" />
                <span>Offline</span>
              </button>
              <button
                type="button"
                onClick={() => onChangeTransport('mobile')}
                className={`min-h-[34px] inline-flex items-center justify-center gap-1 rounded-lg text-[11px] font-semibold transition-colors ${
                  networkTransport === 'mobile'
                    ? 'bg-white text-emerald-700 shadow-sm'
                    : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                <Signal className="h-3 w-3" />
                <span>Mobile</span>
              </button>
              <button
                type="button"
                onClick={() => onChangeTransport('wifi')}
                className={`min-h-[34px] inline-flex items-center justify-center gap-1 rounded-lg text-[11px] font-semibold transition-colors ${
                  networkTransport === 'wifi'
                    ? 'bg-white text-emerald-700 shadow-sm'
                    : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                <Wifi className="h-3 w-3" />
                <span>Wi-Fi</span>
              </button>
            </div>

            <button
              type="button"
              disabled={networkTransport === 'offline' || isSyncing || pendingSyncCount === 0}
              onClick={onSyncNow}
              className="w-full min-h-[40px] inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-emerald-700 disabled:bg-slate-200 disabled:text-slate-500 transition-colors whitespace-nowrap"
            >
              <CloudUpload className="h-3.5 w-3.5" />
              <span>
                {isSyncing
                  ? 'Uploading 50-Record Chunks...'
                  : `Sync Batch (${Math.ceil(pendingSyncCount / 50)} chunk${
                      Math.ceil(pendingSyncCount / 50) === 1 ? '' : 's'
                    })`}
              </span>
            </button>
          </div>
        </div>

        {/* Lecturer PIN Management */}
        <form
          onSubmit={handleSavePin}
          className="rounded-2xl border border-slate-200 bg-white p-5 flex flex-col justify-between gap-4"
        >
          <div>
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-bold text-slate-900">Secure Exit PIN (4-Digit)</h2>
              <KeyRound className="h-4 w-4 text-slate-400" />
            </div>
            <p className="mt-1 text-xs text-slate-500 leading-relaxed">
              Stored via flutter_secure_storage. Required to unlock Student Pass Mode on back-press or exit.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <input
              type="text"
              inputMode="numeric"
              maxLength={4}
              value={pinDraft}
              onChange={(e) => setPinDraft(e.target.value.replace(/\D/g, '').slice(0, 4))}
              aria-label="4-digit lecturer PIN"
              className="h-10 w-28 rounded-xl border border-slate-200 bg-slate-50 px-3 text-center font-mono text-sm font-bold tracking-widest text-slate-900 focus:border-slate-900 focus:outline-none"
            />
            <button
              type="submit"
              disabled={!/^\d{4}$/.test(pinDraft)}
              className="min-h-[40px] flex-1 rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-900 hover:bg-slate-50 disabled:opacity-50 transition-colors whitespace-nowrap"
            >
              {pinSavedMsg ? 'PIN Updated' : 'Save PIN'}
            </button>
          </div>
        </form>

        {/* Auditorium Scale Simulator */}
        <div className="rounded-2xl border border-slate-200 bg-white p-5 flex flex-col justify-between gap-4">
          <div>
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-bold text-slate-900">Auditorium Pass Simulator</h2>
              <Users className="h-4 w-4 text-slate-400" />
            </div>
            <p className="mt-1 text-xs text-slate-500 leading-relaxed">
              Check in 75 desks at once to test multi-chunk (50/req) cellular sync across the {students.length}-student hall.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => onSimulateBulkCheckIn(75)}
              className="min-h-[40px] flex-1 inline-flex items-center justify-center gap-1.5 rounded-xl bg-slate-100 px-3 text-xs font-semibold text-slate-900 hover:bg-slate-200 transition-colors whitespace-nowrap"
            >
              <Play className="h-3.5 w-3.5" />
              <span>Check In +75 Desks</span>
            </button>
            <button
              type="button"
              onClick={onResetSession}
              className="min-h-[40px] inline-flex items-center justify-center gap-1.5 rounded-xl border border-slate-200 bg-white px-3 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition-colors whitespace-nowrap"
            >
              <RotateCcw className="h-3.5 w-3.5" />
              <span>Reset</span>
            </button>
          </div>
        </div>
      </div>

      {/* Roster Table with Manual Overrides */}
      <div className="rounded-2xl border border-slate-200 bg-white overflow-hidden">
        <div className="p-4 border-b border-slate-200 flex flex-col md:flex-row md:items-center md:justify-between gap-3">
          <div className="relative flex-1 max-w-md">
            <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder={`Filter ${students.length} students by name or code...`}
              className="w-full h-10 rounded-xl border border-slate-200 bg-slate-50 pl-9 pr-3 text-sm text-slate-900 focus:border-slate-900 focus:bg-white focus:outline-none"
            />
          </div>

          <div className="flex items-center gap-1 p-1 bg-slate-100 rounded-xl overflow-x-auto">
            {(['all', 'present', 'late', 'excused', 'absent'] as const).map((status) => (
              <button
                key={status}
                type="button"
                onClick={() => setStatusFilter(status)}
                className={`px-3 py-1.5 rounded-lg text-xs font-semibold capitalize transition-colors whitespace-nowrap shrink-0 ${
                  statusFilter === status
                    ? 'bg-white text-slate-900 shadow-sm'
                    : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                {status}
              </button>
            ))}
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-xs font-semibold text-slate-500">
                <th className="py-3 px-4">Student</th>
                <th className="py-3 px-4">ID</th>
                <th className="py-3 px-4">Verification</th>
                <th className="py-3 px-4">Override Reason</th>
                <th className="py-3 px-4">Status Override</th>
                <th className="py-3 px-4 text-right">Sync</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 text-sm">
              {filteredStudents.slice(0, visibleLimit).map((student) => {
                const rec = recordsByStudentId[student.id];
                const currentStatus: AttendanceStatus = rec?.status ?? 'absent';
                const reasonVal = overrideReasons[student.id] ?? rec?.overrideReason ?? '';

                return (
                  <tr key={student.id} className="hover:bg-slate-50/80 transition-colors">
                    <td className="py-2.5 px-4 font-semibold text-slate-900 whitespace-nowrap">
                      {student.lastName}, {student.firstName}
                    </td>
                    <td className="py-2.5 px-4 font-mono text-xs text-slate-500 tabular-nums whitespace-nowrap">
                      {student.studentCode}
                    </td>
                    <td className="py-2.5 px-4 text-xs text-slate-600 whitespace-nowrap">
                      {rec?.biometricVerified
                        ? `${rec.biometricMethod === 'face_id' ? 'Face ID' : 'Touch ID'} · ${
                            rec.checkedInAt
                              ? new Date(rec.checkedInAt).toLocaleTimeString([], {
                                  hour: '2-digit',
                                  minute: '2-digit',
                                })
                              : ''
                          }`
                        : rec?.biometricMethod === 'manual_override'
                        ? 'Teacher Override'
                        : 'Not Scanned'}
                    </td>
                    <td className="py-2.5 px-4">
                      <input
                        type="text"
                        value={reasonVal}
                        onChange={(e) =>
                          setOverrideReasons((prev) => ({
                            ...prev,
                            [student.id]: e.target.value,
                          }))
                        }
                        placeholder="Optional note (e.g. Nurse)"
                        className="h-8 w-44 rounded-lg border border-slate-200 bg-white px-2.5 text-xs text-slate-700 placeholder:text-slate-400 focus:border-slate-900 focus:outline-none"
                      />
                    </td>
                    <td className="py-2.5 px-4">
                      <select
                        aria-label={`Attendance status for ${student.firstName} ${student.lastName}`}
                        value={currentStatus}
                        onChange={(e) =>
                          onOverrideStatus(
                            student,
                            e.target.value as AttendanceStatus,
                            reasonVal || 'Manual teacher adjustment',
                          )
                        }
                        className={`h-8 rounded-lg border px-2.5 text-xs font-semibold focus:outline-none ${
                          currentStatus === 'present'
                            ? 'border-emerald-300 bg-emerald-50 text-emerald-800'
                            : currentStatus === 'late'
                            ? 'border-amber-300 bg-amber-50 text-amber-800'
                            : currentStatus === 'excused'
                            ? 'border-slate-300 bg-slate-100 text-slate-800'
                            : 'border-red-200 bg-red-50 text-red-800'
                        }`}
                      >
                        <option value="present">Present</option>
                        <option value="late">Late</option>
                        <option value="excused">Excused</option>
                        <option value="absent">Absent</option>
                      </select>
                    </td>
                    <td className="py-2.5 px-4 text-right text-xs font-mono whitespace-nowrap">
                      {!rec ? (
                        <span className="text-slate-400">—</span>
                      ) : rec.syncStatus === 'synced' ? (
                        <span className="text-emerald-700 font-medium">Synced</span>
                      ) : (
                        <span className="text-amber-700 font-medium">SQLite Pending</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {filteredStudents.length > visibleLimit && (
          <div className="p-4 border-t border-slate-100 flex items-center justify-between bg-slate-50">
            <span className="text-xs text-slate-500 tabular-nums">
              Showing {visibleLimit} of {filteredStudents.length} students
            </span>
            <button
              type="button"
              onClick={() => setVisibleLimit((v) => v + 100)}
              className="min-h-[36px] rounded-xl border border-slate-200 bg-white px-4 text-xs font-semibold text-slate-900 hover:bg-slate-100"
            >
              Load Next 100 Rows
            </button>
          </div>
        )}
      </div>

      {/* Class History Logs */}
      <div className="rounded-2xl border border-slate-200 bg-white p-5">
        <h2 className="text-base font-bold text-slate-900">Recent Class Session History</h2>
        <p className="mt-0.5 text-xs text-slate-500">
          Session ID {session.id.slice(0, 12)} · Local SQLite WAL cache synced in 50-record chunks
        </p>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-slate-200 text-xs font-semibold text-slate-500">
                <th className="py-2.5 pr-4">Date</th>
                <th className="py-2.5 px-4">Course</th>
                <th className="py-2.5 px-4 text-right">Enrolled</th>
                <th className="py-2.5 px-4 text-right">Checked In</th>
                <th className="py-2.5 px-4 text-right">Absent</th>
                <th className="py-2.5 pl-4 text-right">Cloud Sync</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 text-xs">
              {teacherLogs.slice(0, 4).map((log) => (
                <tr key={log.id}>
                  <td className="py-2.5 pr-4 font-mono tabular-nums text-slate-600">{log.sessionDate}</td>
                  <td className="py-2.5 px-4 font-semibold text-slate-900">{log.lectureTitle}</td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-slate-700">{log.enrolledCount}</td>
                  <td className="py-2.5 px-4 text-right tabular-nums font-semibold text-emerald-700">{log.checkedInCount}</td>
                  <td className="py-2.5 px-4 text-right tabular-nums text-red-600">{log.absentCount}</td>
                  <td className="py-2.5 pl-4 text-right font-medium">
                    {log.syncState === 'synced'
                      ? 'Synced'
                      : log.syncState === 'offline_queued'
                      ? 'Queued'
                      : 'Pending Submission'}
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

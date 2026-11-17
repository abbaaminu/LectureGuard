import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  CheckCircle2,
  Clock,
  Fingerprint,
  Lock,
  Search,
  Signal,
  Unlock,
  Wifi,
  WifiOff,
  X,
} from 'lucide-react';
import {
  AttendanceRecord,
  AttendanceSession,
  BiometricMethod,
  Lecture,
  NetworkTransport,
  Student,
  SyncBatchProgress,
} from '../types/attendance';
import { BiometricPromptModal } from './BiometricPromptModal';

interface StudentPassModeProps {
  lecture: Lecture;
  students: Student[];
  session: AttendanceSession;
  recordsByStudentId: Record<string, AttendanceRecord>;
  networkTransport: NetworkTransport;
  pendingSyncCount: number;
  syncProgress: SyncBatchProgress | null;
  onChangeTransport: (transport: NetworkTransport) => void;
  onStudentVerified: (student: Student, method: BiometricMethod) => void;
  onRequestExitLockdown: () => void;
}

const ROW_HEIGHT = 76;
const VIEWPORT_HEIGHT = 532; // 7 visible rows cleanly framed
const OVERSCAN = 5;
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');

export const StudentPassMode: React.FC<StudentPassModeProps> = ({
  lecture,
  students,
  session,
  recordsByStudentId,
  networkTransport,
  pendingSyncCount,
  syncProgress,
  onChangeTransport,
  onStudentVerified,
  onRequestExitLockdown,
}) => {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [searchQuery, setSearchQuery] = useState('');
  const [activeLetter, setActiveLetter] = useState<string | null>(null);
  const [activeStudent, setActiveStudent] = useState<Student | null>(null);
  const [recentBanner, setRecentBanner] = useState<string | null>(null);

  const trimmedQuery = searchQuery.trim().toLowerCase();
  const isFiltering = trimmedQuery.length >= 2;

  const visibleStudents = useMemo(() => {
    if (!isFiltering) return students;
    return students.filter((s) => {
      return (
        `${s.firstName} ${s.lastName}`.toLowerCase().includes(trimmedQuery) ||
        `${s.lastName}, ${s.firstName}`.toLowerCase().includes(trimmedQuery) ||
        s.studentCode.toLowerCase().includes(trimmedQuery)
      );
    });
  }, [students, isFiltering, trimmedQuery]);

  // Precompute A-Z jump index map for O(1) instant scroll positioning
  const letterIndexMap = useMemo(() => {
    const map: Record<string, number> = {};
    visibleStudents.forEach((student, idx) => {
      const initial = student.lastName[0]?.toUpperCase() ?? '#';
      if (map[initial] === undefined) {
        map[initial] = idx;
      }
    });
    return map;
  }, [visibleStudents]);

  // Reset scroll to top when switching between full roster & search results
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = 0;
      setScrollTop(0);
    }
  }, [isFiltering, trimmedQuery, lecture.id]);

  const totalHeight = visibleStudents.length * ROW_HEIGHT;
  const startIndex = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN);
  const endIndex = Math.min(
    visibleStudents.length,
    Math.ceil((scrollTop + VIEWPORT_HEIGHT) / ROW_HEIGHT) + OVERSCAN,
  );
  const renderedSlice = visibleStudents.slice(startIndex, endIndex);

  const stats = useMemo(() => {
    let checkedIn = 0;
    let late = 0;
    students.forEach((s) => {
      const rec = recordsByStudentId[s.id];
      if (rec?.status === 'present') checkedIn += 1;
      if (rec?.status === 'late') {
        checkedIn += 1;
        late += 1;
      }
    });
    return {
      enrolled: students.length,
      checkedIn,
      late,
      remaining: students.length - checkedIn,
    };
  }, [students, recordsByStudentId]);

  const jumpToLetter = (letter: string) => {
    const idx = letterIndexMap[letter];
    if (idx === undefined || !scrollRef.current) return;
    const maxScroll = Math.max(0, totalHeight - VIEWPORT_HEIGHT);
    const targetTop = Math.min(maxScroll, idx * ROW_HEIGHT);
    scrollRef.current.scrollTop = targetTop;
    setScrollTop(targetTop);
    setActiveLetter(letter);
  };

  const handleVerified = (student: Student, method: BiometricMethod) => {
    setActiveStudent(null);
    onStudentVerified(student, method);
    setRecentBanner(
      `${student.firstName} ${student.lastName} verified via ${
        method === 'face_id' ? 'Face ID' : 'Touch ID'
      } — committed to SQLite WAL`,
    );
    setTimeout(() => {
      setRecentBanner(null);
    }, 3000);
  };

  return (
    <div className="space-y-4">
      {/* Lockdown Session Header */}
      <div className="rounded-2xl bg-slate-900 text-white p-5 border border-slate-800">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
          <div className="space-y-1">
            <div className="flex flex-wrap items-center gap-2 text-xs text-slate-300">
              <span className="inline-flex items-center gap-1.5 font-semibold text-emerald-400">
                <Lock className="h-3.5 w-3.5" />
                <span>Pass Mode Lockdown Active</span>
              </span>
              <span aria-hidden="true">·</span>
              <span>{lecture.courseCode}</span>
              <span aria-hidden="true">·</span>
              <span>{lecture.roomNumber}</span>
              <span aria-hidden="true">·</span>
              <span>
                Started{' '}
                {new Date(session.startedAt).toLocaleTimeString([], {
                  hour: '2-digit',
                  minute: '2-digit',
                })}
              </span>
            </div>
            <h1 className="text-xl sm:text-2xl font-bold tracking-tight text-white">
              {lecture.title}
            </h1>
            <p className="text-xs text-slate-400">
              Virtualized roster ({students.length} enrolled) · Jump via A–Z index or type 2+ characters to filter.
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2.5 shrink-0">
            {/* Connection-Agnostic Transport Selector */}
            <div className="flex items-center gap-1 p-1 rounded-xl bg-slate-800 border border-slate-700">
              <button
                type="button"
                onClick={() => onChangeTransport('offline')}
                className={`min-h-[36px] inline-flex items-center gap-1.5 rounded-lg px-2.5 text-xs font-semibold transition-colors whitespace-nowrap ${
                  networkTransport === 'offline'
                    ? 'bg-amber-500 text-slate-950'
                    : 'text-slate-300 hover:text-white'
                }`}
              >
                <WifiOff className="h-3.5 w-3.5" />
                <span>Offline</span>
              </button>
              <button
                type="button"
                onClick={() => onChangeTransport('mobile')}
                className={`min-h-[36px] inline-flex items-center gap-1.5 rounded-lg px-2.5 text-xs font-semibold transition-colors whitespace-nowrap ${
                  networkTransport === 'mobile'
                    ? 'bg-emerald-500 text-slate-950'
                    : 'text-slate-300 hover:text-white'
                }`}
              >
                <Signal className="h-3.5 w-3.5" />
                <span>Mobile Data</span>
              </button>
              <button
                type="button"
                onClick={() => onChangeTransport('wifi')}
                className={`min-h-[36px] inline-flex items-center gap-1.5 rounded-lg px-2.5 text-xs font-semibold transition-colors whitespace-nowrap ${
                  networkTransport === 'wifi'
                    ? 'bg-emerald-500 text-slate-950'
                    : 'text-slate-300 hover:text-white'
                }`}
              >
                <Wifi className="h-3.5 w-3.5" />
                <span>Wi-Fi</span>
              </button>
            </div>

            <button
              type="button"
              onClick={onRequestExitLockdown}
              className="min-h-[44px] inline-flex items-center gap-2 rounded-xl bg-white px-4 py-2 text-xs font-bold text-slate-900 hover:bg-slate-100 active:scale-[0.98] transition-all whitespace-nowrap shrink-0"
            >
              <Unlock className="h-4 w-4" />
              <span>Admin PIN Unlock</span>
            </button>
          </div>
        </div>

        {/* Live Counter Bar */}
        <div className="mt-5 pt-4 border-t border-slate-800 grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div>
            <p className="text-xs text-slate-400">Enrolled Roster</p>
            <p className="text-xl font-bold tabular-nums text-white">{stats.enrolled}</p>
          </div>
          <div>
            <p className="text-xs text-slate-400">Checked In</p>
            <p className="text-xl font-bold tabular-nums text-emerald-400">{stats.checkedIn}</p>
          </div>
          <div>
            <p className="text-xs text-slate-400">Remaining</p>
            <p className="text-xl font-bold tabular-nums text-slate-200">{stats.remaining}</p>
          </div>
          <div>
            <p className="text-xs text-slate-400">SQLite WAL Queue</p>
            <p className="text-xl font-bold tabular-nums text-amber-300">
              {pendingSyncCount} {pendingSyncCount === 1 ? 'record' : 'records'}
            </p>
          </div>
        </div>
      </div>

      {/* Chunked Cellular/Wi-Fi Sync Progress Banner */}
      {syncProgress && (
        <div
          role="status"
          className="rounded-xl border border-slate-200 bg-white px-4 py-3 flex items-center justify-between gap-4"
        >
          <div className="min-w-0 flex-1">
            <div className="flex items-center justify-between text-xs font-semibold text-slate-900">
              <span>
                Syncing via {syncProgress.transport === 'mobile' ? 'Mobile Data (4G/5G)' : 'Campus Wi-Fi'} · Chunk {syncProgress.currentBatch} of {syncProgress.totalBatches} (50 records/req)
              </span>
              <span className="font-mono tabular-nums text-emerald-700">
                {syncProgress.uploadedCount}/{syncProgress.totalQueued}
              </span>
            </div>
            <div className="mt-1.5 h-1.5 w-full rounded-full bg-slate-100 overflow-hidden">
              <div
                className="h-full bg-emerald-600 transition-all duration-200"
                style={{
                  width: `${Math.round(
                    (syncProgress.uploadedCount / Math.max(1, syncProgress.totalQueued)) * 100,
                  )}%`,
                }}
              />
            </div>
          </div>
        </div>
      )}

      {/* Confirmation Toast */}
      {recentBanner && (
        <div
          role="status"
          className="flex items-center justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-medium text-emerald-900"
        >
          <div className="flex items-center gap-2.5">
            <CheckCircle2 className="h-4 w-4 text-emerald-600 shrink-0" />
            <span>{recentBanner}</span>
          </div>
          <span className="text-xs font-mono text-emerald-700 shrink-0">WAL Committed</span>
        </div>
      )}

      {/* Top Instant Search Bar (Triggers dynamically at 2+ characters) */}
      <div className="rounded-2xl bg-white border border-slate-200 p-4">
        <div className="flex flex-col sm:flex-row sm:items-center gap-3">
          <div className="relative flex-1">
            <Search className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => {
                setSearchQuery(e.target.value);
                if (e.target.value.trim().length >= 2) setActiveLetter(null);
              }}
              placeholder={`Type 2+ characters to filter ${students.length} students by name or ID...`}
              className="w-full h-11 rounded-xl border border-slate-200 bg-slate-50 pl-10 pr-10 text-sm text-slate-900 placeholder:text-slate-400 focus:border-slate-900 focus:bg-white focus:outline-none transition-colors"
            />
            {searchQuery && (
              <button
                type="button"
                onClick={() => setSearchQuery('')}
                aria-label="Clear search"
                className="absolute right-2 top-1/2 -translate-y-1/2 min-h-[36px] min-w-[36px] flex items-center justify-center rounded-lg text-slate-400 hover:text-slate-700"
              >
                <X className="h-4 w-4" />
              </button>
            )}
          </div>
          <div className="text-xs text-slate-500 tabular-nums whitespace-nowrap shrink-0">
            {trimmedQuery.length === 1
              ? 'Type 1 more character to filter'
              : isFiltering
              ? `${visibleStudents.length} matching students`
              : `Rendering ${renderedSlice.length} of ${visibleStudents.length} (Virtualized)`}
          </div>
        </div>
      </div>

      {/* Virtualized Lazy List + Right-Side Vertical A-Z Quick-Jump Bar */}
      <div className="rounded-2xl border border-slate-200 bg-white overflow-hidden">
        {visibleStudents.length === 0 ? (
          <div className="p-12 text-center">
            <p className="text-sm font-semibold text-slate-900">No matching students found</p>
            <p className="mt-1 text-xs text-slate-500">
              Try a different surname or student code.
            </p>
            <button
              type="button"
              onClick={() => setSearchQuery('')}
              className="mt-4 min-h-[40px] rounded-xl bg-slate-900 px-4 py-2 text-xs font-semibold text-white hover:bg-slate-800"
            >
              Clear Filter
            </button>
          </div>
        ) : (
          <div className="flex items-stretch" style={{ height: `${VIEWPORT_HEIGHT}px` }}>
            {/* Virtualized Scroll Viewport */}
            <div
              ref={scrollRef}
              onScroll={(e) => setScrollTop(e.currentTarget.scrollTop)}
              className="flex-1 overflow-y-auto relative px-3 py-2"
            >
              <div style={{ height: `${totalHeight}px`, position: 'relative' }}>
                {renderedSlice.map((student, sliceIdx) => {
                  const actualIndex = startIndex + sliceIdx;
                  const topOffset = actualIndex * ROW_HEIGHT;
                  const record = recordsByStudentId[student.id];
                  const isLocked =
                    record &&
                    record.biometricVerified &&
                    (record.status === 'present' || record.status === 'late');
                  const isLate = record?.status === 'late';
                  const isExcused = record?.status === 'excused';

                  return (
                    <div
                      key={student.id}
                      style={{
                        position: 'absolute',
                        top: `${topOffset}px`,
                        left: 0,
                        right: 0,
                        height: `${ROW_HEIGHT}px`,
                      }}
                      className="py-1"
                    >
                      {isLocked ? (
                        <button
                          type="button"
                          disabled
                          className={`w-full h-full flex items-center justify-between gap-3 rounded-xl border px-4 text-left cursor-not-allowed ${
                            isLate
                              ? 'bg-emerald-50 border-emerald-500 text-emerald-950'
                              : 'bg-emerald-600 border-emerald-700 text-white'
                          }`}
                        >
                          <div className="min-w-0 flex-1">
                            <p className="text-sm font-bold truncate">
                              {student.lastName}, {student.firstName}
                            </p>
                            <p
                              className={`text-xs tabular-nums truncate ${
                                isLate ? 'text-emerald-800' : 'text-emerald-100'
                              }`}
                            >
                              {isLate ? 'Late · ' : 'Present · '}
                              {record.checkedInAt
                                ? new Date(record.checkedInAt).toLocaleTimeString([], {
                                    hour: '2-digit',
                                    minute: '2-digit',
                                  })
                                : 'Verified'}{' '}
                              · {record.syncStatus === 'synced' ? 'Synced' : 'SQLite WAL'}
                            </p>
                          </div>
                          <div
                            className={`flex h-9 w-9 items-center justify-center rounded-lg shrink-0 ${
                              isLate
                                ? 'bg-emerald-200 text-emerald-900'
                                : 'bg-emerald-700/80 text-white'
                            }`}
                          >
                            <Lock className="h-4 w-4" />
                          </div>
                        </button>
                      ) : isExcused ? (
                        <button
                          type="button"
                          disabled
                          className="w-full h-full flex items-center justify-between gap-3 rounded-xl border border-slate-200 bg-slate-100 px-4 text-left text-slate-600 cursor-not-allowed"
                        >
                          <div className="min-w-0 flex-1">
                            <p className="text-sm font-semibold truncate">
                              {student.lastName}, {student.firstName}
                            </p>
                            <p className="text-xs text-slate-500 truncate">
                              Excused by Lecturer · {student.studentCode}
                            </p>
                          </div>
                          <Clock className="h-4 w-4 text-slate-400 shrink-0" />
                        </button>
                      ) : (
                        <button
                          type="button"
                          onClick={() => setActiveStudent(student)}
                          className="w-full h-full group flex items-center justify-between gap-3 rounded-xl border border-slate-200 bg-white px-4 text-left hover:border-slate-900 hover:bg-slate-50 active:scale-[0.99] transition-all focus-visible:outline-2 focus-visible:outline-slate-900"
                        >
                          <div className="min-w-0 flex-1">
                            <p className="text-sm font-bold text-slate-900 truncate">
                              {student.lastName}, {student.firstName}
                            </p>
                            <p className="text-xs text-slate-500 font-mono tabular-nums truncate">
                              {student.studentCode} · Grade {student.gradeLevel} · {student.homeroom}
                            </p>
                          </div>
                          <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-slate-100 text-slate-700 group-hover:bg-slate-900 group-hover:text-white transition-colors shrink-0">
                            <Fingerprint className="h-4 w-4" />
                          </div>
                        </button>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>

            {/* Vertical A-Z Quick-Jump Index Bar on the Right */}
            {!isFiltering && (
              <nav
                aria-label="Alphabetical quick jump index"
                className="w-9 border-l border-slate-200 bg-slate-50 py-1.5 flex flex-col items-center justify-between select-none shrink-0"
              >
                {ALPHABET.map((letter) => {
                  const hasStudents = letterIndexMap[letter] !== undefined;
                  const isActive = activeLetter === letter;
                  return (
                    <button
                      key={letter}
                      type="button"
                      disabled={!hasStudents}
                      onClick={() => jumpToLetter(letter)}
                      className={`w-7 flex-1 flex items-center justify-center rounded text-[11px] font-bold transition-colors ${
                        isActive
                          ? 'bg-slate-900 text-white'
                          : hasStudents
                          ? 'text-slate-700 hover:bg-slate-200 hover:text-slate-900'
                          : 'text-slate-300 cursor-default'
                      }`}
                    >
                      {letter}
                    </button>
                  );
                })}
              </nav>
            )}
          </div>
        )}
      </div>

      <BiometricPromptModal
        student={activeStudent}
        onCancel={() => setActiveStudent(null)}
        onVerified={handleVerified}
      />
    </div>
  );
};

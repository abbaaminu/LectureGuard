import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { CloudUpload, Lock } from 'lucide-react';
import {
  AppView,
  AttendanceRecord,
  AttendanceSession,
  AttendanceStatus,
  BiometricMethod,
  NetworkTransport,
  Student,
  SyncBatchProgress,
} from './types/attendance';
import { SEED_LECTURES, SEED_STUDENTS, SEED_TEACHER_LOGS } from './data/seedData';
import {
  createAttendanceRecord,
  loadPersistedState,
  saveLecturerPin,
  saveNetworkTransport,
  saveRecordsToLocalDb,
  saveSessionToLocalDb,
} from './services/offlineStore';
import { StudentPassMode } from './components/StudentPassMode';
import { TeacherMonitor } from './components/TeacherMonitor';
import { AdminAnalytics } from './components/AdminAnalytics';
import { ArchitectureExplorer } from './components/ArchitectureExplorer';
import { PinExitDialog } from './components/PinExitDialog';

const CHUNK_SIZE = 50;

function createInitialSession(lectureId: string, enrolledCount: number): AttendanceSession {
  const lecture = SEED_LECTURES.find((l) => l.id === lectureId) ?? SEED_LECTURES[0];
  return {
    id: `sess-${lecture.courseCode.toLowerCase()}-${new Date().toISOString().slice(0, 10)}`,
    lectureId: lecture.id,
    teacherId: lecture.teacherId,
    startedAt: new Date().toISOString(),
    endedAt: null,
    isLockedPassMode: true,
    enrolledCount,
  };
}

export default function App() {
  const initialPersisted = useMemo(() => loadPersistedState(), []);

  const [activeLectureId, setActiveLectureId] = useState<string>(
    initialPersisted.session?.lectureId ?? SEED_LECTURES[0].id,
  );

  const activeLecture = useMemo(
    () => SEED_LECTURES.find((l) => l.id === activeLectureId) ?? SEED_LECTURES[0],
    [activeLectureId],
  );

  const lectureStudents = useMemo(() => {
    const enrolledSet = new Set(activeLecture.enrolledStudentIds);
    return SEED_STUDENTS.filter((s) => enrolledSet.has(s.id));
  }, [activeLecture]);

  const [session, setSession] = useState<AttendanceSession>(
    () =>
      initialPersisted.session ??
      createInitialSession(SEED_LECTURES[0].id, SEED_LECTURES[0].enrolledStudentIds.length),
  );

  const [recordsByStudentId, setRecordsByStudentId] = useState<Record<string, AttendanceRecord>>(
    () => initialPersisted.records,
  );
  const [lecturerPin, setLecturerPin] = useState<string>(() => initialPersisted.lecturerPin);
  const [networkTransport, setNetworkTransport] = useState<NetworkTransport>(
    () => initialPersisted.networkTransport,
  );
  const transportRef = useRef<NetworkTransport>(networkTransport);
  transportRef.current = networkTransport;

  const [isSyncing, setIsSyncing] = useState<boolean>(false);
  const [syncProgress, setSyncProgress] = useState<SyncBatchProgress | null>(null);
  const [syncNotice, setSyncNotice] = useState<string | null>(null);

  const [activeView, setActiveView] = useState<AppView>('pass_mode');
  const [pinDialogOpen, setPinDialogOpen] = useState<boolean>(false);
  const [pendingViewAfterUnlock, setPendingViewAfterUnlock] = useState<AppView>('teacher_monitor');

  useEffect(() => {
    saveSessionToLocalDb(session);
  }, [session]);

  useEffect(() => {
    saveRecordsToLocalDb(recordsByStudentId);
  }, [recordsByStudentId]);

  useEffect(() => {
    if (activeView === 'pass_mode' && session.isLockedPassMode) {
      window.history.pushState({ lectureGuardLock: true }, '');
      const handlePopState = () => {
        window.history.pushState({ lectureGuardLock: true }, '');
        setPendingViewAfterUnlock('teacher_monitor');
        setPinDialogOpen(true);
      };
      window.addEventListener('popstate', handlePopState);
      return () => window.removeEventListener('popstate', handlePopState);
    }
  }, [activeView, session.isLockedPassMode]);

  const lectureRecords = useMemo(() => {
    const filtered: Record<string, AttendanceRecord> = {};
    lectureStudents.forEach((s) => {
      const rec = recordsByStudentId[s.id];
      if (rec && rec.lectureId === activeLecture.id) {
        filtered[s.id] = rec;
      }
    });
    return filtered;
  }, [lectureStudents, recordsByStudentId, activeLecture.id]);

  const pendingSyncCount = useMemo(
    () => Object.values(recordsByStudentId).filter((r) => r.syncStatus === 'pending').length,
    [recordsByStudentId],
  );

  // Connection-agnostic chunked batch uploader (50 records per request)
  const runChunkedSync = useCallback(
    async (
      targetRecords: Record<string, AttendanceRecord>,
      activeTransport: Exclude<NetworkTransport, 'offline'>,
    ) => {
      if (isSyncing) return;
      const pendingIds = Object.values(targetRecords)
        .filter((r) => r.syncStatus === 'pending')
        .map((r) => r.studentId);

      if (pendingIds.length === 0) return;

      setIsSyncing(true);
      const totalBatches = Math.ceil(pendingIds.length / CHUNK_SIZE);
      let uploadedCount = 0;

      for (let b = 0; b < totalBatches; b += 1) {
        if (transportRef.current === 'offline') {
          setIsSyncing(false);
          setSyncProgress(null);
          setSyncNotice('Connection dropped mid-sync. Remaining records stay queued in SQLite WAL.');
          setTimeout(() => setSyncNotice(null), 3500);
          return;
        }

        const chunkIds = pendingIds.slice(b * CHUNK_SIZE, (b + 1) * CHUNK_SIZE);
        setSyncProgress({
          uploadedCount,
          totalQueued: pendingIds.length,
          currentBatch: b + 1,
          totalBatches,
          transport: transportRef.current === 'wifi' ? 'wifi' : activeTransport,
        });

        await new Promise((resolve) => setTimeout(resolve, 360));

        setRecordsByStudentId((prev) => {
          const next = { ...prev };
          chunkIds.forEach((sid) => {
            if (next[sid]) {
              next[sid] = { ...next[sid], syncStatus: 'synced' };
            }
          });
          return next;
        });

        uploadedCount += chunkIds.length;
      }

      setSyncProgress(null);
      setIsSyncing(false);
      setSyncNotice(
        `Synced ${uploadedCount} records across ${totalBatches} chunked batch(es) via ${
          activeTransport === 'mobile' ? 'Mobile Data' : 'Campus Wi-Fi'
        }`,
      );
      setTimeout(() => setSyncNotice(null), 3600);
    },
    [isSyncing],
  );

  const handleSyncNow = useCallback(() => {
    if (networkTransport === 'offline' || isSyncing) return;
    void runChunkedSync(recordsByStudentId, networkTransport);
  }, [networkTransport, isSyncing, recordsByStudentId, runChunkedSync]);

  const handleChangeTransport = (nextTransport: NetworkTransport) => {
    setNetworkTransport(nextTransport);
    transportRef.current = nextTransport;
    saveNetworkTransport(nextTransport);

    // Broad connectivity listener triggers sync on ANY active connection (Mobile Data OR Wi-Fi)
    if (nextTransport !== 'offline') {
      const hasPending = Object.values(recordsByStudentId).some(
        (r) => r.syncStatus === 'pending',
      );
      if (hasPending && !isSyncing) {
        setTimeout(() => {
          void runChunkedSync(recordsByStudentId, nextTransport);
        }, 180);
      }
    }
  };

  const handleStudentVerified = (student: Student, method: BiometricMethod) => {
    const elapsedMinutes =
      (Date.now() - new Date(session.startedAt).getTime()) / 60000;
    const computedStatus: AttendanceStatus =
      elapsedMinutes > activeLecture.lateGraceMinutes ? 'late' : 'present';

    const record = createAttendanceRecord({
      sessionId: session.id,
      lectureId: activeLecture.id,
      studentId: student.id,
      status: computedStatus,
      biometricVerified: true,
      biometricMethod: method,
      existing: recordsByStudentId[student.id],
    });

    setRecordsByStudentId((prev) => ({
      ...prev,
      [student.id]: record,
    }));
  };

  const handleOverrideStatus = (
    student: Student,
    status: AttendanceStatus,
    reason: string,
  ) => {
    const record = createAttendanceRecord({
      sessionId: session.id,
      lectureId: activeLecture.id,
      studentId: student.id,
      status,
      biometricVerified: false,
      biometricMethod: 'manual_override',
      overrideReason: reason,
      existing: recordsByStudentId[student.id],
    });

    setRecordsByStudentId((prev) => ({
      ...prev,
      [student.id]: record,
    }));
  };

  const handleNavigate = (targetView: AppView) => {
    if (targetView === activeView) return;

    if (activeView === 'pass_mode' && session.isLockedPassMode) {
      setPendingViewAfterUnlock(targetView);
      setPinDialogOpen(true);
      return;
    }

    if (targetView === 'pass_mode') {
      setSession((prev) => ({ ...prev, isLockedPassMode: true }));
    }
    setActiveView(targetView);
  };

  const handlePinUnlocked = () => {
    setPinDialogOpen(false);
    setSession((prev) => ({ ...prev, isLockedPassMode: false }));
    setActiveView(pendingViewAfterUnlock);
  };

  const handleSelectLecture = (lectureId: string) => {
    const nextLecture = SEED_LECTURES.find((l) => l.id === lectureId) ?? SEED_LECTURES[0];
    setActiveLectureId(nextLecture.id);
    setSession(createInitialSession(nextLecture.id, nextLecture.enrolledStudentIds.length));
  };

  const handleSimulateBulkCheckIn = (count: number) => {
    const unchecked = lectureStudents.filter((s) => !lectureRecords[s.id]);
    const slice = unchecked.slice(0, count);
    if (slice.length === 0) return;

    setRecordsByStudentId((prev) => {
      const next = { ...prev };
      slice.forEach((student, idx) => {
        const status: AttendanceStatus = idx % 11 === 10 ? 'late' : 'present';
        const method: BiometricMethod = idx % 2 === 0 ? 'fingerprint' : 'face_id';
        next[student.id] = createAttendanceRecord({
          sessionId: session.id,
          lectureId: activeLecture.id,
          studentId: student.id,
          status,
          biometricVerified: true,
          biometricMethod: method,
          existing: next[student.id],
        });
      });
      return next;
    });
  };

  const handleResetSession = () => {
    setRecordsByStudentId((prev) => {
      const next = { ...prev };
      lectureStudents.forEach((s) => {
        if (next[s.id]?.lectureId === activeLecture.id) {
          delete next[s.id];
        }
      });
      return next;
    });
    setSession(createInitialSession(activeLecture.id, lectureStudents.length));
  };

  const handleUpdatePin = (newPin: string) => {
    setLecturerPin(newPin);
    saveLecturerPin(newPin);
  };

  const navItems: Array<{ id: AppView; label: string }> = [
    { id: 'pass_mode', label: 'Student Pass' },
    { id: 'teacher_monitor', label: 'Teacher Monitor' },
    { id: 'admin_analytics', label: 'Admin Analytics' },
    { id: 'architecture', label: 'Code & SQL' },
  ];

  return (
    <div className="min-h-screen flex flex-col bg-slate-50 text-slate-900">
      {/* 3-Zone Top Bar Contract */}
      <header className="sticky top-0 z-30 bg-white/95 backdrop-blur-md border-b border-slate-200 no-print">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between gap-8">
          <button
            type="button"
            onClick={() => handleNavigate('pass_mode')}
            className="text-lg font-extrabold tracking-tight text-slate-900 whitespace-nowrap shrink-0 focus-visible:outline-2 focus-visible:outline-slate-900 rounded"
          >
            LectureGuard
          </button>

          <nav className="hidden md:flex items-center gap-6" aria-label="Primary navigation">
            {navItems.map((item) => {
              const isActive = activeView === item.id;
              return (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => handleNavigate(item.id)}
                  className={`py-1.5 text-sm font-semibold whitespace-nowrap shrink-0 border-b-2 transition-colors ${
                    isActive
                      ? 'border-slate-900 text-slate-900'
                      : 'border-transparent text-slate-500 hover:text-slate-900 hover:border-slate-300'
                  }`}
                >
                  {item.label}
                </button>
              );
            })}
          </nav>

          <div className="flex items-center shrink-0">
            {activeView === 'pass_mode' ? (
              <button
                type="button"
                onClick={() => {
                  setPendingViewAfterUnlock('teacher_monitor');
                  setPinDialogOpen(true);
                }}
                className="min-h-[40px] inline-flex items-center gap-2 rounded-xl bg-slate-900 px-4 py-2 text-xs font-semibold text-white hover:bg-slate-800 transition-colors whitespace-nowrap shrink-0"
              >
                <Lock className="h-3.5 w-3.5" />
                <span>Unlock Mode</span>
              </button>
            ) : (
              <button
                type="button"
                disabled={networkTransport === 'offline' || isSyncing || pendingSyncCount === 0}
                onClick={handleSyncNow}
                className="min-h-[40px] inline-flex items-center gap-2 rounded-xl bg-slate-900 px-4 py-2 text-xs font-semibold text-white hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-500 transition-colors whitespace-nowrap shrink-0 tabular-nums"
              >
                <CloudUpload className="h-3.5 w-3.5" />
                <span>
                  {isSyncing && syncProgress
                    ? `Batch ${syncProgress.currentBatch}/${syncProgress.totalBatches}`
                    : pendingSyncCount > 0
                    ? `Sync (${pendingSyncCount})`
                    : 'All Synced'}
                </span>
              </button>
            )}
          </div>
        </div>

        <div className="md:hidden border-t border-slate-100 px-4 py-2 flex items-center gap-4 overflow-x-auto">
          {navItems.map((item) => {
            const isActive = activeView === item.id;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => handleNavigate(item.id)}
                className={`text-xs font-semibold whitespace-nowrap shrink-0 py-1 ${
                  isActive ? 'text-slate-900 underline underline-offset-4' : 'text-slate-500'
                }`}
              >
                {item.label}
              </button>
            );
          })}
        </div>
      </header>

      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 py-6">
        {syncNotice && (
          <div
            role="status"
            className="mb-4 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-xs font-semibold text-emerald-900 no-print"
          >
            {syncNotice}
          </div>
        )}

        {activeView === 'pass_mode' && (
          <StudentPassMode
            lecture={activeLecture}
            students={lectureStudents}
            session={session}
            recordsByStudentId={lectureRecords}
            networkTransport={networkTransport}
            pendingSyncCount={pendingSyncCount}
            syncProgress={syncProgress}
            onChangeTransport={handleChangeTransport}
            onStudentVerified={handleStudentVerified}
            onRequestExitLockdown={() => {
              setPendingViewAfterUnlock('teacher_monitor');
              setPinDialogOpen(true);
            }}
          />
        )}

        {activeView === 'teacher_monitor' && (
          <TeacherMonitor
            lectures={SEED_LECTURES}
            activeLecture={activeLecture}
            students={lectureStudents}
            session={session}
            recordsByStudentId={lectureRecords}
            teacherLogs={SEED_TEACHER_LOGS}
            lecturerPin={lecturerPin}
            networkTransport={networkTransport}
            isSyncing={isSyncing}
            syncProgress={syncProgress}
            pendingSyncCount={pendingSyncCount}
            onSelectLecture={handleSelectLecture}
            onLaunchPassMode={() => {
              setSession((prev) => ({ ...prev, isLockedPassMode: true }));
              setActiveView('pass_mode');
            }}
            onOverrideStatus={handleOverrideStatus}
            onUpdatePin={handleUpdatePin}
            onSimulateBulkCheckIn={handleSimulateBulkCheckIn}
            onResetSession={handleResetSession}
            onChangeTransport={handleChangeTransport}
            onSyncNow={handleSyncNow}
          />
        )}

        {activeView === 'admin_analytics' && (
          <AdminAnalytics
            students={SEED_STUDENTS}
            teacherLogs={SEED_TEACHER_LOGS}
            pendingSyncCount={pendingSyncCount}
          />
        )}

        {activeView === 'architecture' && <ArchitectureExplorer />}
      </main>

      <PinExitDialog
        isOpen={pinDialogOpen}
        expectedPin={lecturerPin}
        onCancel={() => setPinDialogOpen(false)}
        onSuccess={handlePinUnlocked}
      />
    </div>
  );
}

export type AttendanceStatus = 'present' | 'late' | 'absent' | 'excused';
export type SyncStatus = 'pending' | 'synced';
export type BiometricMethod = 'fingerprint' | 'face_id' | 'manual_override';
export type NetworkTransport = 'offline' | 'mobile' | 'wifi';
export type AppView = 'pass_mode' | 'teacher_monitor' | 'admin_analytics' | 'architecture';

export interface SyncBatchProgress {
  uploadedCount: number;
  totalQueued: number;
  currentBatch: number;
  totalBatches: number;
  transport: Exclude<NetworkTransport, 'offline'>;
}

export interface Student {
  id: string;
  studentCode: string;
  firstName: string;
  lastName: string;
  gradeLevel: 9 | 10 | 11 | 12;
  homeroom: string;
  guardianEmail: string;
  term1Pct: number;
  term2Pct: number;
  term3Pct: number;
  unexcusedAbsences: number;
}

export interface Lecture {
  id: string;
  courseCode: string;
  title: string;
  teacherId: string;
  teacherName: string;
  roomNumber: string;
  periodNumber: number;
  lateGraceMinutes: number;
  enrolledStudentIds: string[];
}

export interface AttendanceRecord {
  id: string;
  sessionId: string;
  lectureId: string;
  studentId: string;
  status: AttendanceStatus;
  checkedInAt: string | null;
  biometricVerified: boolean;
  biometricMethod: BiometricMethod | null;
  overrideReason: string | null;
  syncStatus: SyncStatus;
  deviceRecordedAt: string;
}

export interface AttendanceSession {
  id: string;
  lectureId: string;
  teacherId: string;
  startedAt: string;
  endedAt: string | null;
  isLockedPassMode: boolean;
  enrolledCount: number;
}

export interface TeacherSubmissionLog {
  id: string;
  sessionDate: string;
  courseCode: string;
  lectureTitle: string;
  teacherName: string;
  department: string;
  enrolledCount: number;
  checkedInCount: number;
  lateCount: number;
  absentCount: number;
  submittedAt: string | null;
  syncState: 'synced' | 'offline_queued' | 'missing';
}

import {
  AttendanceRecord,
  AttendanceSession,
  AttendanceStatus,
  BiometricMethod,
  NetworkTransport,
} from '../types/attendance';

const STORAGE_KEY_RECORDS = 'lectureguard_sqlite_records_v2';
const STORAGE_KEY_SESSION = 'lectureguard_sqlite_session_v2';
const STORAGE_KEY_PIN = 'lectureguard_secure_pin_v1';
const STORAGE_KEY_TRANSPORT = 'lectureguard_network_transport_v1';

export interface PersistedSnapshot {
  session: AttendanceSession | null;
  records: Record<string, AttendanceRecord>;
  lecturerPin: string;
  networkTransport: NetworkTransport;
}

export function loadPersistedState(): PersistedSnapshot {
  try {
    const rawSession = localStorage.getItem(STORAGE_KEY_SESSION);
    const rawRecords = localStorage.getItem(STORAGE_KEY_RECORDS);
    const rawPin = localStorage.getItem(STORAGE_KEY_PIN);
    const rawTransport = localStorage.getItem(STORAGE_KEY_TRANSPORT);

    const networkTransport: NetworkTransport =
      rawTransport === 'offline' || rawTransport === 'mobile' || rawTransport === 'wifi'
        ? rawTransport
        : 'mobile';

    return {
      session: rawSession ? (JSON.parse(rawSession) as AttendanceSession) : null,
      records: rawRecords ? (JSON.parse(rawRecords) as Record<string, AttendanceRecord>) : {},
      lecturerPin: rawPin && /^\d{4}$/.test(rawPin) ? rawPin : '',
      networkTransport,
    };
  } catch {
    return {
      session: null,
      records: {},
      lecturerPin: '',
      networkTransport: 'mobile',
    };
  }
}

export function saveSessionToLocalDb(session: AttendanceSession | null): void {
  if (!session) {
    localStorage.removeItem(STORAGE_KEY_SESSION);
  } else {
    localStorage.setItem(STORAGE_KEY_SESSION, JSON.stringify(session));
  }
}

export function saveRecordsToLocalDb(records: Record<string, AttendanceRecord>): void {
  localStorage.setItem(STORAGE_KEY_RECORDS, JSON.stringify(records));
}

export function saveLecturerPin(pin: string): void {
  if (/^\d{4}$/.test(pin)) {
    localStorage.setItem(STORAGE_KEY_PIN, pin);
  }
}

export function saveNetworkTransport(transport: NetworkTransport): void {
  localStorage.setItem(STORAGE_KEY_TRANSPORT, transport);
}

export function createAttendanceRecord(params: {
  sessionId: string;
  lectureId: string;
  studentId: string;
  status: AttendanceStatus;
  biometricVerified: boolean;
  biometricMethod: BiometricMethod;
  overrideReason?: string | null;
  existing?: AttendanceRecord;
}): AttendanceRecord {
  const nowIso = new Date().toISOString();
  const isCheckIn = params.status === 'present' || params.status === 'late';
  return {
    id: params.existing?.id ?? `rec-${params.sessionId}-${params.studentId}`,
    sessionId: params.sessionId,
    lectureId: params.lectureId,
    studentId: params.studentId,
    status: params.status,
    checkedInAt: isCheckIn ? (params.existing?.checkedInAt ?? nowIso) : null,
    biometricVerified: params.biometricVerified,
    biometricMethod: params.biometricMethod,
    overrideReason: params.overrideReason ?? null,
    syncStatus: 'pending',
    deviceRecordedAt: nowIso,
  };
}

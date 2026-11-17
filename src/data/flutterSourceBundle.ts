import supabaseMigrationSql from '../../supabase/migrations/001_lectureguard_schema.sql?raw';
import pubspecYaml from '../../flutter_app/pubspec.yaml?raw';
import mainDart from '../../flutter_app/lib/main.dart?raw';
import modelsDart from '../../flutter_app/lib/models/attendance_models.dart?raw';
import localDbDart from '../../flutter_app/lib/services/local_database_service.dart?raw';
import biometricDart from '../../flutter_app/lib/services/biometric_service.dart?raw';
import pinSecurityDart from '../../flutter_app/lib/services/pin_security_service.dart?raw';
import syncEngineDart from '../../flutter_app/lib/services/sync_engine_service.dart?raw';
import providersDart from '../../flutter_app/lib/providers/lecture_guard_providers.dart?raw';
import pinDialogDart from '../../flutter_app/lib/widgets/pin_exit_dialog.dart?raw';
import studentPassScreenDart from '../../flutter_app/lib/screens/student_pass_mode_screen.dart?raw';
import teacherMonitorScreenDart from '../../flutter_app/lib/screens/teacher_monitor_screen.dart?raw';
import adminAnalyticsScreenDart from '../../flutter_app/lib/screens/admin_analytics_screen.dart?raw';

export interface SourceFileEntry {
  path: string;
  category: 'Database & RLS' | 'State & Services' | 'Security & Biometrics' | 'Flutter UI Screens' | 'Project Config';
  language: 'sql' | 'dart' | 'yaml';
  summary: string;
  content: string;
}

export const FLUTTER_SUPABASE_FILES: SourceFileEntry[] = [
  {
    path: 'supabase/migrations/001_lectureguard_schema.sql',
    category: 'Database & RLS',
    language: 'sql',
    summary: 'PostgreSQL tables (students, lectures, enrollments, attendance_sessions, attendance_records), <80% chronic absenteeism views, and strict RLS policies.',
    content: supabaseMigrationSql,
  },
  {
    path: 'flutter_app/lib/screens/student_pass_mode_screen.dart',
    category: 'Flutter UI Screens',
    language: 'dart',
    summary: 'PopScope exit lockdown, alphabetical 70-student grid with A-Z quick jump, and biometric tap-to-lock.',
    content: studentPassScreenDart,
  },
  {
    path: 'flutter_app/lib/widgets/pin_exit_dialog.dart',
    category: 'Security & Biometrics',
    language: 'dart',
    summary: '4-digit Admin PIN dialog triggered on back-press or exit attempt from Student Pass Mode.',
    content: pinDialogDart,
  },
  {
    path: 'flutter_app/lib/services/biometric_service.dart',
    category: 'Security & Biometrics',
    language: 'dart',
    summary: 'local_auth wrapper enforcing biometricOnly: true (Fingerprint / Face ID) with hardware error handling.',
    content: biometricDart,
  },
  {
    path: 'flutter_app/lib/services/pin_security_service.dart',
    category: 'Security & Biometrics',
    language: 'dart',
    summary: 'flutter_secure_storage salted SHA-256 lecturer PIN storage and constant-time comparison.',
    content: pinSecurityDart,
  },
  {
    path: 'flutter_app/lib/services/local_database_service.dart',
    category: 'State & Services',
    language: 'dart',
    summary: 'SQLite (sqflite) service with WAL mode, batch roster caching, and zero-latency offline writes.',
    content: localDbDart,
  },
  {
    path: 'flutter_app/lib/services/sync_engine_service.dart',
    category: 'State & Services',
    language: 'dart',
    summary: 'connectivity_plus Wi-Fi listener & chunked batch upsert sync service to Supabase.',
    content: syncEngineDart,
  },
  {
    path: 'flutter_app/lib/providers/lecture_guard_providers.dart',
    category: 'State & Services',
    language: 'dart',
    summary: 'Riverpod StateNotifier orchestrating offline check-ins, manual overrides, and sync queue state.',
    content: providersDart,
  },
  {
    path: 'flutter_app/lib/screens/teacher_monitor_screen.dart',
    category: 'Flutter UI Screens',
    language: 'dart',
    summary: 'Live headcount monitor, manual status overrides (Present/Late/Excused/Absent), and Pass Mode launcher.',
    content: teacherMonitorScreenDart,
  },
  {
    path: 'flutter_app/lib/screens/admin_analytics_screen.dart',
    category: 'Flutter UI Screens',
    language: 'dart',
    summary: 'School-wide analytics querying Supabase views, chronic absenteeism flags (<80%), CSV & PDF export.',
    content: adminAnalyticsScreenDart,
  },
  {
    path: 'flutter_app/lib/models/attendance_models.dart',
    category: 'State & Services',
    language: 'dart',
    summary: 'Typed Dart models for Student, Lecture, AttendanceSession, and AttendanceRecord.',
    content: modelsDart,
  },
  {
    path: 'flutter_app/lib/main.dart',
    category: 'Project Config',
    language: 'dart',
    summary: 'App bootstrap initializing Supabase, Riverpod ProviderScope, PIN storage, and Wi-Fi auto-sync.',
    content: mainDart,
  },
  {
    path: 'flutter_app/pubspec.yaml',
    category: 'Project Config',
    language: 'yaml',
    summary: 'Flutter dependencies: flutter_riverpod, sqflite, local_auth, flutter_secure_storage, supabase_flutter, pdf, csv.',
    content: pubspecYaml,
  },
];

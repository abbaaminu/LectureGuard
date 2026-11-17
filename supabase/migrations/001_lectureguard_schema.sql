-- ============================================================================
-- LectureGuard: Production PostgreSQL / Supabase Migration
-- Offline-first High School Biometric Attendance & Management Reporting
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Custom Enums
CREATE TYPE user_role AS ENUM ('admin', 'teacher', 'student');
CREATE TYPE attendance_status AS ENUM ('present', 'late', 'absent', 'excused');
CREATE TYPE session_state AS ENUM ('active', 'locked_pass_mode', 'completed');

-- 1. Profiles (extends Supabase auth.users for RBAC)
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  role user_role NOT NULL DEFAULT 'student',
  department TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Students
CREATE TABLE public.students (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID UNIQUE REFERENCES public.profiles(id) ON DELETE SET NULL,
  student_code TEXT UNIQUE NOT NULL, -- e.g. "HS-2026-0142"
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  grade_level SMALLINT NOT NULL CHECK (grade_level BETWEEN 9 AND 12),
  homeroom TEXT NOT NULL,
  guardian_email TEXT,
  guardian_phone TEXT,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_students_name ON public.students (last_name, first_name);
CREATE INDEX idx_students_grade ON public.students (grade_level);

-- 3. Lectures (Courses / Periods)
CREATE TABLE public.lectures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  course_code TEXT NOT NULL,          -- e.g. "BIO-301"
  title TEXT NOT NULL,                -- e.g. "AP Biology — Period 3"
  teacher_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  room_number TEXT NOT NULL,
  period_number SMALLINT NOT NULL CHECK (period_number BETWEEN 1 AND 10),
  academic_term TEXT NOT NULL,        -- e.g. "2026-T2"
  late_grace_minutes SMALLINT NOT NULL DEFAULT 10,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (course_code, academic_term, period_number)
);

CREATE INDEX idx_lectures_teacher ON public.lectures (teacher_id);

-- 4. Enrollments (Many-to-Many Students <-> Lectures)
CREATE TABLE public.enrollments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lecture_id UUID NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  enrolled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (lecture_id, student_id)
);

CREATE INDEX idx_enrollments_lecture ON public.enrollments (lecture_id) WHERE active = TRUE;
CREATE INDEX idx_enrollments_student ON public.enrollments (student_id) WHERE active = TRUE;

-- 5. Attendance Sessions (Each class meeting / pass-the-phone session)
CREATE TABLE public.attendance_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lecture_id UUID NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  teacher_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  session_date DATE NOT NULL DEFAULT CURRENT_DATE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMPTZ,
  state session_state NOT NULL DEFAULT 'active',
  device_id TEXT NOT NULL,
  enrolled_snapshot_count INTEGER NOT NULL DEFAULT 0,
  submitted_to_cloud_at TIMESTAMPTZ,
  UNIQUE (lecture_id, session_date)
);

CREATE INDEX idx_sessions_teacher_date ON public.attendance_sessions (teacher_id, session_date DESC);
CREATE INDEX idx_sessions_lecture_date ON public.attendance_sessions (lecture_id, session_date DESC);

-- 6. Attendance Records (Individual check-ins synced from local SQLite)
CREATE TABLE public.attendance_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.attendance_sessions(id) ON DELETE CASCADE,
  lecture_id UUID NOT NULL REFERENCES public.lectures(id) ON DELETE CASCADE,
  student_id UUID NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  status attendance_status NOT NULL DEFAULT 'absent',
  checked_in_at TIMESTAMPTZ,
  biometric_verified BOOLEAN NOT NULL DEFAULT FALSE,
  biometric_method TEXT, -- 'fingerprint' | 'face_id' | 'manual_override'
  override_by UUID REFERENCES public.profiles(id),
  override_reason TEXT,
  device_recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  client_record_hash TEXT,
  UNIQUE (session_id, student_id)
);

CREATE INDEX idx_records_session ON public.attendance_records (session_id);
CREATE INDEX idx_records_student ON public.attendance_records (student_id, checked_in_at DESC);
CREATE INDEX idx_records_lecture_status ON public.attendance_records (lecture_id, status);

-- ============================================================================
-- Reporting Views (Chronic Absenteeism < 80% & Teacher Submission Audit)
-- ============================================================================

CREATE OR REPLACE VIEW public.v_student_attendance_summary AS
SELECT
  s.id AS student_id,
  s.student_code,
  s.first_name,
  s.last_name,
  s.grade_level,
  s.homeroom,
  COUNT(ar.id) AS total_sessions,
  COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused')) AS attended_sessions,
  COUNT(ar.id) FILTER (WHERE ar.status = 'absent') AS unexcused_absences,
  COUNT(ar.id) FILTER (WHERE ar.status = 'late') AS late_count,
  ROUND(
    CASE
      WHEN COUNT(ar.id) = 0 THEN 100.0
      ELSE (COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused'))::NUMERIC / COUNT(ar.id)) * 100.0
    END,
    1
  ) AS attendance_percentage,
  (
    CASE
      WHEN COUNT(ar.id) = 0 THEN FALSE
      ELSE (COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused'))::NUMERIC / COUNT(ar.id)) < 0.80
    END
  ) AS chronic_absenteeism_flag
FROM public.students s
LEFT JOIN public.attendance_records ar ON ar.student_id = s.id
WHERE s.active = TRUE
GROUP BY s.id, s.student_code, s.first_name, s.last_name, s.grade_level, s.homeroom;

CREATE OR REPLACE VIEW public.v_teacher_submission_logs AS
SELECT
  ats.id AS session_id,
  ats.session_date,
  l.course_code,
  l.title AS lecture_title,
  p.full_name AS teacher_name,
  ats.enrolled_snapshot_count,
  COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late')) AS biometric_checked_in_count,
  COUNT(ar.id) FILTER (WHERE ar.status = 'absent') AS absent_count,
  ats.started_at,
  ats.submitted_to_cloud_at,
  ats.state
FROM public.attendance_sessions ats
JOIN public.lectures l ON l.id = ats.lecture_id
JOIN public.profiles p ON p.id = ats.teacher_id
LEFT JOIN public.attendance_records ar ON ar.session_id = ats.id
GROUP BY ats.id, ats.session_date, l.course_code, l.title, p.full_name,
         ats.enrolled_snapshot_count, ats.started_at, ats.submitted_to_cloud_at, ats.state;

-- ============================================================================
-- Helper Security Functions & Row-Level Security (RLS)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS user_role
LANGUAGE SQL
STABLE
SECURITY DEFINER
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lectures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;

-- Profiles Policies
CREATE POLICY "profiles_select_own_or_admin" ON public.profiles
  FOR SELECT USING (
    id = auth.uid() OR public.current_user_role() = 'admin'
  );

-- Students Policies
CREATE POLICY "students_admin_all" ON public.students
  FOR ALL USING (public.current_user_role() = 'admin');

CREATE POLICY "students_teacher_read_enrolled" ON public.students
  FOR SELECT USING (
    public.current_user_role() = 'teacher'
    AND EXISTS (
      SELECT 1 FROM public.enrollments e
      JOIN public.lectures l ON l.id = e.lecture_id
      WHERE e.student_id = students.id
        AND l.teacher_id = auth.uid()
        AND e.active = TRUE
    )
  );

CREATE POLICY "students_self_read" ON public.students
  FOR SELECT USING (profile_id = auth.uid());

-- Lectures Policies
CREATE POLICY "lectures_admin_all" ON public.lectures
  FOR ALL USING (public.current_user_role() = 'admin');

CREATE POLICY "lectures_teacher_own" ON public.lectures
  FOR SELECT USING (teacher_id = auth.uid());

CREATE POLICY "lectures_student_enrolled" ON public.lectures
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.enrollments e
      JOIN public.students s ON s.id = e.student_id
      WHERE e.lecture_id = lectures.id
        AND s.profile_id = auth.uid()
        AND e.active = TRUE
    )
  );

-- Enrollments Policies
CREATE POLICY "enrollments_admin_all" ON public.enrollments
  FOR ALL USING (public.current_user_role() = 'admin');

CREATE POLICY "enrollments_teacher_own_lecture" ON public.enrollments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.lectures l
      WHERE l.id = enrollments.lecture_id AND l.teacher_id = auth.uid()
    )
  );

CREATE POLICY "enrollments_student_own" ON public.enrollments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id = enrollments.student_id AND s.profile_id = auth.uid()
    )
  );

-- Attendance Sessions Policies
CREATE POLICY "sessions_admin_all" ON public.attendance_sessions
  FOR ALL USING (public.current_user_role() = 'admin');

CREATE POLICY "sessions_teacher_manage_own" ON public.attendance_sessions
  FOR ALL USING (teacher_id = auth.uid())
  WITH CHECK (teacher_id = auth.uid());

-- Attendance Records Policies
CREATE POLICY "records_admin_all" ON public.attendance_records
  FOR ALL USING (public.current_user_role() = 'admin');

CREATE POLICY "records_teacher_manage_assigned_classes" ON public.attendance_records
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.lectures l
      WHERE l.id = attendance_records.lecture_id
        AND l.teacher_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.lectures l
      WHERE l.id = attendance_records.lecture_id
        AND l.teacher_id = auth.uid()
    )
  );

CREATE POLICY "records_student_read_own_only" ON public.attendance_records
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.students s
      WHERE s.id = attendance_records.student_id
        AND s.profile_id = auth.uid()
    )
  );

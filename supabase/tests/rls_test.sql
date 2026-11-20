\set ON_ERROR_STOP on

-- Run with psql against a disposable PostgreSQL 16 database:
--   psql -X -v ON_ERROR_STOP=1 -d lectureguard_test -f supabase/tests/rls_test.sql
-- Roles are cluster-wide, so create them before the test transaction.
DO $$
BEGIN
  CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;
DO $$
BEGIN
  CREATE ROLE authenticated NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

BEGIN;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer / 10000 <> 16 THEN
    RAISE EXCEPTION 'rls_test.sql requires PostgreSQL 16';
  END IF;
END;
$$;

CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

\ir ../migrations/001_lectureguard_schema.sql
\ir ../migrations/002_fix_rls_and_views.sql
\ir ../migrations/003_school_settings_and_analytics.sql
\ir ../migrations/004_harden_teacher_submission_logs.sql

DO $$
BEGIN
  IF (
    SELECT column_default IS NOT NULL
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'attendance_sessions'
      AND column_name = 'session_date'
  ) THEN
    RAISE EXCEPTION 'session_date still has a server-side default';
  END IF;
END;
$$;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.profiles, public.students, public.lectures, public.enrollments,
  public.attendance_sessions, public.attendance_records
  TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.profiles, public.students, public.lectures,
  public.enrollments, public.attendance_sessions, public.attendance_records
  TO authenticated;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('00000000-0000-0000-0000-000000000001', 'admin@example.test', '{"full_name":"Admin"}'),
  ('00000000-0000-0000-0000-000000000002', 'teacher1@example.test', '{"full_name":"Teacher One"}'),
  ('00000000-0000-0000-0000-000000000003', 'teacher2@example.test', '{"full_name":"Teacher Two"}'),
  ('00000000-0000-0000-0000-000000000004', 'student1@example.test', '{"full_name":"Student One"}'),
  ('00000000-0000-0000-0000-000000000005', 'student2@example.test', '{"full_name":"Student Two"}');

UPDATE public.profiles SET role = 'admin'
WHERE id = '00000000-0000-0000-0000-000000000001';
UPDATE public.profiles SET role = 'teacher'
WHERE id IN ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003');

INSERT INTO public.students (id, profile_id, student_code, first_name, last_name, grade_level, homeroom)
VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004',
   'STU-1', 'Student', 'One', 13, 'A'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000005',
   'STU-2', 'Student', 'Two', 8, 'B');

INSERT INTO public.lectures (id, course_code, title, teacher_id, room_number, period_number, academic_term)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'BIO-1', 'Biology One',
   '00000000-0000-0000-0000-000000000002', 'A1', 11, '2026-T1'),
  ('20000000-0000-0000-0000-000000000002', 'BIO-2', 'Biology Two',
   '00000000-0000-0000-0000-000000000003', 'B1', 1, '2026-T1');

INSERT INTO public.enrollments (lecture_id, student_id) VALUES
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');

INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
SELECT
  ('30000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  '20000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  DATE '2026-10-01' + (n - 1),
  'device-1'
FROM generate_series(1, 5) AS n;
INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
VALUES
  ('30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000003', DATE '2026-10-01', 'device-2');

INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
SELECT ats.id, ats.lecture_id, '10000000-0000-0000-0000-000000000001', 'present'
FROM public.attendance_sessions AS ats
WHERE ats.lecture_id = '20000000-0000-0000-0000-000000000001'
  AND ats.session_date <= DATE '2026-10-02';
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES (
  '30000000-0000-0000-0000-000000000004',
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'excused'
);
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES (
  '30000000-0000-0000-0000-000000000006',
  '20000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000002',
  'present'
);

-- Trigger-created accounts are always students and have a usable profile row.
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('00000000-0000-0000-0000-000000000006', 'newstudent@example.test', '{}');
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = '00000000-0000-0000-0000-000000000006'
      AND role = 'student'
      AND full_name = 'newstudent'
  ) THEN
    RAISE EXCEPTION 'auth.users trigger did not create the expected student profile';
  END IF;
END;
$$;

-- Anonymous clients cannot select either view or execute the staff log
-- function, even though table grants below deliberately allow testing that the
-- view ACL itself blocks access.
DO $$
BEGIN
  IF has_table_privilege('anon', 'public.v_student_attendance_summary', 'SELECT')
     OR has_table_privilege('anon', 'public.v_teacher_submission_logs', 'SELECT')
     OR has_table_privilege('anon', 'public.v_student_weekly_attendance', 'SELECT')
     OR has_table_privilege('anon', 'public.school_settings', 'SELECT')
     OR has_function_privilege(
       'anon',
       'public.teacher_submission_logs(integer,integer)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.admin_chronic_absentee_page(text,smallint,date,date)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'anon unexpectedly has view or function privilege';
  END IF;
END;
$$;

SET ROLE anon;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.profiles) <> 0
     OR (SELECT count(*) FROM public.students) <> 0
     OR (SELECT count(*) FROM public.lectures) <> 0
     OR (SELECT count(*) FROM public.enrollments) <> 0
     OR (SELECT count(*) FROM public.attendance_sessions) <> 0
     OR (SELECT count(*) FROM public.attendance_records) <> 0 THEN
    RAISE EXCEPTION 'anon unexpectedly read table rows';
  END IF;
  BEGIN
    PERFORM * FROM public.v_student_attendance_summary;
    RAISE EXCEPTION 'anon unexpectedly read the student summary view';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.v_teacher_submission_logs;
    RAISE EXCEPTION 'anon unexpectedly read the teacher logs view';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Student 1 sees only their own rows; missing attendance records count as absent.
-- Fixture recap (see the inserts above): sessions 1-5 belong to lecture BIO-1,
-- and student 1 has exactly THREE records there: 'present' on 2026-10-01,
-- 'present' on 2026-10-02 and 'excused' on 2026-10-04. Sessions 3 and 5 have no
-- record at all, which is what the implicit-absence assertions below rely on.
-- The fourth fixture record belongs to student 2 in another lecture, so it must
-- never be visible here.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
DO $$
DECLARE
  summary record;
  own_records integer;
BEGIN
  SELECT count(*) INTO own_records FROM public.attendance_records;
  IF (SELECT count(*) FROM public.students) <> 1
     OR (SELECT count(*) FROM public.lectures) <> 1
     OR (SELECT count(*) FROM public.enrollments) <> 1
     OR (SELECT count(*) FROM public.attendance_sessions) <> 5
     OR own_records <> 3
     OR (SELECT count(*) FROM public.school_settings) <> 1
     OR (SELECT count(*) FROM public.v_student_attendance_summary) <> 1
     OR (SELECT count(*) FROM public.teacher_submission_logs(1000, 0)) <> 0 THEN
    RAISE EXCEPTION
      'student can see rows outside their enrolled class (records=%, logs=%)',
      own_records,
      (SELECT count(*) FROM public.teacher_submission_logs(1000, 0));
  END IF;
  -- The submission log view is staff-only; a student must not read it directly
  -- and the SECURITY DEFINER function must return nothing for them.
  IF has_table_privilege(
       current_user, 'public.v_teacher_submission_logs', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'authenticated still holds SELECT on the teacher logs view';
  END IF;
  BEGIN
    PERFORM 1 FROM public.v_teacher_submission_logs;
    RAISE EXCEPTION 'student read the teacher logs view directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Regression guard for the fixture defect that used to make this file abort:
  -- student 2 has exactly one attendance record and it must stay invisible.
  IF EXISTS (
    SELECT 1 FROM public.attendance_records
    WHERE student_id = '10000000-0000-0000-0000-000000000002'
  ) THEN
    RAISE EXCEPTION 'student can read another student attendance record';
  END IF;
  IF (SELECT excused_counts_as_attended
      FROM public.school_settings WHERE id = 1) THEN
    RAISE EXCEPTION 'school setting did not default to not counting excused';
  END IF;

  SELECT * INTO summary
  FROM public.v_student_attendance_summary
  WHERE student_id = '10000000-0000-0000-0000-000000000001';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'student summary row is missing';
  END IF;
  IF summary.total_sessions <> 5
     OR summary.attended_sessions <> 2
     OR summary.unexcused_absences <> 2
     OR summary.attendance_percentage <> 40.0
     OR NOT summary.chronic_absenteeism_flag THEN
    RAISE EXCEPTION 'missing records were not counted as absences: %', row_to_json(summary);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.v_student_attendance_summary
    WHERE student_id <> '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'student can see another student summary';
  END IF;
END;
$$;
RESET ROLE;

-- Teacher 1 sees only their assigned class and may not write records against
-- another teacher's session/lecture or an unenrolled student.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SET ROLE authenticated;
DO $$
DECLARE
  updated_count integer;
  own_records integer;
BEGIN
  SELECT count(*) INTO own_records FROM public.attendance_records;
  IF (SELECT count(*) FROM public.students) <> 1
     OR (SELECT count(*) FROM public.lectures) <> 1
     OR (SELECT count(*) FROM public.enrollments) <> 1
     OR (SELECT count(*) FROM public.attendance_sessions) <> 5
     OR own_records <> 3
     OR (SELECT count(*) FROM public.teacher_submission_logs(1000, 0)) <> 5 THEN
    RAISE EXCEPTION
      'teacher can see rows outside their assigned class (records=%, logs=%)',
      own_records,
      (SELECT count(*) FROM public.teacher_submission_logs(1000, 0));
  END IF;
  -- The log function is scoped by session ownership, not by view policies.
  IF EXISTS (
    SELECT 1 FROM public.teacher_submission_logs(1000, 0)
    WHERE course_code <> 'BIO-1'
  ) THEN
    RAISE EXCEPTION 'teacher submission log leaked another teacher session';
  END IF;

  UPDATE public.school_settings
  SET excused_counts_as_attended = TRUE
  WHERE id = 1;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> 0 THEN
    RAISE EXCEPTION 'teacher changed a school-wide admin setting';
  END IF;

  -- A teacher may record attendance for their own session. Session 3 has no
  -- record for this student yet, so this is an insert (session 4 already holds
  -- the 'excused' fixture row and is protected by a unique constraint).
  INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
  VALUES (
    '30000000-0000-0000-0000-000000000003',
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'late'
  );

  BEGIN
    INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
    VALUES (
      '30000000-0000-0000-0000-000000000006',
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      'late'
    );
    RAISE EXCEPTION 'teacher wrote a record against another teacher session';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
    VALUES (
      '30000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000002',
      'late'
    );
    RAISE EXCEPTION 'teacher wrote a record for a student not enrolled in their class';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.attendance_records (
      session_id, lecture_id, student_id, status, override_by
    )
    VALUES (
      '30000000-0000-0000-0000-000000000005',
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      'present',
      '00000000-0000-0000-0000-000000000001'
    );
    RAISE EXCEPTION 'teacher attributed an override to another profile';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

-- Admin access remains school-wide and can insert/update profiles.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
SET ROLE authenticated;
DO $$
DECLARE
  summary record;
  updated_count integer;
BEGIN
  IF (SELECT count(*) FROM public.students) <> 2
     OR (SELECT count(*) FROM public.lectures) <> 2
     OR (SELECT count(*) FROM public.enrollments) <> 2
     OR (SELECT count(*) FROM public.attendance_sessions) <> 6
     OR (SELECT count(*) FROM public.v_student_attendance_summary) <> 2
     OR (SELECT count(*) FROM public.teacher_submission_logs(1000, 0)) <> 6 THEN
    RAISE EXCEPTION 'admin cannot see school-wide data';
  END IF;

  INSERT INTO public.profiles (id, full_name, email, role)
  VALUES (
    '00000000-0000-0000-0000-000000000006',
    'New Student Updated',
    'newstudent@example.test',
    'student'
  )
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name;
  IF (SELECT full_name FROM public.profiles
      WHERE id = '00000000-0000-0000-0000-000000000006') <> 'New Student Updated' THEN
    RAISE EXCEPTION 'admin profile insert/update policy failed';
  END IF;

  UPDATE public.school_settings
  SET excused_counts_as_attended = TRUE,
      updated_by = auth.uid()
  WHERE id = 1;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> 1 THEN
    RAISE EXCEPTION 'admin could not update school-wide attendance settings';
  END IF;

  SELECT * INTO summary
  FROM public.v_student_attendance_summary
  WHERE student_id = '10000000-0000-0000-0000-000000000001';
  IF summary.attended_sessions <> 4
     OR summary.attendance_percentage <> 80.0
     OR summary.chronic_absenteeism_flag THEN
    RAISE EXCEPTION 'excused attendance setting did not update summary: %',
      row_to_json(summary);
  END IF;

  IF (SELECT count(*) FROM public.v_student_weekly_attendance) = 0 THEN
    RAISE EXCEPTION 'weekly attendance view returned no rows';
  END IF;

  UPDATE public.school_settings
  SET excused_counts_as_attended = FALSE,
      updated_by = auth.uid()
  WHERE id = 1;
  IF (SELECT count(*) FROM public.admin_chronic_absentee_page(
        'STU-1', 13::smallint, DATE '2026-10-01', DATE '2026-10-05'
      )) <> 1 THEN
    RAISE EXCEPTION 'filtered chronic-absence page returned the wrong result';
  END IF;
END;
$$;
RESET ROLE;

ROLLBACK;
\echo 'rls_test.sql passed'

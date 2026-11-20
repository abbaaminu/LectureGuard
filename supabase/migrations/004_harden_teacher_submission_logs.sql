-- ============================================================================
-- 004 — Staff-only access to the teacher submission logs
--
-- public.v_teacher_submission_logs aggregates every session of every lecture.
-- Until now it was granted to `authenticated`, and because the view is declared
-- `security_invoker = true` the student policies on enrollments and
-- attendance_sessions applied to it: a student could read the submission log of
-- their own class (and any other row their table policies expose). Reporting is
-- a staff feature, so the view is no longer readable by client roles. Staff read
-- it through public.teacher_submission_logs(), a SECURITY DEFINER function that
-- returns rows only for the calling teacher, or everything for an admin.
--
-- The student summary view is intentionally left readable by `authenticated`:
-- the student attendance screen needs `v_student_attendance_summary`, and the
-- student policies there already restrict it to the caller's own row.
-- ============================================================================

REVOKE ALL ON public.v_teacher_submission_logs FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.teacher_submission_logs(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  session_id UUID,
  session_date DATE,
  course_code TEXT,
  lecture_title TEXT,
  teacher_name TEXT,
  enrolled_snapshot_count INTEGER,
  biometric_checked_in_count BIGINT,
  absent_count BIGINT,
  started_at TIMESTAMPTZ,
  submitted_to_cloud_at TIMESTAMPTZ,
  state public.session_state
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    logs.session_id,
    logs.session_date,
    logs.course_code,
    logs.lecture_title,
    logs.teacher_name,
    logs.enrolled_snapshot_count,
    logs.biometric_checked_in_count,
    logs.absent_count,
    logs.started_at,
    logs.submitted_to_cloud_at,
    logs.state
  FROM public.v_teacher_submission_logs AS logs
  WHERE auth.uid() IS NOT NULL
    AND (
      public.current_user_role() = 'admin'
      OR EXISTS (
        SELECT 1
        FROM public.attendance_sessions AS ats
        WHERE ats.id = logs.session_id
          AND ats.teacher_id = auth.uid()
      )
    )
  ORDER BY logs.session_date DESC, logs.session_id
  LIMIT GREATEST(p_limit, 0)
  OFFSET GREATEST(p_offset, 0)
$$;

REVOKE ALL ON FUNCTION public.teacher_submission_logs(INTEGER, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.teacher_submission_logs(INTEGER, INTEGER)
  TO authenticated;

COMMENT ON FUNCTION public.teacher_submission_logs(INTEGER, INTEGER) IS
  'Staff-only submission log: own sessions for a teacher, all sessions for an admin.';

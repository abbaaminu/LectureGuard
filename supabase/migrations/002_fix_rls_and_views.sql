-- Remove schema constraints that do not match the client-owned data model.
ALTER TABLE public.students
  DROP CONSTRAINT IF EXISTS students_grade_level_check;

ALTER TABLE public.lectures
  DROP CONSTRAINT IF EXISTS lectures_period_number_check;
ALTER TABLE public.lectures
  ADD CONSTRAINT lectures_period_number_check CHECK (period_number >= 1);

ALTER TABLE public.attendance_sessions
  ALTER COLUMN session_date DROP DEFAULT;

-- Definer helpers avoid policy-to-policy recursion when tables reference one
-- another. The optional session id also verifies the record's session mapping.
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.role
  FROM public.profiles AS p
  WHERE p.id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.my_student_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id
  FROM public.students AS s
  WHERE s.profile_id = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.teaches_lecture(
  p_lecture_id uuid,
  p_session_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.lectures AS l
    WHERE l.id = p_lecture_id
      AND l.teacher_id = auth.uid()
      AND (
        p_session_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM public.attendance_sessions AS ats
          WHERE ats.id = p_session_id
            AND ats.lecture_id = l.id
            AND ats.teacher_id = auth.uid()
        )
      )
  )
$$;

CREATE OR REPLACE FUNCTION public.is_enrolled_in(
  p_lecture_id uuid,
  p_student_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.enrollments AS e
    JOIN public.lectures AS l ON l.id = e.lecture_id
    WHERE e.student_id = p_student_id
      AND e.active
      AND (p_lecture_id IS NULL OR e.lecture_id = p_lecture_id)
      AND (
        (public.current_user_role() = 'teacher' AND l.teacher_id = auth.uid())
        OR (
          public.current_user_role() = 'student'
          AND p_student_id = public.my_student_id()
          AND (p_lecture_id IS NULL OR e.lecture_id = p_lecture_id)
        )
        OR public.current_user_role() = 'admin'
      )
  )
$$;

-- Student summaries count each enrolled class session, including sessions
-- without a corresponding attendance record.
CREATE OR REPLACE VIEW public.v_student_attendance_summary
WITH (security_invoker = true)
AS
SELECT
  s.id AS student_id,
  s.student_code,
  s.first_name,
  s.last_name,
  s.grade_level,
  s.homeroom,
  COUNT(ats.id) AS total_sessions,
  COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused')) AS attended_sessions,
  COUNT(ats.id) FILTER (
    WHERE ats.id IS NOT NULL AND (ar.id IS NULL OR ar.status = 'absent')
  ) AS unexcused_absences,
  COUNT(ar.id) FILTER (WHERE ar.status = 'late') AS late_count,
  ROUND(
    CASE
      WHEN COUNT(ats.id) = 0 THEN 100.0
      ELSE (
        COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused'))::numeric
        / COUNT(ats.id)
      ) * 100.0
    END,
    1
  ) AS attendance_percentage,
  CASE
    WHEN COUNT(ats.id) = 0 THEN FALSE
    ELSE (
      COUNT(ar.id) FILTER (WHERE ar.status IN ('present', 'late', 'excused'))::numeric
      / COUNT(ats.id)
    ) < 0.80
  END AS chronic_absenteeism_flag
FROM public.students AS s
LEFT JOIN public.enrollments AS e
  ON e.student_id = s.id AND e.active
LEFT JOIN public.attendance_sessions AS ats
  ON ats.lecture_id = e.lecture_id
LEFT JOIN public.attendance_records AS ar
  ON ar.session_id = ats.id
  AND ar.student_id = s.id
  AND ar.lecture_id = ats.lecture_id
WHERE s.active
GROUP BY s.id, s.student_code, s.first_name, s.last_name, s.grade_level, s.homeroom;

CREATE OR REPLACE VIEW public.v_teacher_submission_logs
WITH (security_invoker = true)
AS
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
FROM public.attendance_sessions AS ats
JOIN public.lectures AS l ON l.id = ats.lecture_id
LEFT JOIN public.profiles AS p ON p.id = ats.teacher_id
LEFT JOIN public.attendance_records AS ar ON ar.session_id = ats.id
GROUP BY ats.id, ats.session_date, l.course_code, l.title, p.full_name,
         ats.enrolled_snapshot_count, ats.started_at, ats.submitted_to_cloud_at, ats.state;

REVOKE ALL ON public.v_student_attendance_summary,
              public.v_teacher_submission_logs
  FROM PUBLIC, anon;
GRANT SELECT ON public.v_student_attendance_summary,
                public.v_teacher_submission_logs
  TO authenticated;

-- Replace every policy whose cross-table lookup could re-enter another policy.
DROP POLICY IF EXISTS "profiles_select_own_or_admin" ON public.profiles;
DROP POLICY IF EXISTS "students_admin_all" ON public.students;
DROP POLICY IF EXISTS "students_teacher_read_enrolled" ON public.students;
DROP POLICY IF EXISTS "students_self_read" ON public.students;
DROP POLICY IF EXISTS "lectures_admin_all" ON public.lectures;
DROP POLICY IF EXISTS "lectures_teacher_own" ON public.lectures;
DROP POLICY IF EXISTS "lectures_student_enrolled" ON public.lectures;
DROP POLICY IF EXISTS "enrollments_admin_all" ON public.enrollments;
DROP POLICY IF EXISTS "enrollments_teacher_own_lecture" ON public.enrollments;
DROP POLICY IF EXISTS "enrollments_student_own" ON public.enrollments;
DROP POLICY IF EXISTS "sessions_admin_all" ON public.attendance_sessions;
DROP POLICY IF EXISTS "sessions_teacher_manage_own" ON public.attendance_sessions;
DROP POLICY IF EXISTS "records_admin_all" ON public.attendance_records;
DROP POLICY IF EXISTS "records_teacher_manage_assigned_classes" ON public.attendance_records;
DROP POLICY IF EXISTS "records_student_read_own_only" ON public.attendance_records;

CREATE POLICY "profiles_select_own_or_admin" ON public.profiles
  FOR SELECT USING (id = auth.uid() OR public.current_user_role() = 'admin');
CREATE POLICY "profiles_admin_insert" ON public.profiles
  FOR INSERT WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "profiles_admin_update" ON public.profiles
  FOR UPDATE
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');

CREATE POLICY "students_admin_all" ON public.students
  FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "students_teacher_read_enrolled" ON public.students
  FOR SELECT USING (
    public.current_user_role() = 'teacher'
    AND public.is_enrolled_in(NULL, students.id)
  );
CREATE POLICY "students_self_read" ON public.students
  FOR SELECT USING (id = public.my_student_id());

CREATE POLICY "lectures_admin_all" ON public.lectures
  FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "lectures_teacher_own" ON public.lectures
  FOR SELECT USING (public.teaches_lecture(id));
CREATE POLICY "lectures_student_enrolled" ON public.lectures
  FOR SELECT USING (public.is_enrolled_in(id, public.my_student_id()));

CREATE POLICY "enrollments_admin_all" ON public.enrollments
  FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "enrollments_teacher_own_lecture" ON public.enrollments
  FOR SELECT USING (public.teaches_lecture(lecture_id));
CREATE POLICY "enrollments_student_own" ON public.enrollments
  FOR SELECT USING (student_id = public.my_student_id());

CREATE POLICY "sessions_admin_all" ON public.attendance_sessions
  FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "sessions_teacher_manage_own" ON public.attendance_sessions
  FOR ALL
  USING (teacher_id = auth.uid() AND public.teaches_lecture(lecture_id))
  WITH CHECK (teacher_id = auth.uid() AND public.teaches_lecture(lecture_id));
CREATE POLICY "sessions_student_read_enrolled" ON public.attendance_sessions
  FOR SELECT USING (public.is_enrolled_in(lecture_id, public.my_student_id()));

CREATE POLICY "records_admin_all" ON public.attendance_records
  FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');
CREATE POLICY "records_teacher_manage_assigned_classes" ON public.attendance_records
  FOR ALL
  USING (
    public.teaches_lecture(lecture_id, session_id)
    AND public.is_enrolled_in(lecture_id, student_id)
  )
  WITH CHECK (
    public.teaches_lecture(lecture_id, session_id)
    AND public.is_enrolled_in(lecture_id, student_id)
  );
CREATE POLICY "records_student_read_own_only" ON public.attendance_records
  FOR SELECT USING (student_id = public.my_student_id());

-- Newly created auth accounts receive a least-privilege student profile.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, role)
  VALUES (
    NEW.id,
    COALESCE(
      NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
      NULLIF(NEW.raw_user_meta_data ->> 'name', ''),
      NULLIF(split_part(NEW.email, '@', 1), ''),
      NEW.id::text
    ),
    COALESCE(NEW.email, NEW.id::text || '@no-email.invalid'),
    'student'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

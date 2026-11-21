CREATE TABLE public.school_settings (
  id SMALLINT PRIMARY KEY CHECK (id = 1),
  excused_counts_as_attended BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by UUID REFERENCES public.profiles(id)
);

INSERT INTO public.school_settings (id, excused_counts_as_attended)
VALUES (1, FALSE)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.school_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "school_settings_authenticated_read"
  ON public.school_settings
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

CREATE POLICY "school_settings_admin_update"
  ON public.school_settings
  FOR UPDATE
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');

GRANT SELECT, UPDATE ON public.school_settings TO authenticated;
REVOKE ALL ON public.school_settings FROM PUBLIC, anon;

DROP POLICY IF EXISTS "records_teacher_manage_assigned_classes"
  ON public.attendance_records;
CREATE POLICY "records_teacher_manage_assigned_classes"
  ON public.attendance_records
  FOR ALL
  USING (
    public.teaches_lecture(lecture_id, session_id)
    AND public.is_enrolled_in(lecture_id, student_id)
  )
  WITH CHECK (
    public.teaches_lecture(lecture_id, session_id)
    AND public.is_enrolled_in(lecture_id, student_id)
    AND (override_by IS NULL OR override_by = auth.uid())
  );

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
  COUNT(ats.id) FILTER (
    WHERE ar.status IN ('present', 'late')
       OR (settings.excused_counts_as_attended AND ar.status = 'excused')
  ) AS attended_sessions,
  COUNT(ats.id) FILTER (
    WHERE ats.id IS NOT NULL AND (ar.id IS NULL OR ar.status = 'absent')
  ) AS unexcused_absences,
  COUNT(ar.id) FILTER (WHERE ar.status = 'late') AS late_count,
  ROUND(
    CASE
      WHEN COUNT(ats.id) = 0 THEN 100.0
      ELSE (
        COUNT(ats.id) FILTER (
          WHERE ar.status IN ('present', 'late')
             OR (settings.excused_counts_as_attended AND ar.status = 'excused')
        )::NUMERIC / COUNT(ats.id)
      ) * 100.0
    END,
    1
  ) AS attendance_percentage,
  CASE
    WHEN COUNT(ats.id) = 0 THEN FALSE
    ELSE (
      COUNT(ats.id) FILTER (
        WHERE ar.status IN ('present', 'late')
           OR (settings.excused_counts_as_attended AND ar.status = 'excused')
      )::NUMERIC / COUNT(ats.id)
    ) < 0.80
  END AS chronic_absenteeism_flag
FROM public.students AS s
CROSS JOIN public.school_settings AS settings
LEFT JOIN public.enrollments AS e
  ON e.student_id = s.id AND e.active
LEFT JOIN public.attendance_sessions AS ats
  ON ats.lecture_id = e.lecture_id
LEFT JOIN public.attendance_records AS ar
  ON ar.session_id = ats.id
  AND ar.student_id = s.id
  AND ar.lecture_id = ats.lecture_id
WHERE s.active
GROUP BY s.id, s.student_code, s.first_name, s.last_name, s.grade_level,
         s.homeroom, settings.excused_counts_as_attended;

CREATE OR REPLACE VIEW public.v_student_weekly_attendance
WITH (security_invoker = true)
AS
SELECT
  s.id AS student_id,
  s.student_code,
  s.first_name,
  s.last_name,
  DATE_TRUNC('week', ats.session_date::TIMESTAMP)::DATE AS week_start,
  COUNT(ats.id) AS total_sessions,
  COUNT(ats.id) FILTER (
    WHERE ar.status IN ('present', 'late')
       OR (settings.excused_counts_as_attended AND ar.status = 'excused')
  ) AS attended_sessions,
  ROUND(
    (
      COUNT(ats.id) FILTER (
        WHERE ar.status IN ('present', 'late')
           OR (settings.excused_counts_as_attended AND ar.status = 'excused')
      )::NUMERIC / NULLIF(COUNT(ats.id), 0)
    ) * 100.0,
    1
  ) AS attendance_percentage
FROM public.students AS s
CROSS JOIN public.school_settings AS settings
JOIN public.enrollments AS e
  ON e.student_id = s.id AND e.active
JOIN public.attendance_sessions AS ats
  ON ats.lecture_id = e.lecture_id
LEFT JOIN public.attendance_records AS ar
  ON ar.session_id = ats.id
  AND ar.student_id = s.id
  AND ar.lecture_id = ats.lecture_id
WHERE s.active
GROUP BY s.id, s.student_code, s.first_name, s.last_name,
         DATE_TRUNC('week', ats.session_date::TIMESTAMP)::DATE,
         settings.excused_counts_as_attended;

CREATE OR REPLACE FUNCTION public.admin_chronic_absentee_page(
  p_search TEXT DEFAULT NULL,
  p_grade_level SMALLINT DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
  student_id UUID,
  student_code TEXT,
  first_name TEXT,
  last_name TEXT,
  grade_level SMALLINT,
  homeroom TEXT,
  total_sessions BIGINT,
  attended_sessions BIGINT,
  attendance_percentage NUMERIC,
  chronic_absenteeism_flag BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH attendance_totals AS (
    SELECT
      s.id,
      s.student_code,
      s.first_name,
      s.last_name,
      s.grade_level,
      s.homeroom,
      COUNT(ats.id) AS total_sessions,
      COUNT(ats.id) FILTER (
        WHERE ar.status IN ('present', 'late')
           OR (settings.excused_counts_as_attended AND ar.status = 'excused')
      ) AS attended_sessions
    FROM public.students AS s
    CROSS JOIN public.school_settings AS settings
    LEFT JOIN public.enrollments AS e
      ON e.student_id = s.id AND e.active
    LEFT JOIN public.attendance_sessions AS ats
      ON ats.lecture_id = e.lecture_id
      AND (p_start_date IS NULL OR ats.session_date >= p_start_date)
      AND (p_end_date IS NULL OR ats.session_date <= p_end_date)
    LEFT JOIN public.attendance_records AS ar
      ON ar.session_id = ats.id
      AND ar.student_id = s.id
      AND ar.lecture_id = ats.lecture_id
    WHERE s.active
      AND public.current_user_role() = 'admin'
      AND (
        p_search IS NULL
        OR CONCAT_WS(' ', s.student_code, s.first_name, s.last_name)
          ILIKE '%' || p_search || '%'
      )
      AND (p_grade_level IS NULL OR s.grade_level = p_grade_level)
    GROUP BY s.id, s.student_code, s.first_name, s.last_name,
             s.grade_level, s.homeroom, settings.excused_counts_as_attended
  ),
  percentages AS (
    SELECT
      id,
      student_code,
      first_name,
      last_name,
      grade_level,
      homeroom,
      total_sessions,
      attended_sessions,
      ROUND(
        CASE
          WHEN total_sessions = 0 THEN 100.0
          ELSE attended_sessions::NUMERIC / total_sessions * 100.0
        END,
        1
      ) AS attendance_percentage
    FROM attendance_totals
  )
  SELECT
    id,
    student_code,
    first_name,
    last_name,
    grade_level,
    homeroom,
    total_sessions,
    attended_sessions,
    attendance_percentage,
    attendance_percentage < 80.0
  FROM percentages
  WHERE attendance_percentage < 80.0
  ORDER BY attendance_percentage ASC, last_name ASC, first_name ASC, id ASC
$$;

REVOKE ALL ON public.v_student_weekly_attendance FROM PUBLIC, anon;
GRANT SELECT ON public.v_student_weekly_attendance TO authenticated;
REVOKE ALL ON FUNCTION public.admin_chronic_absentee_page(
  TEXT, SMALLINT, DATE, DATE
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_chronic_absentee_page(
  TEXT, SMALLINT, DATE, DATE
) TO authenticated;

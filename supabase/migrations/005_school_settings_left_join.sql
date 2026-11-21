-- ============================================================================
-- 005 — Views must not depend on the school_settings row existing
--
-- 003 joined public.school_settings with a CROSS JOIN. school_settings holds a
-- single row (id = 1) that an administrator can delete, and a missing row made
-- the CROSS JOIN drop every student: the summary, the weekly trend and the
-- chronic-absence page silently returned nothing instead of treating excused
-- absences as not attended. A LEFT JOIN plus COALESCE keeps the documented
-- default (excused absences do not count as attended) when the row is absent.
-- ============================================================================

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
       OR (COALESCE(settings.excused_counts_as_attended, FALSE)
           AND ar.status = 'excused')
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
             OR (COALESCE(settings.excused_counts_as_attended, FALSE)
                 AND ar.status = 'excused')
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
           OR (COALESCE(settings.excused_counts_as_attended, FALSE)
               AND ar.status = 'excused')
      )::NUMERIC / COUNT(ats.id)
    ) < 0.80
  END AS chronic_absenteeism_flag
FROM public.students AS s
LEFT JOIN public.school_settings AS settings
  ON settings.id = 1
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
       OR (COALESCE(settings.excused_counts_as_attended, FALSE)
           AND ar.status = 'excused')
  ) AS attended_sessions,
  ROUND(
    (
      COUNT(ats.id) FILTER (
        WHERE ar.status IN ('present', 'late')
           OR (COALESCE(settings.excused_counts_as_attended, FALSE)
               AND ar.status = 'excused')
      )::NUMERIC / NULLIF(COUNT(ats.id), 0)
    ) * 100.0,
    1
  ) AS attendance_percentage
FROM public.students AS s
LEFT JOIN public.school_settings AS settings
  ON settings.id = 1
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
           OR (COALESCE(settings.excused_counts_as_attended, FALSE)
               AND ar.status = 'excused')
      ) AS attended_sessions
    FROM public.students AS s
    LEFT JOIN public.school_settings AS settings
      ON settings.id = 1
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

-- Students are created from a lecture roster; grade and homeroom can be filled
-- in later by the school if that information is available.
ALTER TABLE public.students
  ALTER COLUMN grade_level DROP NOT NULL,
  ALTER COLUMN homeroom DROP NOT NULL;

-- School staff can review student and enrollment data, but enrollment is now a
-- teacher-owned lecture workflow rather than an admin-management control.
DROP POLICY IF EXISTS "students_admin_all" ON public.students;
DROP POLICY IF EXISTS "students_admin_select" ON public.students;
CREATE POLICY "students_admin_select" ON public.students
  FOR SELECT USING (public.current_user_role() = 'admin');

DROP POLICY IF EXISTS "enrollments_admin_all" ON public.enrollments;
DROP POLICY IF EXISTS "enrollments_admin_select" ON public.enrollments;
CREATE POLICY "enrollments_admin_select" ON public.enrollments
  FOR SELECT USING (public.current_user_role() = 'admin');

CREATE OR REPLACE FUNCTION public.teacher_enroll_student(
  p_lecture_id uuid,
  p_student_id uuid,
  p_student_code text,
  p_first_name text,
  p_last_name text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_student_id uuid;
  v_student_code text := NULLIF(btrim(p_student_code), '');
  v_first_name text := NULLIF(btrim(p_first_name), '');
  v_last_name text := btrim(COALESCE(p_last_name, ''));
BEGIN
  IF auth.uid() IS NULL
     OR NOT COALESCE(public.current_user_role() = 'teacher', FALSE)
     OR NOT public.teaches_lecture(p_lecture_id) THEN
    RAISE EXCEPTION 'Teachers may enroll students only in their assigned lectures.'
      USING ERRCODE = '42501';
  END IF;
  IF p_lecture_id IS NULL
     OR p_student_id IS NULL
     OR v_student_code IS NULL
     OR v_first_name IS NULL THEN
    RAISE EXCEPTION 'Lecture, student id, registration number, and name are required.'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.students (
    id, student_code, first_name, last_name, grade_level, homeroom
  )
  VALUES (
    p_student_id, v_student_code, v_first_name, v_last_name, NULL, NULL
  )
  ON CONFLICT (student_code) DO NOTHING;

  SELECT s.id
  INTO v_student_id
  FROM public.students AS s
  WHERE s.student_code = v_student_code;

  INSERT INTO public.enrollments (lecture_id, student_id, active)
  VALUES (p_lecture_id, v_student_id, TRUE)
  ON CONFLICT (lecture_id, student_id)
  DO UPDATE SET active = TRUE;

  RETURN v_student_id;
END;
$$;

REVOKE ALL ON FUNCTION public.teacher_enroll_student(
  uuid, uuid, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_enroll_student(
  uuid, uuid, text, text, text
) TO authenticated;

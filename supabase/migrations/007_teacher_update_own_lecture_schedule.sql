-- Teachers may maintain timetable details for their own assigned lectures,
-- while course identity and assignment remain administrator-owned.

DROP POLICY IF EXISTS "lectures_teacher_update_own_schedule" ON public.lectures;
CREATE POLICY "lectures_teacher_update_own_schedule" ON public.lectures
  FOR UPDATE
  USING (
    public.current_user_role() = 'teacher'
    AND teacher_id = auth.uid()
  )
  WITH CHECK (
    public.current_user_role() = 'teacher'
    AND teacher_id = auth.uid()
  );

CREATE OR REPLACE FUNCTION public.guard_teacher_lecture_schedule_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF public.current_user_role() = 'teacher'
     AND (
       NEW.id IS DISTINCT FROM OLD.id
       OR NEW.teacher_id IS DISTINCT FROM OLD.teacher_id
       OR NEW.course_code IS DISTINCT FROM OLD.course_code
       OR NEW.title IS DISTINCT FROM OLD.title
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
     ) THEN
    RAISE EXCEPTION
      'Teachers may update timetable details, but not course identity or assignment.'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_teacher_lecture_schedule_update
  ON public.lectures;
CREATE TRIGGER guard_teacher_lecture_schedule_update
  BEFORE UPDATE ON public.lectures
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_teacher_lecture_schedule_update();

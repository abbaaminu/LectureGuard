import { Lecture, Student, TeacherSubmissionLog } from '../types/attendance';

const FIRST_NAMES = [
  'Aarav', 'Abigail', 'Adrian', 'Amina', 'Benjamin', 'Bianca', 'Caleb', 'Camila',
  'Chloe', 'Daniel', 'Darius', 'Elena', 'Elijah', 'Emma', 'Ethan', 'Fatima',
  'Gabriel', 'Grace', 'Hannah', 'Harper', 'Hassan', 'Henry', 'Isaac', 'Isabella',
  'Jacob', 'Jasmine', 'Jordan', 'Julian', 'Kaitlyn', 'Kenji', 'Khloe', 'Liam',
  'Lillian', 'Lucas', 'Madison', 'Malik', 'Maya', 'Mateo', 'Nadia', 'Nathan',
  'Noah', 'Nora', 'Oliver', 'Olivia', 'Owen', 'Priya', 'Penelope', 'Quinn',
  'Rachel', 'Rafael', 'Riley', 'Ryan', 'Samuel', 'Sarah', 'Sebastian', 'Sofia',
  'Sophia', 'Tariq', 'Taylor', 'Theo', 'Uma', 'Victor', 'Victoria', 'William',
  'Wyatt', 'Xavier', 'Yara', 'Zachary', 'Zainab', 'Zoe', 'Amara', 'Brandon',
  'Clara', 'Devon', 'Eva', 'Felix', 'Gemma', 'Hugo', 'Iris', 'Jude',
  'Kira', 'Leo', 'Mila', 'Nolan', 'Oscar', 'Piper', 'Rowan', 'Sienna',
  'Tessa', 'Umar', 'Vera', 'Wesley', 'Xena', 'Yusuf', 'Zara', 'Arthur',
];

const LAST_NAMES_BY_LETTER: Record<string, string[]> = {
  A: ['Abbott', 'Adams', 'Alvarez', 'Anderson', 'Andrews', 'Armstrong', 'Austin', 'Avery', 'Ayala', 'Aziz'],
  B: ['Bailey', 'Bakari', 'Baker', 'Barnes', 'Bennett', 'Brooks', 'Brown', 'Bryant', 'Burns', 'Butler'],
  C: ['Campbell', 'Carter', 'Castillo', 'Castro', 'Chambers', 'Chapman', 'Chavez', 'Chen', 'Clark', 'Coleman', 'Collins', 'Cooper', 'Cox', 'Cruz'],
  D: ['Daniels', 'Davidson', 'Davis', 'Dawson', 'Dean', 'Delgado', 'Diaz', 'Dixon', 'Douglas', 'Duncan', 'Dunn'],
  E: ['Edwards', 'Elliott', 'Ellis', 'Erickson', 'Estrada', 'Evans'],
  F: ['Farooq', 'Ferguson', 'Fernandez', 'Fields', 'Fisher', 'Fleming', 'Flores', 'Ford', 'Foster', 'Fowler', 'Fox', 'Franklin', 'Freeman'],
  G: ['Gallagher', 'Garcia', 'Gardner', 'Garrett', 'Garza', 'Gibson', 'Gilbert', 'Gomez', 'Gonzales', 'Goodman', 'Gordon', 'Graham', 'Grant', 'Gray', 'Green', 'Greene', 'Griffin', 'Guerrero', 'Gutierrez'],
  H: ['Hale', 'Hall', 'Hamilton', 'Hansen', 'Hanson', 'Harper', 'Harris', 'Harrison', 'Hart', 'Harvey', 'Hawkins', 'Hayes', 'Henderson', 'Henry', 'Hernandez', 'Hicks', 'Hill', 'Hoffman', 'Holland', 'Holmes', 'Hopkins', 'Howard', 'Howell', 'Hudson', 'Hughes', 'Hunt', 'Hunter', 'Hussain'],
  I: ['Ibrahim', 'Ingram', 'Irwin', 'Isaac', 'Ibarra'],
  J: ['Jackson', 'Jacobs', 'James', 'Jenkins', 'Jennings', 'Jensen', 'Jimenez', 'Johnson', 'Johnston', 'Jones', 'Jordan', 'Joseph'],
  K: ['Keller', 'Kelley', 'Kelly', 'Kennedy', 'Khan', 'Kim', 'Kimura', 'King', 'Knight', 'Kowalski', 'Kumar'],
  L: ['Lambert', 'Lane', 'Larson', 'Lawrence', 'Lawson', 'Lee', 'Leonard', 'Lewis', 'Lin', 'Little', 'Long', 'Lopez', 'Lucas', 'Lynch'],
  M: ['MacDonald', 'Maldonado', 'Malik', 'Mann', 'Marshall', 'Martin', 'Martinez', 'Mason', 'Matthews', 'May', 'McCoy', 'McDonald', 'Medina', 'Mendez', 'Mendoza', 'Mensah', 'Meyer', 'Miller', 'Mills', 'Mitchell', 'Montgomery', 'Moore', 'Morales', 'Moreno', 'Morgan', 'Morris', 'Morrison', 'Murphy', 'Murray', 'Myers'],
  N: ['Nair', 'Nakamura', 'Navarro', 'Neal', 'Nelson', 'Newman', 'Nguyen', 'Nichols', 'Norman', 'Norris', 'Novak', 'Nunez'],
  O: ['O\'Brien', 'O\'Connor', 'Okafor', 'Oliver', 'Olson', 'Ortega', 'Ortiz', 'Osborne', 'Osei', 'Owens'],
  P: ['Pacheco', 'Padilla', 'Page', 'Palmer', 'Park', 'Parker', 'Patel', 'Patterson', 'Payne', 'Pearson', 'Pena', 'Perez', 'Perkins', 'Perry', 'Peters', 'Peterson', 'Phillips', 'Pierce', 'Porter', 'Powell', 'Powers', 'Price'],
  Q: ['Quinn', 'Quintero', 'Quiroz', 'Quincy'],
  R: ['Ramirez', 'Ramos', 'Ray', 'Reed', 'Reeves', 'Reid', 'Reyes', 'Reynolds', 'Rhodes', 'Rice', 'Richards', 'Richardson', 'Riley', 'Rivera', 'Robbins', 'Roberts', 'Robertson', 'Robinson', 'Rodriguez', 'Rogers', 'Romero', 'Rose', 'Ross', 'Ruiz', 'Russell', 'Ryan'],
  S: ['Salazar', 'Sanchez', 'Sanders', 'Sandoval', 'Santiago', 'Santos', 'Saunders', 'Schmidt', 'Schneider', 'Schultz', 'Scott', 'Serrano', 'Sharp', 'Shaw', 'Shelton', 'Sherman', 'Silva', 'Simmons', 'Simon', 'Simpson', 'Sims', 'Singh', 'Smith', 'Snyder', 'Soto', 'Spencer', 'Stanley', 'Steele', 'Stephens', 'Stevens', 'Stewart', 'Stone', 'Sullivan', 'Summers', 'Sutton', 'Swanson'],
  T: ['Tadesse', 'Takahashi', 'Tanaka', 'Taylor', 'Terry', 'Thomas', 'Thompson', 'Thornton', 'Todd', 'Torres', 'Townsend', 'Tran', 'Tucker', 'Turner'],
  U: ['Uddin', 'Underwood', 'Upton', 'Urban', 'Uribe'],
  V: ['Valdez', 'Valencia', 'Valentine', 'Vance', 'Vargas', 'Vasquez', 'Vaughan', 'Vazquez', 'Vega', 'Velazquez', 'Velez', 'Villarreal', 'Vincent'],
  W: ['Wade', 'Wagner', 'Walker', 'Wallace', 'Walsh', 'Walters', 'Walton', 'Wang', 'Ward', 'Warner', 'Warren', 'Washington', 'Waters', 'Watkins', 'Watson', 'Watts', 'Weaver', 'Webb', 'Weber', 'Webster', 'Welch', 'Wells', 'West', 'Wheeler', 'White', 'Whitehead', 'Williams', 'Williamson', 'Willis', 'Wilson', 'Winters', 'Wise', 'Wolf', 'Wolfe', 'Wong', 'Wood', 'Woods', 'Woodward', 'Wright', 'Wu', 'Wyatt'],
  X: ['Xavier', 'Xie', 'Xiong', 'Xu'],
  Y: ['Yadav', 'Yamamoto', 'Yang', 'Yates', 'Ye', 'Yoder', 'Yoon', 'York', 'Young', 'Youssef', 'Yu'],
  Z: ['Zaidi', 'Zamora', 'Zavala', 'Zhang', 'Zhao', 'Zhou', 'Zimmerman', 'Zuniga'],
};

const ALL_SURNAMES: string[] = Object.values(LAST_NAMES_BY_LETTER).flat();

function build300Students(): Student[] {
  const totalCount = 300;
  const students: Student[] = [];
  const homerooms = ['A', 'B', 'C', 'D'];
  const grades: Array<9 | 10 | 11 | 12> = [9, 10, 11, 12];

  // Ensure every A-Z initial is represented across 300 deterministic students
  const letters = Object.keys(LAST_NAMES_BY_LETTER);
  const pickedLastNames: string[] = [];

  // First pass: guarantee at least 2 from each letter
  letters.forEach((letter) => {
    const pool = LAST_NAMES_BY_LETTER[letter];
    pickedLastNames.push(pool[0]);
    if (pool.length > 1) pickedLastNames.push(pool[1]);
  });

  // Fill remaining up to 300 deterministically across ALL_SURNAMES
  let cursor = 0;
  while (pickedLastNames.length < totalCount) {
    pickedLastNames.push(ALL_SURNAMES[(cursor * 7 + 3) % ALL_SURNAMES.length]);
    cursor += 1;
  }

  for (let i = 0; i < totalCount; i += 1) {
    const firstName = FIRST_NAMES[(i * 11 + 5) % FIRST_NAMES.length];
    const lastName = pickedLastNames[i];
    const gradeLevel = grades[i % grades.length];
    const homeroom = `${gradeLevel}-${homerooms[i % homerooms.length]}`;
    const num = String(i + 101).padStart(4, '0');

    // ~6% chronic absenteeism (<80%) for realistic management flags
    const isAtRisk = i % 17 === 4;
    const basePct = isAtRisk ? 71 + (i % 7) : 88 + (i % 12);
    const term1Pct = Math.min(100, basePct + (i % 3));
    const term2Pct = Math.min(100, Math.max(64, basePct - (isAtRisk ? 3 : 1)));
    const term3Pct = Math.min(100, Math.max(66, basePct + (isAtRisk ? -2 : 2)));
    const unexcusedAbsences = isAtRisk ? 7 + (i % 5) : i % 3;

    students.push({
      id: `stu-${num}`,
      studentCode: `HS-2026-${num}`,
      firstName,
      lastName,
      gradeLevel,
      homeroom,
      guardianEmail: `${firstName.toLowerCase()}.${lastName.toLowerCase().replace(/[^a-z]/g, '')}.parent@oakridge.edu`,
      term1Pct,
      term2Pct,
      term3Pct,
      unexcusedAbsences,
    });
  }

  return students.sort(
    (a, b) => a.lastName.localeCompare(b.lastName) || a.firstName.localeCompare(b.firstName),
  );
}

export const SEED_STUDENTS: Student[] = build300Students();

export const SEED_LECTURES: Lecture[] = [
  {
    id: 'lec-bio-301',
    courseCode: 'BIO-301',
    title: 'AP Biology — Main Auditorium (Period 3)',
    teacherId: 'tch-01',
    teacherName: 'Dr. Elena Vance',
    roomNumber: 'Auditorium A',
    periodNumber: 3,
    lateGraceMinutes: 10,
    enrolledStudentIds: SEED_STUDENTS.map((s) => s.id), // 300 enrolled students
  },
  {
    id: 'lec-math-204',
    courseCode: 'MATH-204',
    title: 'AP Calculus AB — Lecture Hall B (Period 1)',
    teacherId: 'tch-02',
    teacherName: 'Marcus Holloway',
    roomNumber: 'Hall B-118',
    periodNumber: 1,
    lateGraceMinutes: 8,
    enrolledStudentIds: SEED_STUDENTS.slice(0, 145).map((s) => s.id),
  },
  {
    id: 'lec-hist-110',
    courseCode: 'HIST-110',
    title: 'Modern World History — Amphitheater (Period 5)',
    teacherId: 'tch-03',
    teacherName: 'Claire Bennett',
    roomNumber: 'Hall 302',
    periodNumber: 5,
    lateGraceMinutes: 10,
    enrolledStudentIds: SEED_STUDENTS.slice(80, 260).map((s) => s.id),
  },
];

export const SEED_TEACHER_LOGS: TeacherSubmissionLog[] = [
  {
    id: 'log-01',
    sessionDate: '2026-11-17',
    courseCode: 'MATH-204',
    lectureTitle: 'AP Calculus AB — Lecture Hall B',
    teacherName: 'Marcus Holloway',
    department: 'Mathematics',
    enrolledCount: 145,
    checkedInCount: 141,
    lateCount: 4,
    absentCount: 4,
    submittedAt: '2026-11-17T08:14:22Z',
    syncState: 'synced',
  },
  {
    id: 'log-02',
    sessionDate: '2026-11-17',
    courseCode: 'CHEM-210',
    lectureTitle: 'Honors Chemistry — Science Wing',
    teacherName: 'Dr. Priya Nair',
    department: 'Science',
    enrolledCount: 112,
    checkedInCount: 107,
    lateCount: 3,
    absentCount: 5,
    submittedAt: '2026-11-17T09:18:05Z',
    syncState: 'synced',
  },
  {
    id: 'log-03',
    sessionDate: '2026-11-17',
    courseCode: 'ENG-305',
    lectureTitle: 'AP English Literature — Hall C',
    teacherName: 'David Morales',
    department: 'Humanities',
    enrolledCount: 128,
    checkedInCount: 122,
    lateCount: 2,
    absentCount: 6,
    submittedAt: '2026-11-17T09:22:40Z',
    syncState: 'offline_queued',
  },
  {
    id: 'log-04',
    sessionDate: '2026-11-17',
    courseCode: 'CS-401',
    lectureTitle: 'Computer Science Principles — Auditorium',
    teacherName: 'Hannah Park',
    department: 'Engineering',
    enrolledCount: 210,
    checkedInCount: 204,
    lateCount: 5,
    absentCount: 6,
    submittedAt: '2026-11-17T10:11:12Z',
    syncState: 'synced',
  },
  {
    id: 'log-05',
    sessionDate: '2026-11-17',
    courseCode: 'PHYS-220',
    lectureTitle: 'AP Physics 1 — Period 3',
    teacherName: 'Samuel Osei',
    department: 'Science',
    enrolledCount: 136,
    checkedInCount: 0,
    lateCount: 0,
    absentCount: 136,
    submittedAt: null,
    syncState: 'missing',
  },
  {
    id: 'log-06',
    sessionDate: '2026-11-16',
    courseCode: 'BIO-301',
    lectureTitle: 'AP Biology — Main Auditorium',
    teacherName: 'Dr. Elena Vance',
    department: 'Science',
    enrolledCount: 300,
    checkedInCount: 289,
    lateCount: 7,
    absentCount: 11,
    submittedAt: '2026-11-16T10:15:48Z',
    syncState: 'synced',
  },
];

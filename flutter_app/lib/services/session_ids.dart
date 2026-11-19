import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

String localSessionDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String deterministicSessionId(String lectureId, String sessionDate) =>
    _uuid.v5(Namespace.url.value, 'lectureguard:session:$lectureId:$sessionDate');

String deterministicAttendanceRecordId(String sessionId, String studentId) =>
    _uuid.v5(Namespace.url.value, 'lectureguard:record:$sessionId:$studentId');

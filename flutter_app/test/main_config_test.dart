import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/main.dart';

void main() {
  const key = 'publishable-key';

  test('missing values are reported before Supabase.initialize runs', () {
    expect(validateSupabaseConfiguration(url: '', anonKey: key), isNotNull);
    expect(
      validateSupabaseConfiguration(url: 'https://project.supabase.co', anonKey: ''),
      isNotNull,
    );
  });

  test('only an absolute https project URL is accepted', () {
    expect(
      validateSupabaseConfiguration(
        url: 'https://project.supabase.co',
        anonKey: key,
      ),
      isNull,
    );

    for (final url in [
      'http://project.supabase.co',
      'project.supabase.co',
      'ftp://project.supabase.co',
      'https://',
      'not a url',
    ]) {
      final problem = validateSupabaseConfiguration(url: url, anonKey: key);
      expect(problem, isNotNull, reason: '$url must be rejected');
      expect(problem, contains('https'));
    }
  });
}

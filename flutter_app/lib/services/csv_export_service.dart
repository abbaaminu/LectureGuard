import 'package:csv/csv.dart';

String escapeCsvFormulaValue(Object? value) {
  final text = value?.toString() ?? '';
  if (text.startsWith(RegExp(r'[=+\-@]'))) {
    return "'$text";
  }
  return text;
}

String encodeCsvRows(List<List<Object?>> rows) {
  return const ListToCsvConverter().convert(
    rows.map((row) => row.map(escapeCsvFormulaValue).toList()).toList(),
  );
}

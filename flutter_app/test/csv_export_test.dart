import 'package:flutter_test/flutter_test.dart';
import 'package:lecture_guard/services/csv_export_service.dart';

void main() {
  test('CSV cells that can trigger spreadsheet formulas are escaped', () {
    expect(escapeCsvFormulaValue('=SUM(A1:A2)'), "'=SUM(A1:A2)");
    expect(escapeCsvFormulaValue('+cmd'), "'+cmd");
    expect(escapeCsvFormulaValue('-1+1'), "'-1+1");
    expect(escapeCsvFormulaValue('@HYPERLINK'), "'@HYPERLINK");
    expect(escapeCsvFormulaValue('Amina, Bello'), 'Amina, Bello');

    final csv = encodeCsvRows([
      ['Name', 'Value'],
      ['Amina, Bello', '=1+1'],
    ]);
    expect(csv, contains('"Amina, Bello"'));
    expect(csv, contains(",'=1+1"));
  });
}

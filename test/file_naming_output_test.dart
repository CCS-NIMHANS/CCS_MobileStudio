import 'dart:io';

import 'package:ccs_mobile_studio/core/models/module_type.dart';
import 'package:ccs_mobile_studio/core/services/file_naming_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports session files below the configured output folder', () async {
    final temp = await Directory.systemTemp.createTemp('ccs-output-test-');
    addTearDown(() async {
      FileNamingService.configureOutputDirectory(null);
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final output = Directory('${temp.path}/chosen-output');
    FileNamingService.configureOutputDirectory(output.path);
    final source = File('${temp.path}/S007_ANGEL_20260813_120000.csv');
    await source.writeAsString('trial,response\n1,correct\n');

    final exported = await FileNamingService.exportToDownloads(source.path);

    expect(
      exported,
      '${output.path}/S007/S007_ANGEL_20260813_120000/'
      'S007_ANGEL_20260813_120000.csv',
    );
    expect(await File(exported!).readAsString(), await source.readAsString());
  });

  test(
    'configured output directory stays free of staging recordings/data subfolders',
    () async {
      final temp = await Directory.systemTemp.createTemp('ccs-no-dup-test-');
      addTearDown(() async {
        FileNamingService.configureOutputDirectory(null);
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      final output = Directory('${temp.path}/chosen-output');
      FileNamingService.configureOutputDirectory(output.path);

      final edf = await FileNamingService.edfPath(
        'S008',
        ModuleType.standalone,
        DateTime(2026, 11, 26, 20, 0, 0),
      );
      final csv = await FileNamingService.markerCsvPath(
        'S008',
        ModuleType.standalone,
        DateTime(2026, 11, 26, 20, 0, 0),
      );

      expect(await Directory('${output.path}/recordings').exists(), isFalse);
      expect(await Directory('${output.path}/data').exists(), isFalse);
      expect(edf.startsWith(output.path), isFalse);
      expect(csv.startsWith(output.path), isFalse);
    },
  );
}

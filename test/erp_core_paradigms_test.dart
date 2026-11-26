import 'dart:io';
import 'dart:math' as math;

import 'package:ccs_mobile_studio/modules/generic_erp/erp_core_paradigms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all 6 ERP CORE paradigms are defined with standardized timing', () {
    expect(kErpCoreParadigms.length, 6);
    expect(
      kErpCoreParadigms.map((p) => p.id).toSet(),
      ErpCoreParadigmId.values.toSet(),
    );
  });

  test('ERP CORE trial plans respect ratios and constraints', () {
    final n170 = buildErpCoreTrialPlan(
      ErpCoreParadigmId.n170,
      40,
      rng: math.Random(1),
    );
    expect(n170.length, 40);
    expect(n170.where((t) => t.markerCode == 101).length, 10);

    final mmn = buildErpCoreTrialPlan(
      ErpCoreParadigmId.mmn,
      100,
      rng: math.Random(2),
    );
    expect(mmn.where((t) => t.isDeviantTone).length, 20);
    for (var i = 1; i < mmn.length; i++) {
      expect(mmn[i].isDeviantTone && mmn[i - 1].isDeviantTone, isFalse);
    }

    final n2pc = buildErpCoreTrialPlan(ErpCoreParadigmId.n2pc, 40);
    expect(n2pc.where((t) => t.targetOnLeft).length, 20);

    final n400 = buildErpCoreTrialPlan(ErpCoreParadigmId.n400, 40);
    expect(n400.where((t) => t.markerCode == 401).length, 20);
    expect(n400.every((t) => t.primeWord.isNotEmpty && t.targetWord.isNotEmpty), isTrue);

    final p3b = buildErpCoreTrialPlan(ErpCoreParadigmId.p3b, 50);
    expect(p3b.where((t) => t.markerCode == 501).length, 10);

    final flankers = buildErpCoreTrialPlan(ErpCoreParadigmId.flankers, 40);
    expect(flankers.where((t) => t.markerCode == 603).length, 10);
  });

  test('MMN generates valid RIFF WAVE files', () async {
    final files = await ensureMmnToneFiles();
    final stdBytes = await File(files.standardPath).readAsBytes();
    final devBytes = await File(files.deviantPath).readAsBytes();
    expect(stdBytes.length, greaterThan(44));
    expect(devBytes.length, stdBytes.length);
    expect(String.fromCharCodes(stdBytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(stdBytes.sublist(8, 12)), 'WAVE');
  });
}

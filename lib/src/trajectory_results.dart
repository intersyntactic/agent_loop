/// The feed of [ReturnedResult]s a [TrajectoryCrux] waits on: every
/// [resultOfActionOrWhyRefusedKind] entry loop_launcher's own feed hands
/// this loop, decoded once.
///
/// Built with [Stream.expand] rather than `async*`, for the same reason as
/// [followTrajectory]: `expand` passes a cancel straight through to
/// [LogbookReader.subscribe], which an `async*` wrapper would not.
library;

import 'dart:convert' show jsonDecode, utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show readResultOfActionOrWhyRefused, resultOfActionOrWhyRefusedKind;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader;

import 'trajectory_crux.dart';

final _resultKind = Kind.parse(resultOfActionOrWhyRefusedKind)!;

/// Every [resultOfActionOrWhyRefusedKind] entry [reader] is fed, decoded
/// through [readResultOfActionOrWhyRefused]; an entry whose body is not
/// JSON, or does not decode as one, is skipped rather than thrown, since
/// the airlock writes nothing else under this kind.
Stream<ReturnedResult> followResults(LogbookReader reader) =>
    reader.subscribe(kinds: {_resultKind}).expand((item) {
      if (item is! Entry) return const [];
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(item.body));
      } on FormatException {
        return const [];
      }
      final decoded = readResultOfActionOrWhyRefused(json);
      return decoded == null ? const [] : [decoded];
    });

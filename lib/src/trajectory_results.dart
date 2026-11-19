/// The feed of [ReturnedResult]s a [TrajectoryCrux] waits on: every
/// [outcomeOfProposedActionKind] entry loop_launcher's own feed hands
/// this loop, decoded once.
///
/// Built with [Stream.expand] rather than `async*`, for the same reason as
/// [followTrajectory]: `expand` passes a cancel straight through to
/// [LogbookReader.subscribe], which an `async*` wrapper would not.
library;

import 'dart:convert' show utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show outcomeOfProposedActionKind, readOutcomeOfProposedAction;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'trajectory_crux.dart';

final _resultKind = Kind.parse(outcomeOfProposedActionKind)!;

/// Every [outcomeOfProposedActionKind] entry [reader] is fed, decoded
/// through [readOutcomeOfProposedAction], with the entry's own id
/// alongside (a logbook [ObjectId], read back as the [EntryId] a later
/// proposal's `drawnFrom` names, the same hex round trip
/// [recordModelRequestOnTrajectory]'s callers use); an entry whose body is
/// not JSON, or does not decode as one, is skipped rather than thrown,
/// since the airlock writes nothing else under this kind.
Stream<ReturnedResult> followResults(LogbookReader reader) =>
    reader.subscribe(kinds: {_resultKind}).expand((item) {
      if (item is! Entry) return const [];
      final decoded = readOutcomeOfProposedAction(
        utf8.decode(item.body, allowMalformed: true),
      );
      return decoded == null
          ? const []
          : [
              (
                proposed: decoded.proposed,
                resultEntry: EntryId.parse(item.id.hex)!,
                result: decoded.result,
              ),
            ];
    });

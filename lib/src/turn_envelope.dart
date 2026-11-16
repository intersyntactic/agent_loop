/// What a turn's entry says, in the loop's own envelope: the node's shape
/// and fields, alongside where it came from. Provenance lives here, not on
/// the node, so every module that produces a node — `UserSaid` among them —
/// stays free of journal concepts.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;

/// Where a turn came from: the docking station's admission of an event
/// ([FromAdmission]), or the loop's own doing, with nothing admitted to
/// cause it ([Own]).
sealed class TurnProvenance {
  const TurnProvenance();

  Map<String, Object?> toJson();

  /// [json] as a provenance, as [toJson] wrote it. Throws a
  /// [FormatException] for anything else.
  static TurnProvenance fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'fromAdmission' => FromAdmission(
          EntryHash.parse(json['admitted']! as String)!,
        ),
        'own' => const Own(),
        final kind => throw FormatException('not a provenance: $kind'),
      };
}

/// This turn came from [admitted], the journal entry hash of the docking
/// station's `admitted` entry — not the `event` it names, one hop further
/// back, since the admission is what actually caused the loop to append
/// this turn.
final class FromAdmission extends TurnProvenance {
  const FromAdmission(this.admitted);

  final EntryHash admitted;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'fromAdmission',
    'admitted': admitted.hex,
  };
}

/// This turn is the loop's own doing: nothing admitted caused it, such as
/// the agent's own reply.
final class Own extends TurnProvenance {
  const Own();

  @override
  Map<String, Object?> toJson() => {'kind': 'own'};
}

/// One turn's entry bytes: [node]'s own shape and fields, alongside
/// [provenance].
final class TurnEnvelope {
  const TurnEnvelope({required this.node, required this.provenance});

  final Map<String, Object?> node;
  final TurnProvenance provenance;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(jsonEncode({'node': node, 'provenance': provenance.toJson()})),
  );

  /// [bytes] as an envelope, as [encode] wrote it: a journal entry
  /// frame's body, header stripped. Throws a [FormatException] for
  /// anything else.
  static TurnEnvelope decode(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json case {
      'node': final Map<String, Object?> node,
      'provenance': final Map<String, Object?> provenance,
    }) {
      return TurnEnvelope(
        node: node,
        provenance: TurnProvenance.fromJson(provenance),
      );
    }
    throw const FormatException('not a turn envelope');
  }
}

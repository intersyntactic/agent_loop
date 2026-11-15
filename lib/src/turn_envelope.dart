/// What a turn's entry says, in the loop's own envelope: the node's shape
/// and fields, alongside where it came from. Provenance lives here, not on
/// the node, so every module that produces a node — `UserSaid` among them —
/// stays free of journal concepts.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;

/// Where a turn came from: a witnessed arrival ([FromArrival]), or the
/// loop's own doing, with nothing that arrived to cause it ([Own]).
sealed class TurnProvenance {
  const TurnProvenance();

  Map<String, Object?> toJson();

  /// [json] as a provenance, as [toJson] wrote it. Throws a
  /// [FormatException] for anything else.
  static TurnProvenance fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'fromArrival' => FromArrival(
          EntryHash.parse(json['arrival']! as String)!,
        ),
        'own' => const Own(),
        final kind => throw FormatException('not a provenance: $kind'),
      };
}

/// This turn came from the witnessed arrival at [arrival], the journal
/// entry hash of a `witnessed` entry.
final class FromArrival extends TurnProvenance {
  const FromArrival(this.arrival);

  final EntryHash arrival;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'fromArrival',
    'arrival': arrival.hex,
  };
}

/// This turn is the loop's own doing: nothing arrived to cause it, such as
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
    if (json is! Map<String, Object?> ||
        json['node'] is! Map<String, Object?> ||
        json['provenance'] is! Map<String, Object?>) {
      throw const FormatException('not a turn envelope');
    }
    return TurnEnvelope(
      node: json['node']! as Map<String, Object?>,
      provenance: TurnProvenance.fromJson(
        json['provenance']! as Map<String, Object?>,
      ),
    );
  }
}

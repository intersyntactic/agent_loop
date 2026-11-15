/// What a `witnessed` entry's body says: `is_airlock`'s `Witness.witness`
/// format, `{"at", "source", "bytes"}`, the bytes base64 and exactly as
/// they came.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart' show ArrivalSource;

/// One witnessed arrival, decoded from its journal entry's body.
final class WitnessedArrival {
  const WitnessedArrival({
    required this.at,
    required this.source,
    required this.bytes,
  });

  /// When the airlock witnessed it.
  final DateTime at;

  /// Where it came from, such as `teams`.
  final ArrivalSource source;

  /// Exactly as it came.
  final Uint8List bytes;

  /// [body] as a witnessed arrival, as `Witness.witness` wrote it. Throws
  /// a [FormatException] for anything else.
  static WitnessedArrival decode(Uint8List body) {
    final json = jsonDecode(utf8.decode(body));
    if (json is! Map<String, Object?> ||
        json['at'] is! String ||
        json['source'] is! String ||
        json['bytes'] is! String) {
      throw const FormatException('not a witnessed arrival');
    }
    final source = ArrivalSource.parse(json['source']! as String);
    if (source == null) {
      throw FormatException('not a source: ${json['source']}');
    }
    return WitnessedArrival(
      at: DateTime.parse(json['at']! as String),
      source: source,
      bytes: base64Decode(json['bytes']! as String),
    );
  }
}

import 'package:freezed_annotation/freezed_annotation.dart';

part 'network_result.freezed.dart';

// Sealed union with three variants: success carries data, failure carries
// an error code + a defaulted message, loading is a terminal marker. Used
// to exercise freezed's union-type codegen: .when, .map, .maybeWhen,
// copyWith-per-variant, @Default, and equality.

/// A sealed result union over payload type `T`.
@freezed
sealed class NetworkResult<T> with _$NetworkResult<T> {
  /// A successful result carrying [data].
  const factory NetworkResult.success(T data) = NetworkSuccess<T>;

  /// A failed result with [code] and optional [message].
  const factory NetworkResult.failure({
    required int code,
    @Default('') String message,
  }) = NetworkFailure<T>;

  /// A request still in flight.
  const factory NetworkResult.loading() = NetworkLoading<T>;
}

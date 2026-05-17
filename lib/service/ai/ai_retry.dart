import 'dart:async';
import 'dart:io';

/// Default predicate for transient AI errors — network, timeout, rate limit.
/// Catches both typed exceptions and the substring fingerprints that the
/// langchain stack surfaces as plain `Exception(...)` from various providers.
bool isTransientAiError(Object error) {
  if (error is TimeoutException) return true;
  if (error is SocketException) return true;
  final s = error.toString().toLowerCase();
  return s.contains('429') ||
      s.contains('rate limit') ||
      s.contains('timeout') ||
      s.contains('network');
}

/// Retry [call] up to [maxAttempts] times with exponential backoff, retrying
/// only on transient errors per [isTransient]. Cancellation short-circuits the
/// loop without retrying.
///
/// The backoff is `baseDelay * 2^attempt`. Default base is 200ms — first retry
/// after 200ms, second after 400ms, third after 800ms (with default 3 attempts
/// the loop sleeps twice total before giving up).
///
/// Non-transient errors rethrow immediately so the caller can decide policy
/// (e.g. 4xx other than 429 should surface, not retry).
Future<T> retryOnTransient<T>(
  Future<T> Function() call, {
  int maxAttempts = 3,
  Duration baseDelay = const Duration(milliseconds: 200),
  bool Function(Object error)? isTransient,
  bool Function()? isCancelled,
  T Function()? onCancelled,
}) async {
  final transient = isTransient ?? isTransientAiError;
  Object? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (isCancelled?.call() ?? false) {
      if (onCancelled != null) return onCancelled();
      throw _RetryCancelled();
    }
    try {
      return await call();
    } catch (e) {
      if (!transient(e)) rethrow;
      lastError = e;
    }
    if (attempt < maxAttempts - 1) {
      final wait = Duration(
        milliseconds: baseDelay.inMilliseconds * (1 << attempt),
      );
      await Future.delayed(wait);
    }
  }
  throw lastError ?? StateError('retryOnTransient: no attempts ran');
}

class _RetryCancelled implements Exception {
  @override
  String toString() => 'retryOnTransient cancelled';
}

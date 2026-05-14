import 'package:ai_book_reader/service/ai/index.dart';
import 'package:langchain_core/chat_models.dart';

/// Drain [aiGenerateStream] and return the final accumulated buffer as one
/// string.
///
/// `aiGenerateStream` yields the running buffer after every chunk, so the last
/// yielded value already contains the complete response. This helper is the
/// `await` shape we want for non-streaming use cases (Stage B filter, Stage C
/// mining): one request -> one final JSON blob.
///
/// Caller controls cancellation via [cancelActiveAiRequest]. When the stream
/// is cancelled mid-flight the function returns whatever was accumulated so
/// far (could be an empty string), which the caller is expected to discard.
Future<String> aiGenerateOnce(
  List<ChatMessage> messages, {
  String? identifier,
  Map<String, String>? config,
}) async {
  String? last;
  await for (final chunk in aiGenerateStream(
    messages,
    identifier: identifier,
    config: config,
  )) {
    last = chunk;
  }
  return last ?? '';
}

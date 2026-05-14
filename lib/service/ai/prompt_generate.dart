import 'dart:io';

import 'package:ai_book_reader/config/shared_preference_provider.dart';
import 'package:ai_book_reader/enums/ai_prompts.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';

class PromptTemplatePayload {
  const PromptTemplatePayload({
    required this.template,
    required this.variables,
    required this.identifier,
  });

  final ChatPromptTemplate template;
  final Map<String, dynamic> variables;
  final AiPrompts identifier;

  List<ChatMessage> buildMessages() {
    try {
      return template.formatPrompt(variables).toChatMessages();
    } catch (e) {
      Prefs().deleteAiPrompt(identifier);
      final prompt = Prefs().getAiPrompt(identifier);
      final normalized = _normalizePrompt(prompt);
      final template = ChatPromptTemplate.fromPromptMessages([
        HumanChatMessagePromptTemplate.fromTemplate(normalized),
      ]);
      return template.formatPrompt(variables).toChatMessages();
    }
  }

  String buildString() {
    return buildMessages().last.contentAsString;
  }
}

PromptTemplatePayload generatePromptTest() {
  final prompt = Prefs().getAiPrompt(AiPrompts.test);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  final currentLocale = Prefs().locale?.languageCode ?? Platform.localeName;
  return PromptTemplatePayload(
    template: template,
    variables: {'language_locale': currentLocale},
    identifier: AiPrompts.test,
  );
}

PromptTemplatePayload generatePromptSummaryTheChapter() {
  final prompt = Prefs().getAiPrompt(AiPrompts.summaryTheChapter);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {},
    identifier: AiPrompts.summaryTheChapter,
  );
}

PromptTemplatePayload generatePromptSummaryTheBook() {
  final prompt = Prefs().getAiPrompt(AiPrompts.summaryTheBook);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {},
    identifier: AiPrompts.summaryTheBook,
  );
}

PromptTemplatePayload generatePromptMindmap() {
  final prompt = Prefs().getAiPrompt(AiPrompts.mindmap);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {},
    identifier: AiPrompts.mindmap,
  );
}

PromptTemplatePayload generatePromptSummaryThePreviousContent(
    String previousContent) {
  final prompt = Prefs().getAiPrompt(AiPrompts.summaryThePreviousContent);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {
      'previous_content': previousContent.trim(),
    },
    identifier: AiPrompts.summaryThePreviousContent,
  );
}

PromptTemplatePayload generatePromptTranslate(
    String text, String toLocale, String fromLocale,
    {String? contextText}) {
  final prompt = Prefs().getAiPrompt(AiPrompts.translate);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {
      'text': text.trim(),
      'to_locale': toLocale,
      'from_locale': fromLocale,
      'contextText': (contextText ?? '').trim(),
    },
    identifier: AiPrompts.translate,
  );
}

PromptTemplatePayload generatePromptFullTextTranslate(
    String text, String toLocale, String fromLocale) {
  final prompt = Prefs().getAiPrompt(AiPrompts.fullTextTranslate);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {
      'text': text.trim(),
      'to_locale': toLocale,
      'from_locale': fromLocale,
    },
    identifier: AiPrompts.fullTextTranslate,
  );
}

/// Builds the Stage B (LLM filter) prompt. [termsBlock] is one term per line
/// of the form: `INDEX. "TERM" freq=N ch=M — snippet "..."`.
PromptTemplatePayload generatePromptCandidateFilter(String termsBlock) {
  final prompt = Prefs().getAiPrompt(AiPrompts.candidateFilter);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {
      'terms_block': termsBlock,
    },
    identifier: AiPrompts.candidateFilter,
  );
}

/// Builds the Stage C (mining) prompt. The model receives the full source and
/// target chapter plus a newline-separated list of source terms; the response
/// is a JSON object {source -> lemma-form translation or null}.
PromptTemplatePayload generatePromptCandidateMining({
  required String sourceText,
  required String targetText,
  required String fromLocale,
  required String toLocale,
  required String termsList,
}) {
  final prompt = Prefs().getAiPrompt(AiPrompts.candidateMining);
  final normalized = _normalizePrompt(prompt);
  final template = ChatPromptTemplate.fromPromptMessages([
    HumanChatMessagePromptTemplate.fromTemplate(normalized),
  ]);
  return PromptTemplatePayload(
    template: template,
    variables: {
      'source_text': sourceText,
      'target_text': targetText,
      'from_locale': fromLocale,
      'to_locale': toLocale,
      'terms_list': termsList,
    },
    identifier: AiPrompts.candidateMining,
  );
}

String _normalizePrompt(String template) {
  return template.replaceAll('{{', '{').replaceAll('}}', '}');
}

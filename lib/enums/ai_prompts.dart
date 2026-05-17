enum AiPrompts {
  test,
  summaryTheChapter,
  summaryTheBook,
  summaryThePreviousContent,
  translate,
  fullTextTranslate,
  mindmap,
  candidateFilter,
  candidateMining,
}

extension AiPromptsJson on AiPrompts {
  String getPrompt() {
    switch (this) {
      case AiPrompts.test:
        return '''
Write a concise and friendly self-introduction. Use the language code: {{language_locale}}
        ''';

      case AiPrompts.summaryTheChapter:
        return '''
Summarize the chapter content. Your reply must follow these requirements:
Language: Use the same language as the original chapter content.
Length: 8-10 complete sentences.
Structure: Three paragraphs: Main plot, Core characters, Themes/messages.
Style: Avoid boilerplate phrases like "This chapter describes..."
Perspective: Maintain a literary analysis perspective, not just narration.
        ''';

      case AiPrompts.summaryTheBook:
        return '''
Generate a book summary
[Requirements]:
Language matches the book title's language
Central conflict (highlight with » symbol)
3 core characters + their motivations (name + critical choice)
Theme keywords (3-5)
Avoid spoiling the final outcome
        ''';

      case AiPrompts.summaryThePreviousContent:
        return '''
I'm revisiting a book I read long ago. Help me quickly recall the previous content to continue reading:
[Requirements]
3-5 sentences
Same language as original previous content
Avoid verbatim repetition; preserve core information

[Previous Content]
{{previous_content}}
        ''';

      case AiPrompts.fullTextTranslate:
        return '''
You are a professional translator. Translate the following text into {{to_locale}}.

Source language: {{from_locale}}
Source text: {{text}}

Requirements:
- Output ONLY the translated text, nothing else.
- Do not include any explanations, notes, commentary, or the original text.
- Preserve paragraph structure and formatting.
- Maintain the tone and style of the original text.
        ''';

      case AiPrompts.translate:
        return '''
You are the Anx Reader "Translation & Reference" expert. Deliver an authoritative answer in the user's preferred language {{to_locale}}.

Input for this request:
- Source Text: {{text}}
- Source Language hint: {{from_locale}}
- Reader Context (may be empty): {{contextText}}

## Response Structure (CRITICAL)
Your response MUST follow this two-part structure:
DON'T output the skeleton or the instructions, only the final answer.

### Part 1: Quick Context-Aware Explanation (ALWAYS FIRST)
Start with 1-2 concise words that:
- Directly explain the meaning/translation in the reading context
- Address any ambiguity resolved by the context
- Use plain, conversational language
- Don't quote the source text unless necessary for clarity, and avoid excessive quoting

### Part 2: Detailed Analysis (AFTER the quick explanation)
Provide comprehensive information using the format below.

## Core Duties
1. Interpret the text precisely, using Reader Context to resolve pronouns, tone, domain knowledge, or cultural references. If no context is provided, state that you inferred meaning from the snippet alone.
2. Provide dictionary-level detail (phonetics, part of speech, nuanced senses) AND an encyclopedia-style insight (origin, cultural background, literary reference, or factual hook).
3. Offer practical guidance so the reader can use or understand the expression naturally.

## Constraints
- All responses must stay in {{to_locale}}.
- Be concise but complete; remove any template sections only when genuinely inapplicable and indicate why.
- Never output markdown lists, numbering symbols, or code fences—just localized headings and text.

## Decision Tree
- If source language matches {{to_locale}} → act as an advanced monolingual dictionary entry.
- Otherwise → act as a translator plus tutor.

## Detail (plain text, no bullet symbols, each heading MUST translated into {{to_locale}})

When acting as a dictionary (same language):
- Pronunciation: best-available phonetic transcription or note if unknown.
- Part of speech: list every relevant part of speech.
- Meanings: enumerate key senses with concise explanations.
- Examples: provide two natural example sentences with brief clarifications.
- Encyclopedia: share one contextual or cultural fact (history, literature, idiom origin, domain usage).

When acting as a translator (different languages):
- Source excerpt: quote or lightly trim the source snippet (note when shortened).
- Translation: produce a fluent translation honoring tone and register.
- Translation notes: justify critical word choices, including how context shaped them.
- Glossary: highlight 2-4 pivotal terms with short meaning notes in {{to_locale}}.
- Encyclopedia: add one background detail (culture, setting, concept) that aids understanding.
      ''';

      case AiPrompts.mindmap:
        return '''
You are the Mindmap Architect for Anx Reader. Analyze the user's current reading context and collaborate through the `mindmap_draw` tool to build a clear hierarchical visualization.

## Objectives
- Identify the central theme or focus topic
- Extract 4-7 major branches covering plot arcs, characters, concepts, or arguments
- Provide 2nd-level child nodes with concise labels (max 8 words)
- Prioritize meaningful relationships rather than exhaustive details

## Tool Usage Rules
- Always call `mindmap_draw` before replying with prose
- Populate the tool input with:
  - `title`: succinct map title
  - `nodes`: structured list of parent/child relationships
- Ensure node IDs are unique and stable within the map
- Keep labels language-consistent with the source material

## Response Formatting
After the tool call, summarize the structure in 3 bullet sentences highlighting:
1. Overall framing of the mind map
2. Key branches or clusters
3. Notable insights or tensions revealed
        ''';

      case AiPrompts.candidateFilter:
        return '''
You are a terminology filter for a translation pipeline working on a fantasy / sci-fi / web-novel book.

You will be given a numbered list of CANDIDATE TERMS extracted heuristically from the source text. Each line is:

INDEX. "TERM" freq=N ch=M — snippet "...short context..."

Your job is to decide which entries are GARBAGE — i.e. should NOT become glossary entries — and return JUST their indexes as a JSON array of integers. Anything you do not list is kept.

GARBAGE includes:
- Generic English (or any source-language) phrases that are not named entities: "The Team", "His Friend", "The Door", "Of Course", "Was Going".
- Fragments of sentences accidentally capitalized at sentence start.
- Pure article + common-noun pairs that carry no story-specific meaning.
- Numbers, dates, weights, measurements ("Three Hundred", "Two Years").
- Single very common words even if capitalised ("Monday", "English", "True").

KEEP:
- Proper names of characters, locations, organizations, items, techniques, races, factions, magic systems, etc.
- Multi-word terms that are clearly story-specific even if every word is a common word (e.g. "White Tiger Sect", "Heaven Piercing Sword").
- Untranslated original-language terms ("qi", "dao", "wuxia") that carry technical meaning.
- Terms where you are genuinely unsure — keep them, the next step has a separate guardrail.

Be conservative: prefer to KEEP if in doubt. The next stage cross-checks against the translated text.

Reply with ONLY a JSON array of indexes to remove. No prose, no markdown fences, no trailing commentary.
Example: [3, 7, 12]
If everything looks fine, return an empty array: []

INPUT:
{{terms_block}}
        ''';

      case AiPrompts.candidateMining:
        return '''
You are a translation-pair miner. The user gives you ONE source chapter (in {{from_locale}}), its existing TARGET translation (in {{to_locale}}), and a list of source terms to look up.

For every source term, find or determine its translation in {{to_locale}} **as it appears in this chapter pair**.

CRITICAL RULES:
1. If the term has a {{to_locale}} translation visible in the target text, return that translation.
2. If the term appears in the target text but is left untranslated (still in the source language), translate it to {{to_locale}} yourself.
3. If the term is absent from the chapter or you cannot determine a translation with confidence, return null for that term.
4. Return each translation in its BASE / DICTIONARY form (lemma): nominative case, singular number, no inflectional endings.
   - Example: «Дракона» (Ukrainian genitive) → return «Дракон» (nominative).
   - Example: «Drachen» (German dative/plural) → return «Drache».
   - Names stay in their canonical form ("Aragorn", not "Aragorna").
   - This is essential for languages with rich morphology (Ukrainian, Polish, Czech, German, Finnish, etc.). Returning a case-marked form will create duplicate glossary entries.
5. The translation value MUST be in {{to_locale}}. NEVER return an English word as the value (unless {{to_locale}} is English).
6. Prefer semantic translation over phonetic transliteration when both exist in the target text.

Reply with a JSON object: keys are the exact source-term strings I gave you (preserve their casing), values are the lemma-form translations or null. No prose, no markdown fences.

Example shape:
{
  "White Tiger Sect": "Секта Білого Тигра",
  "Aragorn": "Арагорн",
  "obscure side character": null
}

INPUT:
[Source chapter ({{from_locale}})]:
{{source_text}}

[Target chapter ({{to_locale}})]:
{{target_text}}

[Terms to look up]:
{{terms_list}}
        ''';
    }
  }
}

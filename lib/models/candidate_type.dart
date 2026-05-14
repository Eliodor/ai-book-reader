/// Coarse semantic category guessed by the Stage A extractor for a term
/// candidate. The label is informational — Stage B (LLM filter) makes the real
/// term/garbage decision regardless of this value.
enum CandidateType {
  properName('proper_name'),
  title('title'),
  organization('organization'),
  technique('technique'),
  phrase('phrase'),
  unknown('unknown');

  const CandidateType(this.dbValue);

  final String dbValue;

  static CandidateType fromDb(String? raw) {
    if (raw == null) return CandidateType.phrase;
    for (final value in CandidateType.values) {
      if (value.dbValue == raw) return value;
    }
    return CandidateType.phrase;
  }
}

/// Lifecycle status of a term candidate produced by the discovery pipeline.
///
/// Transitions:
/// - `candidate`  -> after Stage A discovery writes the row.
/// - `accepted` / `rejected` / `uncertain` -> Stage B LLM filter verdict.
/// - `promoted`   -> Stage C mined a translation and wrote it to glossary.
enum CandidateStatus {
  candidate('candidate'),
  accepted('accepted'),
  rejected('rejected'),
  uncertain('uncertain'),
  promoted('promoted');

  const CandidateStatus(this.dbValue);

  final String dbValue;

  static CandidateStatus fromDb(String? raw) {
    if (raw == null) return CandidateStatus.candidate;
    for (final value in CandidateStatus.values) {
      if (value.dbValue == raw) return value;
    }
    return CandidateStatus.candidate;
  }
}

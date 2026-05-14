import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:snowball_stemmer/snowball_stemmer.dart';

/// Stage 4 — single-pass clustering of morphological variants.
///
/// Strategy:
/// 1. Build a signature for each candidate. For Snowball-supported languages
///    the signature is `(stem(token_1), stem(token_last))`. For everything
///    else we fall back to character-trigram Jaccard.
/// 2. Sort candidates by score descending (seed clusters with the strongest
///    terms — Salton's single-pass clustering principle).
/// 3. Walk the sorted list. For each candidate try to attach it to an existing
///    cluster (identical stem-tuple OR Jaccard ≥ threshold to representative).
///    If no match — create a new cluster.
/// 4. Recompute representative per cluster as the variant with the highest
///    raw frequency (most likely lemma / nominative form).
/// 5. Aggregate cluster frequency = Σ over members.
class MorphologyClusterer {
  MorphologyClusterer({required this.sourceLanguage});

  final String sourceLanguage;

  SnowballStemmer? _stemmer;

  void _ensureStemmer() {
    if (_stemmer != null) return;
    final algo = _algorithmFor(sourceLanguage);
    if (algo != null) {
      _stemmer = SnowballStemmer(algo);
    }
  }

  /// Run clustering and write the surviving candidates back into [candidates]
  /// (in-place: discarded members are removed).
  void cluster(Map<String, RawCandidate> candidates) {
    if (candidates.length < 2) return;
    _ensureStemmer();

    // 1. Pre-compute signatures.
    final signatures = <RawCandidate, _Signature>{};
    for (final c in candidates.values) {
      signatures[c] = _signatureFor(c);
    }

    // 2. Sort by score descending; ties broken by frequency descending.
    final ordered = candidates.values.toList()
      ..sort((a, b) {
        final cmp = b.score.compareTo(a.score);
        if (cmp != 0) return cmp;
        return b.frequencyTotal.compareTo(a.frequencyTotal);
      });

    final clusters = <_Cluster>[];

    for (final cand in ordered) {
      final sig = signatures[cand]!;
      _Cluster? target;
      for (final cluster in clusters) {
        if (_matches(sig, cluster.representativeSignature)) {
          target = cluster;
          break;
        }
      }
      if (target != null) {
        target.members.add(cand);
      } else {
        clusters.add(_Cluster(
          members: [cand],
          representativeSignature: sig,
        ));
      }
    }

    // 3. Recompute representative per cluster = highest raw frequency.
    final survivors = <String, RawCandidate>{};
    for (final cluster in clusters) {
      if (cluster.members.length == 1) {
        final solo = cluster.members.first;
        survivors[solo.normalizedSource] = solo;
        continue;
      }
      cluster.members.sort(
        (a, b) => b.frequencyTotal.compareTo(a.frequencyTotal),
      );
      final winner = cluster.members.first;
      // Merge stats from the other members into the winner.
      var totalScore = winner.score;
      for (var i = 1; i < cluster.members.length; i++) {
        final m = cluster.members[i];
        winner.frequencyTotal += m.frequencyTotal;
        winner.chapterIds.addAll(m.chapterIds);
        winner.allCapsOccurrences += m.allCapsOccurrences;
        winner.uniqueSentences.addAll(m.uniqueSentences);
        // Keep up to maxOccurrencesPerCandidate occurrences.
        for (final occ in m.occurrences) {
          if (winner.occurrences.length >= maxOccurrencesPerCandidate) break;
          winner.occurrences.add(occ);
        }
        totalScore += m.score;
      }
      // The winning representative's score becomes the max of cluster scores
      // — not the sum — to avoid pathological inflation.
      winner.score = totalScore / cluster.members.length;
      survivors[winner.normalizedSource] = winner;
    }

    candidates.clear();
    candidates.addAll(survivors);
  }

  _Signature _signatureFor(RawCandidate cand) {
    final words = cand.normalizedSource.split(' ');
    if (_stemmer != null && words.isNotEmpty) {
      final first = _stemmer!.stem(words.first);
      final last = words.length == 1 ? first : _stemmer!.stem(words.last);
      return _Signature(stemFirst: first, stemLast: last, trigrams: null);
    }
    return _Signature(
      stemFirst: '',
      stemLast: '',
      trigrams: _trigrams(cand.normalizedSource),
    );
  }

  bool _matches(_Signature a, _Signature b) {
    if (a.trigrams == null && b.trigrams == null) {
      return a.stemFirst == b.stemFirst && a.stemLast == b.stemLast;
    }
    final left = a.trigrams ?? _trigrams(a.stemFirst);
    final right = b.trigrams ?? _trigrams(b.stemFirst);
    return _jaccard(left, right) >= clusterJaccardThreshold;
  }

  static Set<String> _trigrams(String s) {
    if (s.length <= 3) return {s};
    final padded = '^$s\$';
    final result = <String>{};
    for (var i = 0; i + 3 <= padded.length; i++) {
      result.add(padded.substring(i, i + 3));
    }
    return result;
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final inter = a.intersection(b).length;
    final union = a.length + b.length - inter;
    return union == 0 ? 0 : inter / union;
  }

  /// Map ISO 639-1 codes to Snowball [Algorithm]s. Languages not present in
  /// Snowball fall back to the char-trigram path.
  static Algorithm? _algorithmFor(String lang) {
    switch (lang) {
      case 'en':
        return Algorithm.english;
      case 'ru':
        return Algorithm.russian;
      case 'de':
        return Algorithm.german;
      case 'fr':
        return Algorithm.french;
      case 'es':
        return Algorithm.spanish;
      case 'it':
        return Algorithm.italian;
      case 'pt':
        return Algorithm.portuguese;
      case 'nl':
        return Algorithm.dutch;
      case 'fi':
        return Algorithm.finnish;
      case 'hu':
        return Algorithm.hungarian;
      case 'ro':
        return Algorithm.romanian;
      case 'tr':
        return Algorithm.turkish;
      case 'no':
      case 'nb':
      case 'nn':
        return Algorithm.norwegian;
      case 'sv':
        return Algorithm.swedish;
      case 'da':
        return Algorithm.danish;
      case 'ar':
        return Algorithm.arabic;
      // uk, pl, cs, bg, etc. — not in Snowball as of 0.1.0; trigram fallback.
      default:
        return null;
    }
  }
}

class _Signature {
  _Signature({
    required this.stemFirst,
    required this.stemLast,
    required this.trigrams,
  });
  final String stemFirst;
  final String stemLast;
  final Set<String>? trigrams;
}

class _Cluster {
  _Cluster({required this.members, required this.representativeSignature});
  final List<RawCandidate> members;
  final _Signature representativeSignature;
}

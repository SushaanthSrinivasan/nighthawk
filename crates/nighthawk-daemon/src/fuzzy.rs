//! Fuzzy string matching via Damerau-Levenshtein distance.
//!
//! Used as a fallback when prefix matching finds nothing in the spec tier.
//! All functions are case-sensitive — critical for flag matching where
//! `-R` and `-r` are distinct.

use std::collections::HashMap;

/// Compute the Damerau-Levenshtein distance between two strings.
///
/// Counts insertions, deletions, substitutions, and transpositions of
/// adjacent characters. Uses the full DL algorithm (not the restricted
/// "optimal string alignment" variant).
///
/// `max_dist` enables early termination: if every value in a row exceeds
/// `max_dist`, returns `max_dist + 1` immediately.
pub fn damerau_levenshtein(a: &str, b: &str, max_dist: usize) -> usize {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let len_a = a_chars.len();
    let len_b = b_chars.len();

    // Quick length-difference check
    if len_a.abs_diff(len_b) > max_dist {
        return max_dist + 1;
    }

    if len_a == 0 {
        return len_b;
    }
    if len_b == 0 {
        return len_a;
    }

    // Full Damerau-Levenshtein with the "last row where char was seen" trick.
    // Matrix is (len_a + 2) x (len_b + 2) to accommodate the sentinel row/col.
    let max_val = len_a + len_b;
    let rows = len_a + 2;
    let cols = len_b + 2;
    let mut d = vec![0usize; rows * cols];

    // Macro for 2D indexing
    macro_rules! at {
        ($r:expr, $c:expr) => {
            d[($r) * cols + ($c)]
        };
    }

    // Sentinel values
    at!(0, 0) = max_val;
    for i in 0..=len_a {
        at!(i + 1, 0) = max_val;
        at!(i + 1, 1) = i;
    }
    for j in 0..=len_b {
        at!(0, j + 1) = max_val;
        at!(1, j + 1) = j;
    }

    // Last row in which each character was seen
    let mut last_row: HashMap<char, usize> = HashMap::with_capacity(16);

    for i in 1..=len_a {
        let ch_a = a_chars[i - 1];
        let mut last_match_col: usize = 0;
        let mut row_min = usize::MAX;

        for j in 1..=len_b {
            let ch_b = b_chars[j - 1];
            let i1 = *last_row.get(&ch_b).unwrap_or(&0);
            let j1 = last_match_col;

            let cost = if ch_a == ch_b {
                last_match_col = j;
                0
            } else {
                1
            };

            let val = *[
                at!(i, j) + cost,  // substitution
                at!(i + 1, j) + 1, // deletion
                at!(i, j + 1) + 1, // insertion
                // transposition
                at!(i1, j1) + (i - i1 - 1) + 1 + (j - j1 - 1),
            ]
            .iter()
            .min()
            .unwrap();

            at!(i + 1, j + 1) = val;

            if val < row_min {
                row_min = val;
            }
        }

        last_row.insert(ch_a, i);

        // Early termination: proven correct for OSA (restricted DL). Full DL
        // differs from OSA only at distance >= 3, and max_distance_for_length()
        // caps at 2, so this is sound for our use case.
        if row_min > max_dist {
            return max_dist + 1;
        }
    }

    at!(len_a + 1, len_b + 1)
}

/// Maximum edit distance allowed for a given token length.
///
/// Returns `None` if the token is too short for meaningful fuzzy matching.
/// - len 1-2: `None` (too short — "ls" would match "rm")
/// - len 3-4: `Some(1)`
/// - len 5+: `Some(2)`
pub fn max_distance_for_length(len: usize) -> Option<usize> {
    match len {
        0..=2 => None,
        3..=4 => Some(1),
        _ => Some(2),
    }
}

/// A fuzzy match result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FuzzyMatch {
    pub text: String,
    pub distance: usize,
}

/// Find candidates within the allowed edit distance of `query`.
///
/// - Exact matches (distance 0) are excluded (handled by prefix matching).
/// - Results sorted by distance ascending, then alphabetically.
/// - Case-sensitive.
pub fn fuzzy_matches<'a>(
    query: &str,
    candidates: impl Iterator<Item = &'a str>,
) -> Vec<FuzzyMatch> {
    let max_dist = match max_distance_for_length(query.len()) {
        Some(d) => d,
        None => return vec![],
    };

    let mut results: Vec<FuzzyMatch> = candidates
        .filter_map(|candidate| {
            let dist = damerau_levenshtein(query, candidate, max_dist);
            if dist > 0 && dist <= max_dist {
                Some(FuzzyMatch {
                    text: candidate.to_string(),
                    distance: dist,
                })
            } else {
                None
            }
        })
        .collect();

    results.sort_by(|a, b| a.distance.cmp(&b.distance).then(a.text.cmp(&b.text)));
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- damerau_levenshtein tests ---

    #[test]
    fn dl_identical() {
        assert_eq!(damerau_levenshtein("checkout", "checkout", 2), 0);
    }

    #[test]
    fn dl_transposition() {
        assert_eq!(damerau_levenshtein("teh", "the", 2), 1);
        assert_eq!(damerau_levenshtein("stahs", "stash", 2), 1);
    }

    #[test]
    fn dl_deletion() {
        assert_eq!(damerau_levenshtein("chekout", "checkout", 2), 1);
    }

    #[test]
    fn dl_insertion() {
        assert_eq!(damerau_levenshtein("checckout", "checkout", 2), 1);
    }

    #[test]
    fn dl_substitution() {
        assert_eq!(damerau_levenshtein("chackout", "checkout", 2), 1);
    }

    #[test]
    fn dl_case_sensitive() {
        // -R and -r differ by one substitution
        assert_eq!(damerau_levenshtein("R", "r", 2), 1);
        assert_eq!(damerau_levenshtein("--Verbose", "--verbose", 2), 1);
    }

    #[test]
    fn dl_empty_strings() {
        assert_eq!(damerau_levenshtein("", "", 2), 0);
        assert_eq!(damerau_levenshtein("abc", "", 5), 3);
        assert_eq!(damerau_levenshtein("", "abc", 5), 3);
    }

    #[test]
    fn dl_distance_two() {
        assert_eq!(damerau_levenshtein("chckot", "checkout", 2), 2);
    }

    #[test]
    fn dl_early_termination() {
        // "abcdef" vs "zyxwvu" — very different, should bail early
        let dist = damerau_levenshtein("abcdef", "zyxwvu", 2);
        assert_eq!(dist, 3); // max_dist + 1
    }

    #[test]
    fn dl_length_difference_shortcut() {
        // Length differs by 4 but max_dist is 2 → immediate return
        assert_eq!(damerau_levenshtein("ab", "abcdef", 2), 3);
    }

    // --- max_distance_for_length tests ---

    #[test]
    fn max_dist_short_tokens() {
        assert_eq!(max_distance_for_length(0), None);
        assert_eq!(max_distance_for_length(1), None);
        assert_eq!(max_distance_for_length(2), None);
    }

    #[test]
    fn max_dist_medium_tokens() {
        assert_eq!(max_distance_for_length(3), Some(1));
        assert_eq!(max_distance_for_length(4), Some(1));
    }

    #[test]
    fn max_dist_long_tokens() {
        assert_eq!(max_distance_for_length(5), Some(2));
        assert_eq!(max_distance_for_length(10), Some(2));
        assert_eq!(max_distance_for_length(20), Some(2));
    }

    // --- fuzzy_matches tests ---

    #[test]
    fn fuzzy_basic_match() {
        let candidates = vec!["checkout", "cherry-pick", "clone"];
        let results = fuzzy_matches("chekout", candidates.into_iter());
        assert_eq!(
            results,
            vec![FuzzyMatch {
                text: "checkout".into(),
                distance: 1
            }]
        );
    }

    #[test]
    fn fuzzy_short_query_rejected() {
        let candidates = vec!["git", "go", "gp"];
        let results = fuzzy_matches("gi", candidates.into_iter());
        assert!(results.is_empty());
    }

    #[test]
    fn fuzzy_exact_match_excluded() {
        let candidates = vec!["checkout", "cherry-pick"];
        let results = fuzzy_matches("checkout", candidates.into_iter());
        assert!(results.is_empty());
    }

    #[test]
    fn fuzzy_sorted_by_distance_then_alpha() {
        // "stash" at dist 1 (transposition "stahs"), "status" at dist 2
        let candidates = vec!["status", "stash", "stage"];
        let results = fuzzy_matches("stahs", candidates.into_iter());
        // "stash" at distance 1 should come first
        assert_eq!(results[0].text, "stash");
        assert_eq!(results[0].distance, 1);
    }

    #[test]
    fn fuzzy_respects_max_distance_for_length() {
        // 3-char query allows only distance 1
        let candidates = vec!["add", "adb"];
        let results = fuzzy_matches("adc", candidates.into_iter());
        // "add" is distance 1 — included
        // "adb" is distance 1 — included
        assert_eq!(results.len(), 2);

        // But distance 2 should be excluded for a 3-char token
        let candidates2 = vec!["xyz"];
        let results2 = fuzzy_matches("abc", candidates2.into_iter());
        assert!(results2.is_empty());
    }

    #[test]
    fn fuzzy_case_sensitive_flags() {
        // "-R" (len 2) → rejected by length check, not by case
        let results = fuzzy_matches("-R", vec!["-r"].into_iter());
        assert!(results.is_empty()); // len 2 → no fuzzy

        // "--Recursive" vs "--recursive" — distance 1
        let results2 = fuzzy_matches("--Recursive", vec!["--recursive"].into_iter());
        assert_eq!(results2.len(), 1);
        assert_eq!(results2[0].distance, 1);
    }

    #[test]
    fn dl_max_dist_zero_boundary() {
        // max_dist=0 means only exact matches are "within budget"
        assert_eq!(damerau_levenshtein("abc", "abd", 0), 1);
        assert_eq!(damerau_levenshtein("abc", "abc", 0), 0);
    }

    #[test]
    fn dl_unicode_safety() {
        // Multi-byte UTF-8 chars must not panic; distance = 1 (substitution é→e)
        assert_eq!(damerau_levenshtein("café", "cafe", 2), 1);
        assert_eq!(damerau_levenshtein("naïve", "naive", 2), 1);
    }

    #[test]
    fn fuzzy_long_option_typo() {
        let candidates = vec!["--verbose", "--version", "--verify"];
        let results = fuzzy_matches("--vrebose", candidates.into_iter());
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text, "--verbose");
        assert_eq!(results[0].distance, 1); // transposition of 'r' and 'e'
    }
}

//! Fuzzy string matching via Damerau-Levenshtein distance.
//!
//! Used as a fallback when prefix matching finds nothing in the spec tier.
//! All functions are case-sensitive — critical for flag matching where
//! `-R` and `-r` are distinct.

use nighthawk_proto::DiffOp;
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

/// Compute character-level diff operations between `typed` and `corrected`.
///
/// Uses the full Damerau-Levenshtein matrix (no early termination) and
/// backtraces to produce a sequence of Keep/Delete/Insert ops.
/// Substitution decomposes into Delete(old) + Insert(new).
/// Transposition decomposes into Delete+Delete+Insert+Insert.
///
/// The resulting ops, when applied to `typed`, produce `corrected`.
pub fn diff_ops(typed: &str, corrected: &str) -> Vec<DiffOp> {
    let a: Vec<char> = typed.chars().collect();
    let b: Vec<char> = corrected.chars().collect();
    let len_a = a.len();
    let len_b = b.len();

    if len_a == 0 {
        return b.iter().map(|&ch| DiffOp::Insert(ch)).collect();
    }
    if len_b == 0 {
        return a.iter().map(|&ch| DiffOp::Delete(ch)).collect();
    }

    // Build the full DL matrix (same structure as damerau_levenshtein but
    // without early termination — we need the complete matrix for backtrace).
    let max_val = len_a + len_b;
    let rows = len_a + 2;
    let cols = len_b + 2;
    let mut d = vec![0usize; rows * cols];

    macro_rules! at {
        ($r:expr, $c:expr) => {
            d[($r) * cols + ($c)]
        };
    }

    at!(0, 0) = max_val;
    for i in 0..=len_a {
        at!(i + 1, 0) = max_val;
        at!(i + 1, 1) = i;
    }
    for j in 0..=len_b {
        at!(0, j + 1) = max_val;
        at!(1, j + 1) = j;
    }

    let mut last_row: HashMap<char, usize> = HashMap::with_capacity(16);

    // We also need to record the transposition source (i1, j1) for each cell
    // so the backtrace can detect transposition moves.
    let mut trans_source = vec![(0usize, 0usize); rows * cols];

    for i in 1..=len_a {
        let ch_a = a[i - 1];
        let mut last_match_col: usize = 0;

        for j in 1..=len_b {
            let ch_b = b[j - 1];
            let i1 = *last_row.get(&ch_b).unwrap_or(&0);
            let j1 = last_match_col;

            let cost = if ch_a == ch_b {
                last_match_col = j;
                0
            } else {
                1
            };

            let sub = at!(i, j) + cost;
            let del = at!(i + 1, j) + 1;
            let ins = at!(i, j + 1) + 1;
            let trans = at!(i1, j1) + (i - i1 - 1) + 1 + (j - j1 - 1);

            let val = sub.min(del).min(ins).min(trans);
            at!(i + 1, j + 1) = val;
            trans_source[(i + 1) * cols + (j + 1)] = (i1, j1);
        }

        last_row.insert(ch_a, i);
    }

    // Backtrace from d[len_a+1][len_b+1] to d[1][1]
    let mut ops = Vec::new();
    let mut i = len_a;
    let mut j = len_b;

    while i > 0 || j > 0 {
        if i > 0 && j > 0 {
            let (i1, j1) = trans_source[(i + 1) * cols + (j + 1)];
            let trans_cost = at!(i1, j1) + (i - i1 - 1) + 1 + (j - j1 - 1);

            if at!(i + 1, j + 1) == trans_cost && i1 > 0 && j1 > 0 {
                // Transposition path: characters between i1..i and j1..j
                // were involved in a transposition. Delete typed chars, insert corrected.
                // The chars from i1+1..=i in `a` get deleted (reverse order for backtrace)
                // The chars from j1+1..=j in `b` get inserted (reverse order for backtrace)
                let mut del_chars: Vec<char> = (i1..i).map(|idx| a[idx]).collect();
                let mut ins_chars: Vec<char> = (j1..j).map(|idx| b[idx]).collect();
                del_chars.reverse();
                ins_chars.reverse();
                for ch in ins_chars {
                    ops.push(DiffOp::Insert(ch));
                }
                for ch in del_chars {
                    ops.push(DiffOp::Delete(ch));
                }
                i = i1;
                j = j1;
                continue;
            }
        }

        if i > 0 && j > 0 && a[i - 1] == b[j - 1] && at!(i + 1, j + 1) == at!(i, j) {
            // Keep: diagonal move, same character
            ops.push(DiffOp::Keep(a[i - 1]));
            i -= 1;
            j -= 1;
        } else if i > 0 && j > 0 && at!(i + 1, j + 1) == at!(i, j) + 1 {
            // Substitution: diagonal move with cost 1 → Delete old + Insert new
            ops.push(DiffOp::Insert(b[j - 1]));
            ops.push(DiffOp::Delete(a[i - 1]));
            i -= 1;
            j -= 1;
        } else if i > 0 && at!(i + 1, j + 1) == at!(i, j + 1) + 1 {
            // Deletion: move up
            ops.push(DiffOp::Delete(a[i - 1]));
            i -= 1;
        } else if j > 0 && at!(i + 1, j + 1) == at!(i + 1, j) + 1 {
            // Insertion: move left
            ops.push(DiffOp::Insert(b[j - 1]));
            j -= 1;
        } else {
            // Shouldn't happen with a correct matrix, but guard against infinite loop
            break;
        }
    }

    ops.reverse();
    ops
}

/// Apply diff ops to verify correctness: applying ops to `typed` should yield `corrected`.
#[cfg(test)]
fn apply_ops(ops: &[DiffOp]) -> (String, String) {
    let mut source = String::new();
    let mut target = String::new();
    for op in ops {
        match op {
            DiffOp::Keep(ch) => {
                source.push(*ch);
                target.push(*ch);
            }
            DiffOp::Delete(ch) => {
                source.push(*ch);
            }
            DiffOp::Insert(ch) => {
                target.push(*ch);
            }
        }
    }
    (source, target)
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

    // --- diff_ops tests ---

    #[test]
    fn diff_ops_missing_char() {
        // "chekout" → "checkout" (missing 'c' after "che")
        let ops = diff_ops("chekout", "checkout");
        let (src, tgt) = apply_ops(&ops);
        assert_eq!(src, "chekout");
        assert_eq!(tgt, "checkout");
    }

    #[test]
    fn diff_ops_substitution() {
        // "chackout" → "checkout" (a→e substitution)
        let ops = diff_ops("chackout", "checkout");
        let (src, tgt) = apply_ops(&ops);
        assert_eq!(src, "chackout");
        assert_eq!(tgt, "checkout");
        // Should contain Delete('a') and Insert('e')
        assert!(ops.contains(&DiffOp::Delete('a')));
        assert!(ops.contains(&DiffOp::Insert('e')));
    }

    #[test]
    fn diff_ops_extra_char() {
        // "checckout" → "checkout" (extra 'c')
        let ops = diff_ops("checckout", "checkout");
        let (src, tgt) = apply_ops(&ops);
        assert_eq!(src, "checckout");
        assert_eq!(tgt, "checkout");
    }

    #[test]
    fn diff_ops_transposition() {
        // "chekcout" → "checkout" (k and c swapped)
        let ops = diff_ops("chekcout", "checkout");
        let (src, tgt) = apply_ops(&ops);
        assert_eq!(src, "chekcout");
        assert_eq!(tgt, "checkout");
    }

    #[test]
    fn diff_ops_long_option_transposition() {
        // "--vrebose" → "--verbose" (r and e swapped)
        let ops = diff_ops("--vrebose", "--verbose");
        let (src, tgt) = apply_ops(&ops);
        assert_eq!(src, "--vrebose");
        assert_eq!(tgt, "--verbose");
    }

    #[test]
    fn diff_ops_identical() {
        let ops = diff_ops("checkout", "checkout");
        assert!(ops.iter().all(|op| matches!(op, DiffOp::Keep(_))));
        assert_eq!(ops.len(), 8);
    }

    #[test]
    fn diff_ops_empty_typed() {
        let ops = diff_ops("", "abc");
        assert_eq!(
            ops,
            vec![
                DiffOp::Insert('a'),
                DiffOp::Insert('b'),
                DiffOp::Insert('c')
            ]
        );
    }

    #[test]
    fn diff_ops_empty_corrected() {
        let ops = diff_ops("abc", "");
        assert_eq!(
            ops,
            vec![
                DiffOp::Delete('a'),
                DiffOp::Delete('b'),
                DiffOp::Delete('c')
            ]
        );
    }
}

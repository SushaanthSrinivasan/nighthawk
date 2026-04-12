use flate2::read::GzDecoder;
use std::path::Path;
use tar::Archive;

/// Compressed tar archive of all spec JSON files, built by build.rs.
/// Empty if specs/ was not present at build time.
const SPECS_ARCHIVE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/specs.tar.gz"));

/// Version of the binary that produced this archive.
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Marker filename written to the specs directory after extraction.
const VERSION_FILE: &str = ".specs_version";

/// Result of attempting to extract embedded specs.
pub enum ExtractResult {
    /// Specs were extracted successfully.
    Extracted { count: usize },
    /// Specs directory already has the current version.
    AlreadyCurrent,
    /// No specs were embedded in this binary.
    NoEmbeddedSpecs,
}

/// Returns true if this binary has embedded specs.
pub fn has_embedded_specs() -> bool {
    !SPECS_ARCHIVE.is_empty()
}

/// Extract embedded specs to the given directory.
///
/// Skips extraction if the directory already contains specs from the same version.
/// Creates the directory if it doesn't exist.
pub fn extract_specs(dest: &Path) -> Result<ExtractResult, Box<dyn std::error::Error>> {
    if !has_embedded_specs() {
        return Ok(ExtractResult::NoEmbeddedSpecs);
    }

    // Check version marker — skip if already current
    let version_path = dest.join(VERSION_FILE);
    if version_path.exists() {
        let existing = std::fs::read_to_string(&version_path).unwrap_or_default();
        if existing.trim() == VERSION {
            return Ok(ExtractResult::AlreadyCurrent);
        }
    }

    std::fs::create_dir_all(dest)?;

    // Decompress and extract
    let decoder = GzDecoder::new(SPECS_ARCHIVE);
    let mut archive = Archive::new(decoder);
    let mut count = 0;

    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();

        // Only extract .json files (safety check)
        if path.extension().map(|e| e == "json").unwrap_or(false) {
            let filename = path
                .file_name()
                .ok_or_else(|| format!("Invalid entry path: {}", path.display()))?;
            let dest_path = dest.join(filename);
            let mut file = std::fs::File::create(&dest_path)?;
            std::io::copy(&mut entry, &mut file)?;
            count += 1;
        }
    }

    // Write version marker
    std::fs::write(&version_path, VERSION)?;

    Ok(ExtractResult::Extracted { count })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_specs_when_built_with_specs_dir() {
        // This test only passes when built from the repo with specs/ present
        if !has_embedded_specs() {
            eprintln!("Skipping: no embedded specs in this build");
            return;
        }
        assert!(SPECS_ARCHIVE.len() > 100);
    }

    #[test]
    fn extract_to_tempdir() {
        if !has_embedded_specs() {
            eprintln!("Skipping: no embedded specs in this build");
            return;
        }

        let dir = tempfile::tempdir().unwrap();
        let result = extract_specs(dir.path()).unwrap();

        match result {
            ExtractResult::Extracted { count } => {
                assert!(count > 100, "Expected 100+ specs, got {count}");

                // Verify version marker
                let version = std::fs::read_to_string(dir.path().join(VERSION_FILE)).unwrap();
                assert_eq!(version.trim(), VERSION);

                // Verify git.json exists and is valid JSON
                let git_spec = dir.path().join("git.json");
                assert!(git_spec.exists(), "git.json should exist");
                let contents = std::fs::read_to_string(&git_spec).unwrap();
                let parsed: serde_json::Value = serde_json::from_str(&contents).unwrap();
                assert_eq!(parsed["name"], "git");
            }
            other => panic!(
                "Expected Extracted, got {}",
                match other {
                    ExtractResult::AlreadyCurrent => "AlreadyCurrent",
                    ExtractResult::NoEmbeddedSpecs => "NoEmbeddedSpecs",
                    _ => "unknown",
                }
            ),
        }
    }

    #[test]
    fn extract_twice_returns_already_current() {
        if !has_embedded_specs() {
            eprintln!("Skipping: no embedded specs in this build");
            return;
        }

        let dir = tempfile::tempdir().unwrap();

        // First extraction
        let result = extract_specs(dir.path()).unwrap();
        assert!(matches!(result, ExtractResult::Extracted { .. }));

        // Second extraction — same version
        let result = extract_specs(dir.path()).unwrap();
        assert!(matches!(result, ExtractResult::AlreadyCurrent));
    }

    #[test]
    fn re_extracts_on_version_change() {
        if !has_embedded_specs() {
            eprintln!("Skipping: no embedded specs in this build");
            return;
        }

        let dir = tempfile::tempdir().unwrap();

        // First extraction
        extract_specs(dir.path()).unwrap();

        // Tamper with version marker
        std::fs::write(dir.path().join(VERSION_FILE), "0.0.0").unwrap();

        // Should re-extract
        let result = extract_specs(dir.path()).unwrap();
        assert!(matches!(result, ExtractResult::Extracted { .. }));

        // Version marker should be updated
        let version = std::fs::read_to_string(dir.path().join(VERSION_FILE)).unwrap();
        assert_eq!(version.trim(), VERSION);
    }
}

use flate2::write::GzEncoder;
use flate2::Compression;
use std::path::Path;

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let specs_dir = Path::new(&manifest_dir).join("specs");
    let archive_path = Path::new(&out_dir).join("specs.tar.gz");

    println!("cargo:rerun-if-changed=build.rs");

    // If specs/ doesn't exist, write an empty file so the build succeeds
    if !specs_dir.exists() {
        std::fs::write(&archive_path, b"").unwrap();
        println!("cargo:rerun-if-changed=specs");
        return;
    }

    // Collect and sort JSON files for reproducible builds
    let mut entries: Vec<_> = std::fs::read_dir(&specs_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .map(|ext| ext == "json")
                .unwrap_or(false)
        })
        .collect();
    entries.sort_by_key(|e| e.file_name());

    if entries.is_empty() {
        std::fs::write(&archive_path, b"").unwrap();
        println!("cargo:rerun-if-changed=specs");
        return;
    }

    // Build compressed tar archive
    let file = std::fs::File::create(&archive_path).unwrap();
    let encoder = GzEncoder::new(file, Compression::best());
    let mut archive = tar::Builder::new(encoder);

    for entry in &entries {
        let path = entry.path();
        let filename = entry.file_name();
        println!("cargo:rerun-if-changed={}", path.display());
        archive
            .append_path_with_name(&path, filename)
            .unwrap_or_else(|e| panic!("Failed to add {} to archive: {e}", path.display()));
    }

    archive.finish().unwrap();
}

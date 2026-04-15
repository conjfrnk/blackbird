#[test]
fn header_file_exists_and_has_symbols() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let header_path = std::path::Path::new(manifest_dir).join("include/BBCore.h");
    let header = std::fs::read_to_string(&header_path)
        .expect("BBCore.h missing — run `cargo build` to generate it");
    for sym in &[
        "bb_term_new",
        "bb_term_free",
        "bb_term_input",
        "bb_term_resize",
        "bb_term_take_snapshot",
        "bb_snap_retain",
        "bb_snap_release",
        "bb_term_set_event_cb",
        "BBEvent",
        "BBSnap",
        "BBCell",
        "BBEventKind",
    ] {
        assert!(header.contains(sym), "BBCore.h missing {sym}");
    }
}

// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#[test]
fn sbat_records_are_well_formed() {
    let rows = include_str!(concat!(env!("OUT_DIR"), "/sbat.csv"));
    assert!(rows.ends_with('\n'));
    for row in rows.lines() {
        assert_eq!(row.split(',').count(), 6);
        assert!(row.split(',').all(|field| !field.is_empty() && field.is_ascii()));
    }
    let selector_row = rows.lines().nth(1).unwrap();
    assert_eq!(selector_row.split(',').nth(4), Some(env!("CARGO_PKG_VERSION")));
}

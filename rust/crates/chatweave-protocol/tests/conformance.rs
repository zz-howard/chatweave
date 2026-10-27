mod support;

#[test]
fn every_registered_fixture_conforms_and_roundtrips() {
    let count = support::run(&support::repository()).expect("conformance fixtures");
    assert!(count >= 35, "the shared fixture suite must not be empty");
}

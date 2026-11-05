// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

use super::*;

#[test]
fn nvidia_grace_and_generic_profiles() {
    for (manufacturer, profile) in [
        ("NVIDIA", Profile::NvidiaGrace),
        ("nvidia", Profile::NvidiaGrace),
        ("Ampere Computing", Profile::Generic),
        ("Microsoft Corporation", Profile::Generic),
        ("Intel Corporation", Profile::Generic),
        ("NVIDIA Corporation", Profile::Generic),
    ] {
        assert_eq!(detect_profile(&[manufacturer]).unwrap(), profile, "manufacturer={manufacturer:?}");
    }
}

#[test]
fn matching_processor_profiles_are_accepted() {
    for (first, second, profile) in [
        ("NVIDIA", "NVIDIA", Profile::NvidiaGrace),
        ("NVIDIA", "nvidia", Profile::NvidiaGrace),
        ("Intel", "Ampere", Profile::Generic),
    ] {
        assert_eq!(detect_profile(&[first, second]).unwrap(), profile);
    }
}

#[test]
fn conflicting_processors_are_rejected() {
    assert_eq!(detect_profile(&["NVIDIA", "Ampere"]), Err(SmbiosDetectionError::InvalidProcessorInfo));
}

#[test]
fn missing_populated_processors_are_rejected() {
    assert_eq!(detect_profile(&[]), Err(SmbiosDetectionError::InvalidProcessorInfo));
}

#[test]
fn active_addon_comparison_preserves_firmware_errors() {
    let expected = b"verified template";
    assert!(active_addon_matches(Ok(Some(expected.to_vec())), expected).unwrap());
    assert!(!active_addon_matches(Ok(Some(b"different".to_vec())), expected).unwrap());
    assert!(!active_addon_matches(Ok(None), expected).unwrap());
    assert!(!active_addon_matches(Err(Status::NOT_FOUND.into()), expected).unwrap());
    for status in [Status::BAD_BUFFER_SIZE, Status::DEVICE_ERROR, Status::ACCESS_DENIED] {
        let error = active_addon_matches(Err(status.into()), expected).unwrap_err();
        assert_eq!(error.status(), status);
    }
}

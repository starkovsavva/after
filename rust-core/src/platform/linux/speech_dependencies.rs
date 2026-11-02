//! Reviewed Linux CPU wheel installation. Wheel hashes are checked before pip
//! parses them; local installed RECORD files are never a trust root.
use anyhow::{ensure, Result};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, ffi::OsStr, io::Write, path::Path, sync::OnceLock};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    target: String,
    python: String,
    packages: Vec<Wheel>,
}
#[derive(Deserialize)]
struct Wheel {
    name: String,
    version: String,
    filename: String,
    url: String,
    sha256: String,
    size: u64,
}
const POLICY: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../backend/python-wheels-linux-x86_64.json"
));
fn manifest() -> Result<&'static Manifest> {
    static VALUE: OnceLock<std::result::Result<Manifest, String>> = OnceLock::new();
    match VALUE.get_or_init(|| {
        let value: Manifest = serde_json::from_str(POLICY).map_err(|e| e.to_string())?;
        validate(&value).map_err(|e| e.to_string())?;
        Ok(value)
    }) {
        Ok(value) => Ok(value),
        Err(error) => anyhow::bail!("{error}"),
    }
}
fn validate(value: &Manifest) -> Result<()> {
    ensure!(
        value.schema_version == 1
            && value.target == "x86_64-unknown-linux-gnu"
            && value.python == "cp312",
        "Unsupported wheel profile"
    );
    ensure!(
        !value.packages.is_empty() && value.packages.len() <= 32,
        "Invalid wheel count"
    );
    let mut names = BTreeSet::new();
    let mut files = BTreeSet::new();
    for wheel in &value.packages {
        ensure!(
            !wheel.name.is_empty()
                && wheel
                    .name
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && names.insert(&wheel.name),
            "Invalid wheel name"
        );
        ensure!(
            !wheel.version.is_empty()
                && wheel
                    .version
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".+!_-".contains(&b)),
            "Invalid wheel version"
        );
        ensure!(
            wheel.filename.ends_with(".whl")
                && wheel
                    .filename
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".+_-".contains(&b))
                && files.insert(&wheel.filename),
            "Invalid wheel filename"
        );
        ensure!(
            wheel.url.starts_with("https://files.pythonhosted.org/")
                && wheel.url.ends_with(&wheel.filename),
            "Invalid wheel source"
        );
        ensure!(
            wheel.sha256.len() == 64
                && wheel.sha256.bytes().all(|b| b.is_ascii_hexdigit())
                && wheel.size > 0
                && wheel.size <= 128 * 1024 * 1024,
            "Invalid wheel integrity policy"
        );
    }
    for required in ["imageio-ffmpeg", "sherpa-onnx", "onnx-asr", "onnxruntime"] {
        ensure!(
            names.contains(&required.to_owned()),
            "Missing required CPU package"
        );
    }
    Ok(())
}
pub(super) fn prepare(
    directory: &Path,
    cache: Option<&Path>,
    run: &dyn Fn(&Path, &[&OsStr]) -> Result<()>,
) -> Result<()> {
    let policy = manifest()?;
    let wheelhouse = directory.join("wheelhouse");
    crate::platform_fs::create_private_directory(&wheelhouse)?;
    let lock = directory.join("cpu-requirements.txt");
    let mut requirements = crate::platform_fs::open_private(&lock, true)?;
    for wheel in &policy.packages {
        let source = cache.map(|root| root.join(&wheel.filename));
        crate::infrastructure::artifact_download::copy_verified(
            source.as_deref(),
            &wheel.url,
            &wheel.sha256,
            wheel.size,
            &wheelhouse.join(&wheel.filename),
        )?;
        writeln!(
            requirements,
            "{}=={} --hash=sha256:{}",
            wheel.name, wheel.version, wheel.sha256
        )?;
    }
    requirements.sync_all()?;
    let python = directory.join("venv/bin/python");
    run(
        &python,
        &[
            "-B".as_ref(),
            "-I".as_ref(),
            "-m".as_ref(),
            "ensurepip".as_ref(),
            "--upgrade".as_ref(),
        ],
    )?;
    run(
        &python,
        &[
            "-B".as_ref(),
            "-I".as_ref(),
            "-m".as_ref(),
            "pip".as_ref(),
            "--isolated".as_ref(),
            "install".as_ref(),
            "--no-index".as_ref(),
            "--no-deps".as_ref(),
            "--require-hashes".as_ref(),
            "--only-binary=:all:".as_ref(),
            "--no-compile".as_ref(),
            "--no-cache-dir".as_ref(),
            "--no-input".as_ref(),
            "--disable-pip-version-check".as_ref(),
            "--find-links".as_ref(),
            wheelhouse.as_os_str(),
            "--prefix".as_ref(),
            directory.join("venv").as_os_str(),
            "-r".as_ref(),
            lock.as_os_str(),
        ],
    )?;
    run(
        &python,
        &[
            "-B".as_ref(),
            "-I".as_ref(),
            "-m".as_ref(),
            "pip".as_ref(),
            "--isolated".as_ref(),
            "check".as_ref(),
        ],
    )?;
    let probe = directory.join("cpu-probe.py");
    let policy_path = directory.join("cpu-wheel-policy.json");
    let mut script = crate::platform_fs::open_private(&probe, true)?;
    script.write_all(include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../backend/probe_linux_cpu.py"
    )))?;
    script.sync_all()?;
    let mut metadata = crate::platform_fs::open_private(&policy_path, true)?;
    metadata.write_all(POLICY.as_bytes())?;
    metadata.sync_all()?;
    run(
        &python,
        &[
            "-B".as_ref(),
            "-I".as_ref(),
            probe.as_os_str(),
            policy_path.as_os_str(),
            directory.join("cpu-probe-result.json").as_os_str(),
        ],
    )?;
    let report = serde_json::json!({"schemaVersion":1,"profile":"linux-cpu","manifestSha256":format!("{:x}",Sha256::digest(POLICY.as_bytes())),"modelsInstalled":false});
    let mut output =
        crate::platform_fs::open_private(&directory.join("speech-profile.json"), true)?;
    serde_json::to_writer(&mut output, &report)?;
    output.sync_all()?;
    // Cached wheels are inputs, not installed execution paths or runtime authority.
    std::fs::remove_dir_all(wheelhouse)?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy_is_complete_and_rejects_unsafe_or_incomplete_artifacts() {
        assert_eq!(manifest().unwrap().packages.len(), 9);
        for change in 0..5 {
            let mut value: Manifest = serde_json::from_str(POLICY).unwrap();
            match change {
                0 => value.packages[0].filename = "../outside.whl".into(),
                1 => value.packages[0].url = "https://untrusted.invalid/wheel.whl".into(),
                2 => value.packages[0].sha256 = "bad".into(),
                3 => value.packages.clear(),
                _ => value.python = "cp313".into(),
            }
            assert!(validate(&value).is_err());
        }
    }
}

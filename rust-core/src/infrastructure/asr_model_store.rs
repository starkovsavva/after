//! Reviewed Parakeet artifact deployment; no default selection or ASR SDK here.
use crate::{
    application::asr_model_install::{self, ModelInstallation},
    domain::asr_models::InstalledAsrModel,
    infrastructure::{
        artifact_download::copy_verified,
        generation_store::{seal_distribution, Candidate, GenerationStore},
        runtime_tree::{absolute, open, Layout, Policy, Tree},
    },
};
use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use std::{
    fs::File,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::OnceLock,
    thread,
    time::{Duration, Instant},
};
#[derive(Deserialize)]
struct Artifact {
    #[serde(flatten)]
    policy: Policy,
    id: String,
    archive_url: String,
    archive_sha256: String,
    archive_size: u64,
}
const SCOPE: &str = "runtime/asr-models/parakeet-v3-int8";
const LAYOUT: Layout<'static> = Layout {
    required_files: &[
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
    ],
    library: None,
};
fn artifact() -> Result<&'static Artifact> {
    static VALUE: OnceLock<std::result::Result<Artifact, String>> = OnceLock::new();
    match VALUE.get_or_init(|| {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../backend/asr-model-parakeet-v3-int8.json"
        )))
        .map_err(|e| e.to_string())
    }) {
        Ok(value) => Ok(value),
        Err(error) => anyhow::bail!("{error}"),
    }
}
fn tree(path: &Path) -> Result<Tree> {
    Tree::verify(path, &artifact()?.policy, LAYOUT).map_err(|_| {
        anyhow::anyhow!("ASR model integrity verification failed; reinstall the managed model.")
    })
}
struct Installer {
    store: GenerationStore,
    archive: Option<PathBuf>,
}
impl ModelInstallation for Installer {
    type Candidate = Candidate;
    type Installed = InstalledAsrModel;
    fn stage(&mut self) -> Result<Candidate> {
        let spec = artifact()?;
        let candidate = self.store.create_candidate()?;
        let archive = candidate.directory.join("model.tar.bz2");
        copy_verified(
            self.archive.as_deref(),
            &spec.archive_url,
            &spec.archive_sha256,
            spec.archive_size,
            &archive,
        )?;
        self.store.recheck()?;
        candidate.recheck()?;
        let mut command = Command::new("/usr/bin/tar");
        command
            .args(["--extract", "--bzip2", "--file"])
            .arg(&archive)
            .args(["--no-same-owner", "--no-same-permissions"])
            .current_dir(&candidate.directory)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = after_process_runtime::ProcessTree::spawn(&mut command)?;
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            if let Some(status) = child.try_wait()? {
                ensure!(status.success(), "Cannot extract the verified ASR archive");
                break;
            }
            ensure!(
                Instant::now() < deadline,
                "ASR extraction exceeded its deadline"
            );
            thread::sleep(Duration::from_millis(20));
        }
        std::fs::remove_file(archive)?;
        Ok(candidate)
    }
    fn verify(&mut self, candidate: &Candidate) -> Result<()> {
        self.store.recheck()?;
        candidate.recheck()?;
        tree(&candidate.directory.join(&artifact()?.policy.directory))?.recheck()
    }
    fn activate(&mut self, candidate: &mut Candidate) -> Result<InstalledAsrModel> {
        self.store.recheck()?;
        candidate.recheck()?;
        let spec = artifact()?;
        let directory = candidate.directory.join(&spec.policy.directory);
        seal_distribution(&directory)?;
        self.verify(candidate)?;
        let installed = InstalledAsrModel {
            schema_version: 1,
            model_id: spec.id.clone(),
            generation: candidate
                .directory
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .into(),
            directory: directory
                .to_str()
                .context("Model path must be UTF-8")?
                .into(),
            version: spec.policy.version.clone(),
        };
        self.store.publish(candidate, &installed)?;
        Ok(installed)
    }
}
pub fn install(root: &Path, archive: Option<&Path>) -> Result<InstalledAsrModel> {
    asr_model_install::install(&mut Installer {
        store: GenerationStore::open(root, SCOPE)?,
        archive: archive.map(Path::to_owned),
    })
}
pub struct VerifiedModel {
    tree: Tree,
    directories: Vec<(PathBuf, File)>,
}
impl VerifiedModel {
    pub fn recheck(&self) -> Result<()> {
        for (path, file) in &self.directories {
            let held = file.metadata()?;
            let actual = std::fs::symlink_metadata(path)?;
            crate::infrastructure::runtime_tree::secure(&actual)?;
            ensure!(
                actual.is_dir() && actual.dev() == held.dev() && actual.ino() == held.ino(),
                "Selected ASR generation changed"
            );
        }
        self.tree.recheck()
    }
}
pub fn verify_selected(root: &Path, directory: &Path) -> Result<VerifiedModel> {
    absolute(root)?;
    let _root = open(root, true)?;
    let root = root.canonicalize()?;
    let scope = root.join(SCOPE);
    let spec = artifact()?;
    let generation = directory.parent().context("Invalid ASR generation path")?;
    ensure!(
        generation.parent() == Some(scope.as_path())
            && directory.file_name() == Some(std::ffi::OsStr::new(&spec.policy.directory)),
        "ASR directory is outside its managed scope"
    );
    let id = generation
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid ASR generation")?;
    let uuid = uuid::Uuid::parse_str(id)?;
    ensure!(
        uuid.get_version_num() == 4 && uuid.to_string() == id,
        "Invalid ASR generation"
    );
    let mut directories = Vec::new();
    let mut path = root.clone();
    directories.push((root.clone(), open(&root, true)?));
    for component in Path::new(SCOPE).components() {
        path.push(component.as_os_str());
        directories.push((path.clone(), open(&path, true)?));
    }
    directories.push((generation.to_owned(), open(generation, true)?));
    let model = VerifiedModel {
        tree: tree(directory)?,
        directories,
    };
    model.recheck()?;
    Ok(model)
}
pub(crate) fn is_managed_path(root: &Path, path: &Path) -> Result<bool> {
    let root = root.canonicalize()?;
    let scope = root.join(SCOPE);
    if path.starts_with(&scope) {
        return Ok(true);
    }
    if let Ok(canonical) = path.canonicalize() {
        ensure!(
            !canonical.starts_with(scope),
            "Use the canonical managed ASR path, not an external alias"
        );
    }
    Ok(false)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy_has_complete_artifacts_and_cannot_accept_external_generations() {
        let policy = &artifact().unwrap().policy;
        assert_eq!(policy.files.len(), 8);
        for name in LAYOUT.required_files {
            assert!(policy.files.iter().any(|f| f.path == *name));
        }
        let root = tempfile::tempdir().unwrap();
        assert!(verify_selected(root.path(), Path::new("/outside/model")).is_err());
        assert!(verify_selected(
            root.path(),
            &root
                .path()
                .join(SCOPE)
                .join("../outside")
                .join(&policy.directory)
        )
        .is_err());
    }
}

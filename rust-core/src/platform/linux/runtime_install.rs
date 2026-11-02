//! Linux generation publication. Previous generations are never overwritten or
//! collected here; a failed or interrupted preparation cannot alter active data.
use super::python_runtime::{artifact, verify_distribution};
use crate::{
    application::runtime_install::{self, RuntimeInstallation},
    infrastructure::generation_store::{
        owned_directory, seal_distribution, Candidate, GenerationStore,
    },
};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledRuntime {
    pub schema_version: u32,
    pub generation: String,
    pub target: String,
    pub version: String,
    pub interpreter: PathBuf,
}
struct Installer {
    store: GenerationStore,
    archive: Option<PathBuf>,
    cpu: bool,
    wheelhouse: Option<PathBuf>,
}
impl Installer {
    fn new(root: &Path, archive: Option<&Path>) -> Result<Self> {
        artifact()?;
        Ok(Self {
            store: GenerationStore::open(root, "runtime/linux-python")?,
            archive: archive.map(Path::to_owned),
            cpu: false,
            wheelhouse: None,
        })
    }
    fn run(
        &self,
        candidate: &Candidate,
        program: &Path,
        arguments: &[&std::ffi::OsStr],
    ) -> Result<()> {
        self.store.recheck()?;
        candidate.recheck()?;
        let mut command = Command::new(program);
        command
            .args(arguments)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("LANG", "C.UTF-8")
            .env("PIP_CONFIG_FILE", "/dev/null")
            .env("TMPDIR", candidate.directory.join("tmp"))
            .current_dir(&candidate.directory)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = after_process_runtime::ProcessTree::spawn(&mut command)?;
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            if let Some(status) = child.try_wait()? {
                ensure!(status.success(), "Runtime preparation command failed");
                return Ok(());
            }
            ensure!(
                Instant::now() < deadline,
                "Runtime preparation exceeded its deadline"
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
}
impl RuntimeInstallation for Installer {
    type Candidate = Candidate;
    type Installed = InstalledRuntime;
    fn stage(&mut self) -> Result<Candidate> {
        let candidate = self.store.create_candidate()?;
        owned_directory(&candidate.directory.join("tmp"))?;
        let spec = artifact()?;
        let archive = candidate.directory.join("python.tar.gz");
        crate::infrastructure::artifact_download::copy_verified(
            self.archive.as_deref(),
            &spec.archive_url,
            &spec.archive_sha256,
            spec.archive_size,
            &archive,
        )?;
        self.run(
            &candidate,
            Path::new("/usr/bin/tar"),
            &[
                "--extract".as_ref(),
                "--gzip".as_ref(),
                "--file".as_ref(),
                archive.as_os_str(),
                "--no-same-owner".as_ref(),
                "--no-same-permissions".as_ref(),
            ],
        )?;
        // The fixed archive digest is verified before tar parses any payload.
        fs::remove_file(archive)?;
        Ok(candidate)
    }
    fn verify_distribution(&mut self, candidate: &Candidate) -> Result<()> {
        self.store.recheck()?;
        candidate.recheck()?;
        verify_distribution(&candidate.directory.join("python"))
    }
    fn prepare_environment(&mut self, candidate: &Candidate) -> Result<()> {
        candidate.recheck()?;
        seal_distribution(&candidate.directory.join("python"))?;
        let interpreter = candidate.directory.join("python/bin/python3.12");
        let venv = candidate.directory.join("venv");
        self.run(
            candidate,
            &interpreter,
            &[
                "-B".as_ref(),
                "-I".as_ref(),
                "-m".as_ref(),
                "venv".as_ref(),
                "--symlinks".as_ref(),
                "--without-pip".as_ref(),
                venv.as_os_str(),
            ],
        )?;
        if self.cpu {
            super::speech_dependencies::prepare(
                &candidate.directory,
                self.wheelhouse.as_deref(),
                &|program, args| self.run(candidate, program, args),
            )?;
        }
        Ok(())
    }
    fn verify_environment(&mut self, candidate: &Candidate) -> Result<()> {
        self.verify_distribution(candidate)?;
        let interpreter = candidate.directory.join("venv/bin/python");
        let report = candidate.directory.join("probe.json");
        self.run(candidate, &interpreter, &[
            "-B".as_ref(), "-I".as_ref(), "-c".as_ref(),
            "import json,ssl,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps({'version':sys.version.split()[0],'base':sys.base_prefix,'venv':sys.prefix}))".as_ref(),
            report.as_os_str(),
        ])?;
        let mut text = String::new();
        crate::platform_fs::open_read(&report)?
            .take(8193)
            .read_to_string(&mut text)?;
        ensure!(text.len() <= 8192, "Oversized runtime probe");
        let actual: serde_json::Value = serde_json::from_str(&text)?;
        ensure!(
            actual
                == serde_json::json!({"version":artifact()?.policy.version,"base":candidate.directory.join("python"),"venv":candidate.directory.join("venv")}),
            "Prepared Python environment escaped the pinned runtime"
        );
        self.verify_distribution(candidate)
    }
    fn activate(&mut self, candidate: &mut Candidate) -> Result<InstalledRuntime> {
        self.store.recheck()?;
        candidate.recheck()?;
        let spec = artifact()?;
        let installed = InstalledRuntime {
            schema_version: 1,
            generation: candidate
                .directory
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .into(),
            target: "x86_64-unknown-linux-gnu".into(),
            version: spec.policy.version.clone(),
            interpreter: candidate.directory.join("venv/bin/python"),
        };
        self.store.publish(candidate, &installed)?;
        Ok(installed)
    }
}
/// Installs only CPython and a clean venv. Does not publish speech readiness or
/// install packages/models. The caller explicitly chooses network or an archive.
pub fn install(root: &Path, archive: Option<&Path>) -> Result<InstalledRuntime> {
    runtime_install::install(&mut Installer::new(root, archive)?)
}

#[cfg(all(test, target_arch = "x86_64", target_env = "gnu"))]
mod tests {
    use super::*;
    fn candidate(installer: &Installer) -> Candidate {
        let candidate = installer.store.create_candidate().unwrap();
        fs::write(
            candidate.directory.join("verified-placeholder"),
            b"synthetic; never executed",
        )
        .unwrap();
        candidate
    }

    #[test]
    fn publication_preserves_previous_generations_and_releases_the_fixed_lease() {
        let root = tempfile::tempdir().unwrap();
        let mut installer = Installer::new(root.path(), None).unwrap();
        assert!(Installer::new(root.path(), None).is_err());
        let mut one = candidate(&installer);
        let first = installer.activate(&mut one).unwrap();
        drop(one);
        let mut two = candidate(&installer);
        let second = installer.activate(&mut two).unwrap();
        drop(two);
        assert_ne!(first.generation, second.generation);
        assert!(installer
            .store
            .directory
            .join(&first.generation)
            .join("verified-placeholder")
            .is_file());
        let active: InstalledRuntime = serde_json::from_slice(
            &fs::read(installer.store.directory.join("active.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(active.generation, second.generation);
        drop(installer);
        assert!(Installer::new(root.path(), None).is_ok());
        assert!(root
            .path()
            .join("runtime/linux-python/.install.lock")
            .is_file());
    }
    #[test]
    fn failed_activation_preserves_active_bytes_and_discards_its_own_candidate() {
        let root = tempfile::tempdir().unwrap();
        let mut installer = Installer::new(root.path(), None).unwrap();
        let active = installer.store.directory.join("active.json");
        fs::write(&active, b"previous activation").unwrap();
        let mut candidate = candidate(&installer);
        let path = candidate.directory.clone();
        fs::write(path.join("activation.json"), b"collision").unwrap();
        assert!(installer.activate(&mut candidate).is_err());
        drop(candidate);
        assert!(!path.exists());
        assert_eq!(fs::read(active).unwrap(), b"previous activation");
    }
    #[test]
    fn readonly_candidate_cleanup_never_follows_external_aliases() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let file = outside.path().join("keep");
        fs::write(&file, b"unchanged").unwrap();
        let installer = Installer::new(root.path(), None).unwrap();
        let candidate = candidate(&installer);
        let path = candidate.directory.clone();
        std::os::unix::fs::symlink(outside.path(), path.join("external")).unwrap();
        seal_distribution(&path).unwrap();
        drop(candidate);
        assert!(!path.exists());
        assert_eq!(fs::read(file).unwrap(), b"unchanged");
    }
    #[test]
    fn candidate_replacement_is_rejected_and_cleanup_preserves_the_replacement() {
        let root = tempfile::tempdir().unwrap();
        let installer = Installer::new(root.path(), None).unwrap();
        let candidate = candidate(&installer);
        let path = candidate.directory.clone();
        let moved = installer.store.directory.join("moved-original");
        fs::rename(&path, &moved).unwrap();
        fs::create_dir(&path).unwrap();
        fs::write(path.join("keep"), b"replacement; not owned by candidate").unwrap();
        assert!(candidate.recheck().is_err());
        drop(candidate);
        assert_eq!(
            fs::read(path.join("keep")).unwrap(),
            b"replacement; not owned by candidate"
        );
        assert!(moved.join("verified-placeholder").is_file());
    }
    #[test]
    fn linked_installation_roots_and_lock_files_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), root.path().join("runtime")).unwrap();
        assert!(Installer::new(root.path(), None).is_err());
        fs::remove_file(root.path().join("runtime")).unwrap();
        let installer = Installer::new(root.path(), None).unwrap();
        let lock = installer.store.directory.join(".install.lock");
        drop(installer);
        fs::remove_file(&lock).unwrap();
        let source = outside.path().join("keep");
        fs::write(&source, b"keep").unwrap();
        std::os::unix::fs::symlink(&source, &lock).unwrap();
        assert!(Installer::new(root.path(), None).is_err());
        fs::remove_file(&lock).unwrap();
        fs::hard_link(&source, &lock).unwrap();
        assert!(Installer::new(root.path(), None).is_err());
        assert_eq!(fs::read(source).unwrap(), b"keep");
    }
}

/// Installs the reviewed Linux CPU wheels before activation; models and speech
/// readiness are separate. A cache is read-only input, never an integrity root.
pub fn install_cpu(
    root: &Path,
    archive: Option<&Path>,
    wheelhouse: Option<&Path>,
) -> Result<InstalledRuntime> {
    let mut installer = Installer::new(root, archive)?;
    installer.cpu = true;
    installer.wheelhouse = wheelhouse.map(Path::to_owned);
    runtime_install::install(&mut installer)
}

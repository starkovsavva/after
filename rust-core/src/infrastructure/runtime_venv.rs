//! Unix venv binding, separate from distribution selection or native loading.
//! This validates configuration/aliases, not third-party package provenance.
use super::runtime_tree::{absolute, open, stamp, Stamp, ERROR};
use anyhow::{bail, Context, Result};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Read,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

pub(crate) struct VenvBinding {
    directories: Vec<(PathBuf, File, Stamp)>,
    config_path: PathBuf,
    config: File,
    config_stamp: Stamp,
    links: Vec<(PathBuf, PathBuf, Stamp)>,
}
impl VenvBinding {
    pub(crate) fn verify(venv: &Path, base: &Path, version: &str) -> Result<Self> {
        absolute(venv)?;
        absolute(base)?;
        let mut directories = Vec::new();
        for path in [venv.to_owned(), venv.join("bin")] {
            let directory = open(&path, true)?;
            let observed = stamp(&directory.metadata()?);
            directories.push((path, directory, observed));
        }
        let real = base.join("bin/python3.12");
        let aliases = [
            venv.join("bin/python"),
            venv.join("bin/python3"),
            venv.join("bin/python3.12"),
        ];
        let mut link = aliases[0].clone();
        let mut links = Vec::new();
        let mut complete = false;
        for _ in 0..4 {
            if fs::canonicalize(&link).context(ERROR)? != real {
                bail!(ERROR);
            }
            let info = fs::symlink_metadata(&link).context(ERROR)?;
            if !info.file_type().is_symlink() || info.uid() != unsafe { libc::geteuid() } {
                bail!(ERROR);
            }
            let target = fs::read_link(&link).context(ERROR)?;
            let next = if target.is_absolute() {
                target.clone()
            } else {
                link.parent().context(ERROR)?.join(&target)
            };
            links.push((link, target, stamp(&info)));
            if next == real {
                complete = true;
                break;
            }
            if !aliases.contains(&next) {
                bail!(ERROR);
            }
            link = next;
        }
        if !complete {
            bail!(ERROR);
        }
        let config_path = venv.join("pyvenv.cfg");
        let mut config = open(&config_path, false)?;
        let config_stamp = stamp(&config.metadata()?);
        let mut text = String::new();
        Read::by_ref(&mut config)
            .take(16 * 1024 + 1)
            .read_to_string(&mut text)
            .context(ERROR)?;
        if text.len() > 16 * 1024 {
            bail!(ERROR);
        }
        let mut values = BTreeMap::new();
        for line in text.lines() {
            if let Some((key, value)) = line.split_once('=') {
                if values
                    .insert(key.trim().to_lowercase(), value.trim())
                    .is_some()
                {
                    bail!(ERROR);
                }
            }
        }
        if values.get("include-system-site-packages") != Some(&"false")
            || values.get("version").copied() != Some(version)
            || values
                .get("home")
                .map(Path::new)
                .and_then(|path| fs::canonicalize(path).ok())
                != Some(base.join("bin"))
        {
            bail!(ERROR);
        }
        let binding = Self {
            directories,
            config_path,
            config,
            config_stamp,
            links,
        };
        binding.recheck()?;
        Ok(binding)
    }
    pub(crate) fn recheck(&self) -> Result<()> {
        for (path, directory, expected) in &self.directories {
            if stamp(&directory.metadata()?) != *expected
                || stamp(&fs::symlink_metadata(path)?) != *expected
            {
                bail!(ERROR);
            }
        }
        if stamp(&self.config.metadata()?) != self.config_stamp
            || stamp(&fs::symlink_metadata(&self.config_path)?) != self.config_stamp
        {
            bail!(ERROR);
        }
        for (path, target, expected) in &self.links {
            if stamp(&fs::symlink_metadata(path)?) != *expected || fs::read_link(path)? != *target {
                bail!(ERROR);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    fn fixture(root: &Path) -> (PathBuf, PathBuf) {
        let base = root.join("base");
        let venv = root.join("venv");
        fs::create_dir_all(base.join("bin")).unwrap();
        fs::create_dir_all(venv.join("bin")).unwrap();
        fs::write(base.join("bin/python3.12"), b"synthetic; never executed").unwrap();
        symlink(base.join("bin/python3.12"), venv.join("bin/python3.12")).unwrap();
        symlink("python3.12", venv.join("bin/python3")).unwrap();
        symlink("python3", venv.join("bin/python")).unwrap();
        fs::write(
            venv.join("pyvenv.cfg"),
            format!(
                "home = {}\ninclude-system-site-packages = false\nversion = 3.12.16\n",
                base.join("bin").display()
            ),
        )
        .unwrap();
        (base, venv)
    }
    #[test]
    fn configuration_and_alias_replacement_invalidate_the_selected_binding() {
        for config in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let (base, venv) = fixture(root.path());
            let binding = VenvBinding::verify(&venv, &base, "3.12.16").unwrap();
            if config {
                fs::write(venv.join("pyvenv.cfg"), b"home = /outside").unwrap();
            } else {
                fs::remove_file(venv.join("bin/python")).unwrap();
                symlink("python3.12", venv.join("bin/python")).unwrap();
            }
            assert!(binding.recheck().is_err());
        }
    }
    #[test]
    fn external_directory_and_interpreter_aliases_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let (base, venv) = fixture(root.path());
        let outside = tempfile::tempdir().unwrap();
        let (other, _) = fixture(outside.path());
        fs::remove_file(venv.join("bin/python")).unwrap();
        symlink(other.join("bin/python3.12"), venv.join("bin/python")).unwrap();
        assert!(VenvBinding::verify(&venv, &base, "3.12.16").is_err());
        let alias = root.path().join("linked-venv");
        symlink(&venv, &alias).unwrap();
        assert!(VenvBinding::verify(&alias, &base, "3.12.16").is_err());
    }
    #[test]
    fn duplicate_redirecting_version_and_oversized_configuration_fail() {
        for addition in [
            "HOME = /outside\n".to_owned(),
            "version = 3.13.1\n".into(),
            "include-system-site-packages = true\n".into(),
            "x".repeat(16 * 1024 + 1),
        ] {
            let root = tempfile::tempdir().unwrap();
            let (base, venv) = fixture(root.path());
            let path = venv.join("pyvenv.cfg");
            let original = fs::read_to_string(&path).unwrap();
            fs::write(path, original + &addition).unwrap();
            assert!(VenvBinding::verify(&venv, &base, "3.12.16").is_err());
        }
    }
}

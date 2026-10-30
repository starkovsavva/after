//! Windows implementation. Handles pin every parent without FILE_SHARE_DELETE;
//! reparse points (including junctions), devices and multiply-linked files fail.
//! New private objects have a protected current-user/SYSTEM/Administrators ACL.
use super::*;
use anyhow::{bail, Context};
use serde::Serialize;
use std::{ffi::OsStr, io::Write, mem::{size_of, zeroed}, ops::{Deref, DerefMut}, os::windows::{ffi::OsStrExt, io::{AsRawHandle, FromRawHandle}}, path::{Component, PathBuf, Prefix}, ptr::{null, null_mut}};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE, LocalFree, ERROR_ALREADY_EXISTS},
    Security::{Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SetSecurityInfo, SE_FILE_OBJECT, SDDL_REVISION_1}, EqualSid, GetSecurityDescriptorDacl, GetTokenInformation, TokenOwner, TokenUser, TOKEN_INFORMATION_CLASS, TOKEN_OWNER, TOKEN_QUERY, TOKEN_USER, SECURITY_ATTRIBUTES, PSECURITY_DESCRIPTOR, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION},
    Storage::FileSystem::*,
    System::Threading::{GetCurrentProcess, OpenProcessToken},
};

fn wide(value: &OsStr) -> Vec<u16> { value.encode_wide().chain(Some(0)).collect() }
fn valid_component(value: &OsStr) -> Result<()> {
    let value = value.to_str().context("The private library path must be valid Unicode")?;
    ensure!(!value.is_empty() && !value.ends_with(['.', ' ']) && !value.chars().any(|c| c < ' ' || matches!(c, ':' | '<' | '>' | '"' | '|' | '?' | '*')), "Unsupported private library path");
    let base = value.split('.').next().unwrap().to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL"].contains(&base.as_str())
        || ["COM", "LPT"].iter().any(|prefix| base.strip_prefix(prefix).is_some_and(|suffix| suffix.len()==1 && matches!(suffix.as_bytes()[0], b'1'..=b'9') || ["¹","²","³"].contains(&suffix)));
    ensure!(!reserved, "Device names cannot be library files");
    Ok(())
}
fn validate_path(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "The private library path must be absolute");
    let mut prefix = false;
    for part in path.components() {
        match part {
            Component::Prefix(value) if matches!(value.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)) && !prefix => prefix=true,
            Component::RootDir => {},
            Component::Normal(value) => valid_component(value)?,
            _ => bail!("Unsupported private library path"),
        }
    }
    ensure!(prefix && path.as_os_str().encode_wide().count()<32_760, "Unsupported private library path");
    Ok(())
}
struct Token(HANDLE);
impl Drop for Token { fn drop(&mut self) { unsafe { CloseHandle(self.0); } } }
struct Descriptor(PSECURITY_DESCRIPTOR);
impl Drop for Descriptor { fn drop(&mut self) { unsafe { LocalFree(self.0); } } }
fn token_information(class: TOKEN_INFORMATION_CLASS) -> Result<Vec<usize>> {
    let mut token = null_mut();
    ensure!(unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) }!=0, "Cannot read the library user identity");
    let token = Token(token);
    let mut size=0;
    unsafe { GetTokenInformation(token.0,class,null_mut(),0,&mut size); }
    ensure!(size as usize>=size_of::<usize>() && size<64*1024,"Invalid library user identity");
    let mut bytes=vec![0usize;(size as usize+size_of::<usize>()-1)/size_of::<usize>()];
    ensure!(unsafe { GetTokenInformation(token.0,class,bytes.as_mut_ptr().cast(),size,&mut size) }!=0,"Cannot read the library user identity");
    Ok(bytes)
}
fn token_user() -> Result<Vec<usize>> { token_information(TokenUser) }
fn private_descriptor() -> Result<Descriptor> {
    let token=token_user()?;
    let sid=unsafe { (*(token.as_ptr().cast::<TOKEN_USER>())).User.Sid };
    let mut text=null_mut();
    ensure!(unsafe { ConvertSidToStringSidW(sid,&mut text) }!=0,"Cannot secure private library files");
    let text_owner=Descriptor(text.cast());
    let mut length=0; unsafe { while *text.add(length)!=0 { length+=1; } }
    let sid=String::from_utf16(unsafe { std::slice::from_raw_parts(text,length) })?;
    let sddl=wide(OsStr::new(&format!("O:{sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;{sid})")));
    let mut descriptor=null_mut();
    ensure!(unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(),SDDL_REVISION_1,&mut descriptor,null_mut()) }!=0,"Cannot secure private library files");
    drop(text_owner);
    Ok(Descriptor(descriptor))
}
fn owned(file: &File) -> Result<()> {
    let token=token_user()?;
    let sid=unsafe { (*(token.as_ptr().cast::<TOKEN_USER>())).User.Sid };
    let mut owner=null_mut(); let mut descriptor=null_mut();
    let status=unsafe { GetSecurityInfo(file.as_raw_handle(),SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION,&mut owner,null_mut(),null_mut(),null_mut(),&mut descriptor) };
    ensure!(status==0,"Cannot verify private library ownership");
    let _descriptor=Descriptor(descriptor);
    let current = !owner.is_null() && unsafe { EqualSid(owner,sid) }!=0;
    // SQLite-created WAL/SHM files use the process token's default owner,
    // which can be Administrators for an elevated Windows runner. Accept only
    // this exact native owner, rather than any arbitrary privileged-group SID.
    let default_owner=token_information(TokenOwner)?;
    let default_sid=unsafe { (*(default_owner.as_ptr().cast::<TOKEN_OWNER>())).Owner };
    ensure!(current || (!owner.is_null() && unsafe { EqualSid(owner,default_sid) }!=0),"The library contains a file owned by another account");
    Ok(())
}
fn information(file: &File, directory: bool) -> Result<BY_HANDLE_FILE_INFORMATION> {
    let mut information=unsafe { zeroed::<BY_HANDLE_FILE_INFORMATION>() };
    ensure!(unsafe { GetFileInformationByHandle(file.as_raw_handle(),&mut information) }!=0,"Cannot inspect library file");
    ensure!(information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0,"Links and reparse points are not allowed in the private library");
    ensure!((information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0)==directory,"Unexpected private library file type");
    ensure!(directory || information.nNumberOfLinks==1,"Hard-linked library files are not allowed");
    Ok(information)
}
fn raw_open(path: &Path, access: u32, creation: u32, directory: bool, share_delete: bool, descriptor: Option<&Descriptor>) -> Result<File> {
    let path=wide(path.as_os_str());
    let attributes=descriptor.map(|value| SECURITY_ATTRIBUTES { nLength:size_of::<SECURITY_ATTRIBUTES>() as u32,lpSecurityDescriptor:value.0,bInheritHandle:0 });
    let handle=unsafe { CreateFileW(path.as_ptr(),access,FILE_SHARE_READ | FILE_SHARE_WRITE | if share_delete {FILE_SHARE_DELETE} else {0},attributes.as_ref().map_or(null(),|a|a),creation,FILE_FLAG_OPEN_REPARSE_POINT | if directory {FILE_FLAG_BACKUP_SEMANTICS} else {FILE_ATTRIBUTE_NORMAL},null_mut()) };
    if handle==INVALID_HANDLE_VALUE { return Err(std::io::Error::last_os_error().into()); }
    let file=unsafe { File::from_raw_handle(handle) };
    information(&file,directory)?;
    Ok(file)
}
/// Parent directory handles remain open without delete sharing for the whole
/// mutation/connection. A concurrently installed junction cannot redirect it.
pub struct DirectoryGuard { _handles: Vec<File> }
pub fn pin_directory(path: &Path) -> Result<DirectoryGuard> {
    validate_path(path)?;
    let mut handles=vec![]; let mut current=PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if matches!(component,Component::RootDir | Component::Normal(_)) {
            // Attribute/control-only handles do not enforce Windows sharing
            // restrictions. Request directory data-read access as well, so
            // withholding FILE_SHARE_DELETE really prevents rename/removal.
            // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-createfilew
            handles.push(raw_open(&current,FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES|READ_CONTROL,OPEN_EXISTING,true,false,None)?);
        }
    }
    ensure!(!handles.is_empty(),"Invalid private library directory");
    Ok(DirectoryGuard { _handles:handles })
}
fn set_private(file: &File) -> Result<()> {
    owned(file)?;
    let descriptor=private_descriptor()?;
    let mut present=0; let mut defaulted=0; let mut acl=null_mut();
    ensure!(unsafe { GetSecurityDescriptorDacl(descriptor.0,&mut present,&mut acl,&mut defaulted) }!=0 && present!=0 && !acl.is_null(),"Invalid private library ACL");
    let status=unsafe { SetSecurityInfo(file.as_raw_handle(),SE_FILE_OBJECT,DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION,null_mut(),null_mut(),acl,null()) };
    ensure!(status==0,"Cannot protect private library access");
    Ok(())
}
pub fn private_directory(path: &Path) -> Result<()> {
    validate_path(path)?;
    let descriptor=private_descriptor()?;
    let mut current=PathBuf::new();
    for part in path.components() {
        current.push(part.as_os_str());
        if !matches!(part,Component::Normal(_)) { continue; }
        let parent=current.parent().context("Invalid library directory")?;
        let _guard=pin_directory(parent)?;
        let attrs=SECURITY_ATTRIBUTES { nLength:size_of::<SECURITY_ATTRIBUTES>() as u32,lpSecurityDescriptor:descriptor.0,bInheritHandle:0 };
        let name=wide(current.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(_) => {},
            Err(error) if error.kind()==std::io::ErrorKind::NotFound => {
                if unsafe { CreateDirectoryW(name.as_ptr(),&attrs) }==0 {
                    let error=std::io::Error::last_os_error();
                    ensure!(error.raw_os_error()==Some(ERROR_ALREADY_EXISTS as i32),"Cannot create private library directory: {error}");
                }
            },
            Err(error) => return Err(error.into()),
        }
        let handle=raw_open(&current,FILE_READ_ATTRIBUTES|READ_CONTROL,OPEN_EXISTING,true,false,None)?;
        // Existing ancestors are inspected, never chmodded or re-owned.
        if current==path { drop(handle); let handle=raw_open(&current,FILE_READ_ATTRIBUTES|READ_CONTROL|WRITE_DAC,OPEN_EXISTING,true,false,None)?; set_private(&handle)?; }
    }
    Ok(())
}
pub fn create_private_directory(path: &Path) -> Result<()> {
    validate_path(path)?;
    let _guard=pin_directory(path.parent().context("Invalid private directory")?)?;
    let descriptor=private_descriptor()?;
    let attrs=SECURITY_ATTRIBUTES { nLength:size_of::<SECURITY_ATTRIBUTES>() as u32,lpSecurityDescriptor:descriptor.0,bInheritHandle:0 };
    let name=wide(path.as_os_str());
    if unsafe { CreateDirectoryW(name.as_ptr(),&attrs) }==0 { return Err(std::io::Error::last_os_error().into()); }
    Ok(())
}
pub fn open_read(path: &Path) -> Result<File> {
    validate_path(path)?;
    let _guard=pin_directory(path.parent().context("Invalid library file")?)?;
    let file=raw_open(path,FILE_GENERIC_READ,OPEN_EXISTING,false,true,None)?;
    owned(&file)?;
    Ok(file)
}
pub fn open_private(path: &Path, create_new: bool) -> Result<File> {
    validate_path(path)?;
    let _guard=pin_directory(path.parent().context("Invalid library file")?)?;
    let descriptor=private_descriptor()?;
    let file=raw_open(path,FILE_GENERIC_READ|FILE_GENERIC_WRITE|WRITE_DAC,if create_new {CREATE_NEW} else {OPEN_ALWAYS},false,false,Some(&descriptor))?;
    secure_file(&file)?;
    Ok(file)
}
pub fn secure_file(file: &File) -> Result<()> { information(file,false)?; set_private(file) }
pub fn secure_existing(path: &Path) -> Result<()> { drop(open_private(path,false)?); Ok(()) }
pub fn ordinary_single_file(path: &Path) -> Result<bool> {
    match open_read(path) { Ok(_)=>Ok(true),Err(error) if error.downcast_ref::<std::io::Error>().is_some_and(|e|e.kind()==std::io::ErrorKind::NotFound)=>Ok(false),Err(error)=>Err(error) }
}
pub fn stamp(path: &Path) -> String {
    match open_read(path).and_then(|file| {
        let info=information(&file,false)?;
        let mut basic=unsafe { zeroed::<FILE_BASIC_INFO>() };
        ensure!(unsafe { GetFileInformationByHandleEx(file.as_raw_handle(),FileBasicInfo,(&mut basic as *mut FILE_BASIC_INFO).cast(),size_of::<FILE_BASIC_INFO>() as u32) }!=0,"Cannot inspect source version");
        Ok(format!("{}:{}:{}:{}:{}:{}:{}",info.dwVolumeSerialNumber,info.nFileIndexHigh,info.nFileIndexLow,((info.nFileSizeHigh as u64)<<32)|info.nFileSizeLow as u64,basic.CreationTime,basic.LastWriteTime,basic.ChangeTime))
    }) { Ok(stamp)=>stamp,Err(_)=>"missing-or-unsafe".into() }
}
pub fn atomic_json<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<()> {
    let parent=path.parent().context("Library file has no parent")?;
    private_directory(parent)?;
    let _guard=pin_directory(parent)?;
    ordinary_single_file(path)?;
    let temporary=parent.join(format!(".after-{}.tmp",uuid::Uuid::new_v4()));
    let result=(|| -> Result<()> {
        let mut output=open_private(&temporary,true)?;
        serde_json::to_writer_pretty(&mut output,value)?;
        output.write_all(b"\n")?; output.sync_all()?; drop(output);
        // MoveFileEx replaces the directory entry atomically, preserving the
        // new file's protected ACL. It never writes through a target link.
        ordinary_single_file(path)?;
        let from=wide(temporary.as_os_str()); let to=wide(path.as_os_str());
        ensure!(unsafe { MoveFileExW(from.as_ptr(),to.as_ptr(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH) }!=0,"Cannot atomically commit library file: {}",std::io::Error::last_os_error());
        Ok(())
    })();
    if result.is_err() { let _=fs::remove_file(temporary); }
    result
}
pub struct GuardedConnection { connection: rusqlite::Connection, _file:File, _parents:DirectoryGuard }
impl Deref for GuardedConnection { type Target=rusqlite::Connection; fn deref(&self)->&Self::Target { &self.connection } }
impl DerefMut for GuardedConnection { fn deref_mut(&mut self)->&mut Self::Target { &mut self.connection } }
pub fn sqlite_connection(path: &Path, flags:rusqlite::OpenFlags) -> Result<GuardedConnection> {
    let parents=pin_directory(path.parent().context("Invalid database path")?)?;
    let file=open_private(path,false)?;
    let connection=rusqlite::Connection::open_with_flags(path,flags)?;
    Ok(GuardedConnection {connection,_file:file,_parents:parents})
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::ser::Error;
    use serde_json::json;
    use windows_sys::Win32::Security::{GetSecurityDescriptorControl, SE_DACL_PROTECTED};
    fn private_fixture() -> tempfile::TempDir {
        let root=tempfile::tempdir().unwrap();
        private_directory(root.path()).unwrap();
        root
    }
    #[test]
    fn private_objects_have_a_protected_three_principal_acl() {
        let root=private_fixture();
        let file=open_private(&root.path().join("private.json"),true).unwrap();
        let mut acl=null_mut();let mut descriptor=null_mut();
        assert_eq!(unsafe { GetSecurityInfo(file.as_raw_handle(),SE_FILE_OBJECT,DACL_SECURITY_INFORMATION,null_mut(),null_mut(),&mut acl,null_mut(),&mut descriptor) },0);
        let descriptor=Descriptor(descriptor);
        let mut control=0;let mut revision=0;
        assert_ne!(unsafe { GetSecurityDescriptorControl(descriptor.0,&mut control,&mut revision) },0);
        assert_ne!(control & SE_DACL_PROTECTED,0);
        assert!(!acl.is_null());
        assert_eq!(unsafe { (*acl).AceCount },3,"Only the current user, SYSTEM and Administrators may access the library");
        owned(&file).unwrap();
    }
    #[test]
    fn failed_serialization_preserves_previous_bytes_and_leaves_no_temporary_file() {
        struct Broken;
        impl Serialize for Broken {
            fn serialize<S:serde::Serializer>(&self,_serializer:S)->std::result::Result<S::Ok,S::Error> { Err(S::Error::custom("intentional fixture error")) }
        }
        let root=private_fixture();let path=root.path().join("note.json");
        atomic_json(&path,&json!({"text":"Русский текст, версия 1"})).unwrap();
        let before=fs::read(&path).unwrap();
        assert!(atomic_json(&path,&Broken).is_err());
        assert_eq!(fs::read(&path).unwrap(),before);
        assert_eq!(fs::read_dir(root.path()).unwrap().count(),1);
        atomic_json(&path,&json!({"text":"Updated safely"})).unwrap();
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&fs::read(path).unwrap()).unwrap()["text"],"Updated safely");
    }
    #[test]
    fn kernel_locks_and_directory_pins_reject_concurrent_replacement() {
        let root=private_fixture();let directory=root.path().join("pinned");
        create_private_directory(&directory).unwrap();
        let pin=pin_directory(&directory).unwrap();
        let moved=root.path().join("moved");
        let from=wide(directory.as_os_str());let to=wide(moved.as_os_str());
        assert_eq!(unsafe { MoveFileExW(from.as_ptr(),to.as_ptr(),MOVEFILE_WRITE_THROUGH) },0,"Native rename must be blocked by a live directory pin");
        assert_eq!(std::io::Error::last_os_error().raw_os_error(),Some(windows_sys::Win32::Foundation::ERROR_SHARING_VIOLATION as i32));
        assert!(fs::rename(&directory,&moved).is_err(),"The Rust rename path must also respect the pin");
        assert!(directory.is_dir() && !moved.exists());
        let first=open_private(&directory.join("workspace.lock"),false).unwrap();
        let second=open_private(&directory.join("workspace.lock"),false).unwrap();
        first.lock().unwrap();
        assert!(second.try_lock().is_err());
        first.unlock().unwrap();second.try_lock().unwrap();second.unlock().unwrap();
        drop(first);drop(second);drop(pin);
        fs::rename(directory,root.path().join("moved")).unwrap();
    }
    #[test]
    fn hard_link_alias_is_not_read_or_replaced() {
        let root=private_fixture();let outside=root.path().join("original.json");let alias=root.path().join("alias.json");
        atomic_json(&outside,&json!({"external":"must remain"})).unwrap();
        fs::hard_link(&outside,&alias).unwrap();
        let before=fs::read(&outside).unwrap();
        assert!(open_read(&alias).is_err());
        assert!(atomic_json(&alias,&json!({"external":"bad"})).is_err());
        assert_eq!(fs::read(&outside).unwrap(),before);
    }
    #[test]
    fn junction_parent_cannot_redirect_read_or_atomic_write() {
        let base=private_fixture();let library=base.path().join("library");let outside=base.path().join("outside");
        create_private_directory(&library).unwrap();create_private_directory(&outside).unwrap();
        let original=outside.join("external.json");fs::write(&original,b"unchanged external bytes").unwrap();
        let junction=library.join("escape");
        let result=std::process::Command::new("cmd.exe").args(["/D","/C","mklink","/J"]).arg(&junction).arg(&outside).output().unwrap();
        assert!(result.status.success(),"The native junction fixture must be created: {}",String::from_utf8_lossy(&result.stderr));
        assert!(open_read(&junction.join("external.json")).is_err());
        assert!(atomic_json(&junction.join("external.json"),&json!({"bad":true})).is_err());
        assert_eq!(fs::read(&original).unwrap(),b"unchanged external bytes");
        fs::remove_dir(junction).unwrap();assert!(outside.is_dir());
    }
    #[test]
    fn windows_device_ads_network_and_traversal_paths_fail_closed() {
        for path in [r"C:relative",r"C:\library\..\outside",r"C:\library\CON.json",r"C:\library\file:stream",r"\\server\share\library",r"\\.\PhysicalDrive0",r"C:\library\trailing."] {
            assert!(validate_path(Path::new(path)).is_err(),"{path}");
        }
        assert!(validate_path(Path::new(r"C:\Users\Друг\AppData\Local\After library")).is_ok());
    }
}

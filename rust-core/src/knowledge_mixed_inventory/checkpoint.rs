//! Restartable derived checkpoint. Stores IDs and content digests, never text.
//! It does not grant access or prove that privacy settings did not race.
use super::*;
use anyhow::bail;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::fs::{DirBuilder, OpenOptions};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::time::Duration;

pub(super) struct Checkpoint {
    connection: Connection,
}

impl Checkpoint {
    /// Open only a private, derived cache for this exact root and selected
    /// scope. A changed membership is refused instead of mixing generations.
    pub(super) fn open(inventory: &Inventory) -> Result<Self> {
        Self::open_impl(inventory,false)
    }

    /// Explicitly discard only this derived checkpoint and begin a new sweep.
    pub(super) fn restart(inventory: &Inventory) -> Result<Self> {
        Self::open_impl(inventory,true)
    }

    fn open_impl(inventory: &Inventory, restart: bool) -> Result<Self> {
        crate::storage::meeting_directory(&inventory.root, "_inventory_probe")?;
        // macOS commonly exposes the temp directory through /var -> /private/var.
        // SQLite NOFOLLOW rejects symlinks anywhere in the path, so resolve the
        // already-checked root before appending our checked private directory.
        let directory = fs::canonicalize(&inventory.root)?.join("knowledge-mixed-index");
        match fs::symlink_metadata(&directory) {
            Ok(info) => ensure!(info.is_dir() && !info.file_type().is_symlink(), "Недопустимый каталог индекса"),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => DirBuilder::new().mode(0o700).create(&directory)?,
            Err(error) => return Err(error.into()),
        }
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let scope = format!("{:x}", Sha256::digest(serde_json::to_vec(&inventory.folder)?));
        let path = directory.join(format!("meetings-{scope}.sqlite"));
        // SQLite may recover an interrupted transaction from one of these
        // files during open. Never follow an unrelated link as a journal.
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar=directory.join(format!("meetings-{scope}.sqlite{suffix}"));
            match fs::symlink_metadata(sidecar) {
                Ok(info) => ensure!(info.is_file() && !info.file_type().is_symlink() &&
                    info.nlink()==1 && info.permissions().mode() & 0o077 == 0,
                    "Недопустимый служебный файл индекса"),
                Err(error) if error.kind()==std::io::ErrorKind::NotFound => {},
                Err(error) => return Err(error.into()),
            }
        }
        let empty_or_new = match OpenOptions::new().write(true).create_new(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW).open(&path) {
            Ok(file) => { file.set_permissions(fs::Permissions::from_mode(0o600))?; file.sync_all()?; true }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let info=fs::symlink_metadata(&path)?;
                ensure!(info.is_file() && !info.file_type().is_symlink(), "Недопустимый файл индекса");
                ensure!(info.nlink()==1, "Файл индекса не должен иметь жёстких ссылок");
                ensure!(info.permissions().mode() & 0o077 == 0, "Файл индекса не является приватным");
                info.len()==0
            }
            Err(error) => return Err(error.into()),
        };
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW;
        let mut connection=Connection::open_with_flags(path,flags)?;
        connection.busy_timeout(Duration::from_secs(1))?;
        const APPLICATION_ID: i64=0x41464b42;
        let application_id:i64=connection.query_row("PRAGMA application_id",[],|row|row.get(0))?;
        if empty_or_new && application_id==0 {
            // Set the cache identity and version in one transaction: after a
            // crash the file is either empty or can be opened and resumed.
            let tx=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            tx.pragma_update(None,"application_id",APPLICATION_ID)?;
            tx.pragma_update(None,"user_version",1)?;
            tx.commit()?;
        } else {
            let version:i64=connection.query_row("PRAGMA user_version",[],|row|row.get(0))?;
            ensure!(application_id==APPLICATION_ID && version==1,"Неподходящий файл или версия индекса");
        }
        connection.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA secure_delete=ON;
            CREATE TABLE IF NOT EXISTS state (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL,
                membership TEXT NOT NULL, cursor TEXT, complete INTEGER NOT NULL CHECK(complete IN (0,1)),
                examined INTEGER NOT NULL, skipped INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sources (
                meeting_id TEXT PRIMARY KEY NOT NULL, content_digest TEXT NOT NULL
            );")?;
        let state: Option<(i64,String)>=connection.query_row(
            "SELECT version,membership FROM state WHERE singleton=1",[],|row|Ok((row.get(0)?,row.get(1)?))).optional()?;
        if restart {
            ensure!(state.as_ref().is_none_or(|(version,_)|*version==1),"Неподдерживаемая версия индекса");
            let tx=connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            tx.execute("DELETE FROM sources",[])?;
            tx.execute("DELETE FROM state",[])?;
            tx.execute("INSERT INTO state VALUES(1,1,?1,NULL,0,0,0)",params![inventory.membership_digest])?;
            tx.commit()?;
        } else { match state {
            Some((1,membership)) => ensure!(membership == inventory.membership_digest,
                "Состав библиотеки изменился. Индекс нуждается в новом проходе."),
            Some(_) => bail!("Неподдерживаемая версия индекса"),
            None => { connection.execute("INSERT INTO state VALUES(1,1,?1,NULL,0,0,0)",params![inventory.membership_digest])?; }
        }}
        Ok(Self { connection })
    }

    /// Commit a page's source digests and the cursor together. Cancellation
    /// immediately before commit discards both, making a retry idempotent.
    pub(super) fn advance(&mut self, inventory: &Inventory, cancelled: impl Fn() -> bool) -> Result<bool> {
        if cancelled() { bail!("Индексация остановлена"); }
        let (membership,old_cursor,complete):(String,Option<String>,i64)=self.connection.query_row(
            "SELECT membership,cursor,complete FROM state WHERE singleton=1",[],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?)))?;
        ensure!(membership==inventory.membership_digest,"Состав библиотеки изменился");
        if complete != 0 { return Ok(true); }
        let cursor:Option<Cursor>=old_cursor.as_deref().map(serde_json::from_str).transpose()?;
        let result=page(inventory,cursor.as_ref(),MAX_PAGE)?;
        if result.next.is_none() {
            ensure!(membership_is_current(inventory),"Состав библиотеки изменился. Начните заново.");
        }
        let tx=self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current:(String,Option<String>,i64)=tx.query_row(
            "SELECT membership,cursor,complete FROM state WHERE singleton=1",[],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?)))?;
        ensure!(current==(membership,old_cursor,0),"Индекс изменился в другом процессе");
        for document in &result.documents {
            let digest=format!("{:x}",Sha256::digest(serde_json::to_vec(document)?));
            tx.execute("INSERT INTO sources(meeting_id,content_digest) VALUES(?1,?2)",params![document.meeting_id,digest])?;
        }
        let finished=result.next.is_none();
        let next=result.next.as_ref().map(serde_json::to_string).transpose()?;
        tx.execute("UPDATE state SET cursor=?1,complete=?2,examined=examined+?3,skipped=skipped+?4 WHERE singleton=1",
            params![next,finished as i64,result.examined as i64,result.skipped as i64])?;
        if cancelled() { bail!("Индексация остановлена"); }
        tx.commit()?;
        Ok(finished)
    }

    /// Verify indexed members against the live source; this is still only a
    /// point-in-time audit, not authorization or a publication barrier.
    pub(super) fn audit(&self,inventory:&Inventory) -> Result<bool> {
        self.audit_with_cancel(inventory, &||false)
    }

    pub(super) fn audit_with_cancel(&self,inventory:&Inventory,cancelled:&impl Fn()->bool) -> Result<bool> {
        ensure!(!cancelled(),"Индексация остановлена");
        if !membership_is_current(inventory) {return Ok(false);}
        let (membership,complete,skipped):(String,i64,i64)=self.connection.query_row(
            "SELECT membership,complete,skipped FROM state WHERE singleton=1",[],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?)))?;
        if membership!=inventory.membership_digest || complete==0 {return Ok(false);}
        let expected_count:i64=self.connection.query_row("SELECT count(*) FROM sources",[],|row|row.get(0))?;
        let mut cursor=None;
        let mut seen=0i64;
        let mut seen_skipped=0i64;
        loop {
            ensure!(!cancelled(),"Индексация остановлена");
            let current=page(inventory,cursor.as_ref(),MAX_PAGE)?;
            seen_skipped+=current.skipped as i64;
            for actual in current.documents {
                let expected:Option<String>=self.connection.query_row(
                    "SELECT content_digest FROM sources WHERE meeting_id=?1",params![actual.meeting_id],|row|row.get(0)).optional()?;
                if expected.as_deref()!=Some(format!("{:x}",Sha256::digest(serde_json::to_vec(&actual)?)).as_str()) {return Ok(false);}
                seen+=1;
            }
            cursor=current.next;
            if cursor.is_none() {break;}
        }
        Ok(seen==expected_count && seen_skipped==skipped && membership_is_current(inventory))
    }

    /// Private experimental input only. It re-reads live authorized sources;
    /// an audit is a freshness check, never an atomic publication guarantee.
    pub(super) fn collect(&self,inventory:&Inventory,limit:usize,cancelled:&impl Fn()->bool)
        -> Result<(Vec<MeetingTopicDocument>,usize,bool)> {
        self.collect_impl(inventory,limit,cancelled,false)
    }
    pub(super) fn collect_available(&self,inventory:&Inventory,limit:usize,cancelled:&impl Fn()->bool)
        -> Result<(Vec<MeetingTopicDocument>,usize,bool)> {
        self.collect_impl(inventory,limit,cancelled,true)
    }
    fn collect_impl(&self,inventory:&Inventory,limit:usize,cancelled:&impl Fn()->bool,include_partial:bool)
        -> Result<(Vec<MeetingTopicDocument>,usize,bool)> {
        ensure!(limit>0 && limit<=1000,"Некорректный лимит встреч");
        ensure!(self.audit_with_cancel(inventory,cancelled)?,"Индекс встреч неполный или устарел. Требуется сверка.");
        let total:i64=self.connection.query_row("SELECT count(*) FROM sources",[],|row|row.get(0))?;
        let skipped:i64=self.connection.query_row("SELECT skipped FROM state WHERE singleton=1",[],|row|row.get(0))?;
        let mut incomplete=skipped>0;
        let mut documents=Vec::new();
        let mut cursor=None;
        loop {
            ensure!(!cancelled(),"Индексация остановлена");
            let current=page(inventory,cursor.as_ref(),MAX_PAGE)?;
            incomplete |= current.skipped>0;
            for actual in current.documents {
                let expected:Option<String>=self.connection.query_row(
                    "SELECT content_digest FROM sources WHERE meeting_id=?1",params![actual.meeting_id],|row|row.get(0)).optional()?;
                let digest=format!("{:x}",Sha256::digest(serde_json::to_vec(&actual)?));
                ensure!(expected.as_deref()==Some(digest.as_str()),"Источник встречи изменился. Требуется сверка.");
                if actual.partial {incomplete=true; if !include_partial {continue;}}
                if documents.len()<limit {documents.push(actual);}
            }
            cursor=current.next;
            if cursor.is_none() || documents.len()>=limit {break;}
        }
        ensure!(membership_is_current(inventory),"Состав встреч изменился. Требуется сверка.");
        Ok((documents,total as usize,incomplete))
    }

    #[cfg(test)]
    pub(super) fn progress(&self)->Result<(i64,i64,i64)> {
        Ok(self.connection.query_row("SELECT complete,examined,skipped FROM state WHERE singleton=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?)
    }
}

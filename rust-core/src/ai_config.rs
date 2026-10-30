//! Shared settings and source permissions; no model runtime or network operations.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, rename_all="camelCase")]
pub struct Settings { pub features: AppFeatures, pub mode: String, pub local_model: String, pub local_provider: String, pub local_endpoint: String, pub cloud_model: String, pub cloud_provider: String, pub cloud_endpoint: String, #[serde(rename="cloudAPI", alias="cloudApi")] pub cloud_api: String, pub cloud_output: String, pub cloud_reasoning: String, #[serde(rename="chatGPTAccountID")] pub chat_gpt_account_id: String, pub language: String, pub focus: String, pub summary_user_context: String }
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default, rename_all="camelCase")]
pub struct AppFeatures {
    pub cards: bool,
    pub tasks: bool,
    pub calendar: bool,
    pub assistant: bool,
    pub semantic_search: bool,
}
impl Default for Settings {
    fn default() -> Self { Self { features:AppFeatures::default(), mode:"local".into(), local_model:"qwen3.5:9b-q4_K_M".into(), local_provider:"managed".into(), local_endpoint:String::new(), cloud_model:"gpt-4.1-mini".into(), cloud_provider:"openai".into(), cloud_endpoint:String::new(), cloud_api:"responses".into(), cloud_output:"schema".into(), cloud_reasoning:"none".into(), chat_gpt_account_id:String::new(), language:"ru".into(), focus:"Решения, задачи, ответственные, сроки, точные цифры, требования и риски. ".into(), summary_user_context:String::new() } }
}

pub(crate) fn snapshot_settings(snapshot: &str) -> Result<Settings> {
    if snapshot.len() > 256 * 1024 { bail!("Сохранённые настройки операции слишком большие"); }
    let value: Value = serde_json::from_str(snapshot).context("Не удалось прочитать настройки фоновой операции")?;
    if !value.is_object() { bail!("Настройки фоновой операции должны быть объектом"); }
    serde_json::from_value(value).context("Проверьте сохранённые настройки ИИ")
}
pub(crate) fn settings(root:&Path) -> Result<Settings> {
    match std::env::var("POSLE_JOB_SETTINGS") {
        Ok(snapshot) => return snapshot_settings(&snapshot),
        Err(std::env::VarError::NotUnicode(_)) => bail!("Настройки операции должны быть в UTF-8"),
        Err(std::env::VarError::NotPresent) => {},
    }
    if !root.join("settings.json").exists() { return Ok(Settings::default()); }
    serde_json::from_value(crate::storage::regular_json(&root.join("settings.json"))?).context("Проверьте настройки ИИ")
}
/// Current feature permissions must never come from a frozen job snapshot.
/// A queued job may keep its provider, but feature revocation applies at once.
pub(crate) fn live_features(root: &Path) -> Result<AppFeatures> { crate::folders::available_features(root) }

/// Resolve source permissions from one committed workspace snapshot. This must
/// also work while a domain command already holds the workspace file lock.
pub(crate) struct FeatureResolver {
    global: Value,
    workspace: crate::notes::NotesWorkspace,
}
impl FeatureResolver {
    pub(crate) fn new(root: &Path) -> Result<Self> {
        Ok(Self { global: if root.join("settings.json").exists() { crate::storage::regular_json(&root.join("settings.json"))? } else { json!({}) },
            workspace:crate::folders::workspace_snapshot(root)? })
    }
    pub(crate) fn folder_for(&self, source: &Value) -> Result<Option<String>> {
        let explicit=source["folderID"].as_str();
        let note=source["noteID"].as_str().or_else(||source["taskID"].as_str().and_then(|id|if id.starts_with("summary:"){None}else{Some(id.strip_prefix("manual:").unwrap_or(id))}));
        let meeting=source["meetingID"].as_str().filter(|id|!id.is_empty())
            .or_else(||source["taskID"].as_str().and_then(|id|id.strip_prefix("summary:")).and_then(|id|id.split(':').next()));
        // A selected object owns its canonical scope, including the base inbox.
        // An old UI folder selection cannot grant permissions to another task.
        let folder=if let Some(note)=note.and_then(|id|self.workspace.notes.iter().find(|n|n.id==id)) {
            crate::folders::folder_id_for_note(&self.workspace,&note.id)
        } else if let Some(meeting)=meeting {
            crate::folders::folder_id_for_meeting(&self.workspace,meeting)
        } else { explicit };
        if let Some(id)=folder { if !self.workspace.folders.iter().any(|f|f.id==id) { bail!("Папка удалена. Обновите данные."); } }
        Ok(folder.map(str::to_owned))
    }
    pub(crate) fn settings_for(&self, source: &Value) -> Result<Settings> {
        let mut value=self.global.clone();
        if let Some(id)=self.folder_for(source)? {
            let folder=self.workspace.folders.iter().find(|f|f.id==id).context("Папка удалена")?;
            crate::folders::apply_overrides(&mut value,&folder.overrides)?;
        }
        serde_json::from_value(value).context("Некорректные настройки профиля папки")
    }
    pub(crate) fn features_for(&self, source: &Value) -> Result<AppFeatures> { Ok(self.settings_for(source)?.features) }
    pub(crate) fn in_scope(&self, source: &Value, input: &Value) -> bool {
        input["folderID"].as_str().is_none_or(|folder|self.folder_for(source).is_ok_and(|id|id.as_deref()==Some(folder)))
    }
}
pub(crate) fn live_features_for(root:&Path,meeting:Option<&str>,folder:Option<&str>)->Result<AppFeatures> {
    FeatureResolver::new(root)?.features_for(&json!({"meetingID":meeting,"folderID":folder}))
}
pub(crate) fn live_features_for_input(root:&Path,input:&Value)->Result<AppFeatures> {
    FeatureResolver::new(root)?.features_for(input)
}
pub(crate) fn profile_for_input(root:&Path,input:&Value)->Result<crate::folders::ProfileSnapshot> {
    let resolver=FeatureResolver::new(root)?;
    let folder=resolver.folder_for(input)?;
    crate::folders::resolve(root,None,folder.as_deref())
}
pub(crate) fn check_captured_profile(root:&Path,input:&Value)->Result<crate::folders::ProfileSnapshot> {
    let current=profile_for_input(root,input)?;
    match std::env::var("POSLE_JOB_FOLDER_PROFILE") {
        Ok(snapshot)=>{
            if snapshot.len()>128*1024 { bail!("Сохранённый профиль папки слишком большой"); }
            let saved:Value=serde_json::from_str(&snapshot).context("Не удалось прочитать профиль фоновой операции")?;
            if saved["fingerprint"]!=current.fingerprint || saved["folderID"].as_str()!=current.folder_id.as_deref() {
                bail!("Профиль папки изменился после постановки в очередь. Запустите операцию заново; данные сохранены.");
            }
        },
        Err(std::env::VarError::NotPresent)=>{
            if std::env::var_os("POSLE_JOB_SETTINGS").is_some() && current.folder_id.is_some() {
                bail!("У фоновой операции нет сохранённого профиля папки. Запустите её заново из встречи.");
            }
        },
        Err(_)=>bail!("Профиль операции должен быть в UTF-8"),
    }
    Ok(current)
}
pub(crate) fn settings_for_input(root:&Path,input:&Value)->Result<Settings> {
    check_captured_profile(root,input)?;
    let live=FeatureResolver::new(root)?.settings_for(input)?;
    if std::env::var_os("POSLE_JOB_SETTINGS").is_some() {
        let captured=settings(root)?;
        if serde_json::to_value(&captured)?!=serde_json::to_value(&live)? { bail!("Настройки модели не совпадают с сохранённым профилем операции. Запустите обработку заново."); }
        Ok(captured)
    } else { Ok(live) }
}
pub(crate) fn require_profile_current(root:&Path,input:&Value,fingerprint:&str)->Result<()> {
    if profile_for_input(root,input)?.fingerprint!=fingerprint { bail!("Профиль папки изменился во время обработки. Повторите операцию; предыдущие данные сохранены."); }
    Ok(())
}

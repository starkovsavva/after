//! Configuration values only: no filesystem, network, runtime or UI dependencies.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub features: AppFeatures,
    pub mode: String,
    pub local_model: String,
    pub local_provider: String,
    pub local_endpoint: String,
    pub cloud_model: String,
    pub cloud_provider: String,
    pub cloud_endpoint: String,
    #[serde(rename = "cloudAPI", alias = "cloudApi")]
    pub cloud_api: String,
    pub cloud_output: String,
    pub cloud_reasoning: String,
    #[serde(rename = "chatGPTAccountID")]
    pub chat_gpt_account_id: String,
    pub language: String,
    pub focus: String,
    pub summary_user_context: String,
}
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(default, rename_all = "camelCase")]
pub struct AppFeatures {
    pub cards: bool,
    pub tasks: bool,
    pub calendar: bool,
    pub assistant: bool,
    pub semantic_search: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            features: AppFeatures::default(),
            mode: "local".into(),
            local_model: "qwen3.5:9b-q4_K_M".into(),
            local_provider: "managed".into(),
            local_endpoint: String::new(),
            cloud_model: "gpt-4.1-mini".into(),
            cloud_provider: "openai".into(),
            cloud_endpoint: String::new(),
            cloud_api: "responses".into(),
            cloud_output: "schema".into(),
            cloud_reasoning: "none".into(),
            chat_gpt_account_id: String::new(),
            language: "ru".into(),
            focus: "Решения, задачи, ответственные, сроки, точные цифры, требования и риски. "
                .into(),
            summary_user_context: String::new(),
        }
    }
}

pub(crate) fn validate_reasoning(effort: &str) -> anyhow::Result<()> {
    if ![
        "auto", "none", "minimal", "low", "medium", "high", "xhigh", "max",
    ]
    .contains(&effort)
    {
        anyhow::bail!("Выберите уровень рассуждений ChatGPT в настройках.");
    }
    Ok(())
}

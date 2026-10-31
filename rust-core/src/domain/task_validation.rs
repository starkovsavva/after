//! Task/material validation without filesystem or provider access.
use super::{tasks::*, workspace::NotesWorkspace};
use anyhow::{ensure, Result};
use std::collections::HashSet;
pub(crate) const MAX_EVENTS: usize = 500;
pub(crate) const MAX_CONTEXT: usize = 180_000;
pub(crate) fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
pub(crate) fn bounded(s: &str, max: usize) -> bool {
    s.len() <= max && !s.contains('\0')
}
pub(crate) fn checked_url(s: &str) -> bool {
    s.is_empty()
        || url::Url::parse(s).is_ok_and(|u| {
            matches!(u.scheme(), "http" | "https")
                && !u.host_str().unwrap_or("").is_empty()
                && u.username().is_empty()
                && u.password().is_none()
        })
}

pub(crate) fn validate_workspace(workspace: &NotesWorkspace) -> Result<()> {
    ensure!(
        workspace.task_workspaces.len() <= 10_000 && workspace.task_plans.len() <= 100,
        "Слишком много данных задач"
    );
    let mut ids = HashSet::new();
    for r in &workspace.task_workspaces {
        ensure!(
            valid_id(&r.note_id) && ids.insert(&r.note_id),
            "Некорректная задача в рабочей области"
        );
        ensure!(
            ["todo", "doing", "blocked", "done"].contains(&r.status.as_str())
                && ["local", "manual", "yandex", "google"].contains(&r.source.as_str()),
            "Некорректный статус или источник задачи"
        );
        ensure!(
            bounded(&r.external_url, 4096)
                && checked_url(&r.external_url)
                && bounded(&r.project, 512)
                && r.materials.len() <= 200
                && r.history.len() <= MAX_EVENTS,
            "Некорректные материалы задачи"
        );
        let mut mids = HashSet::new();
        for m in &r.materials {
            validate_material(m)?;
            ensure!(mids.insert(&m.id), "Повторный материал задачи");
        }
        for e in &r.history {
            ensure!(
                valid_id(&e.id)
                    && bounded(&e.kind, 80)
                    && bounded(&e.text, 20_000)
                    && bounded(&e.actor, 256)
                    && e.created_at.is_finite()
                    && e.created_at >= 0.0,
                "Некорректное событие задачи"
            );
            validate_artifacts(&e.artifacts)?;
            if let Some(s) = &e.snapshot {
                ensure!(
                    serde_json::to_vec(s)?.len() <= MAX_CONTEXT + 20_000,
                    "Слишком большой снимок контекста"
                );
            }
        }
        if let Some(c) = &r.claim {
            ensure!(
                valid_id(&c.id)
                    && bounded(&c.agent_id, 256)
                    && !c.agent_id.is_empty()
                    && c.claimed_at.is_finite()
                    && c.context_version.len() == 64,
                "Некорректное принятие задачи агентом"
            );
        }
    }
    Ok(())
}
pub(crate) fn validate_material(m: &TaskMaterial) -> Result<()> {
    ensure!(
        valid_id(&m.id)
            && ["note", "meeting", "file", "folder", "repository", "link"]
                .contains(&m.kind.as_str())
            && bounded(&m.title, 1024)
            && !m.title.trim().is_empty(),
        "Некорректный материал задачи"
    );
    ensure!(
        m.segment_ids.len() <= 200 && m.created_at.is_finite() && m.created_at >= 0.0,
        "Некорректный источник материала"
    );
    if let Some(id) = &m.note_id {
        ensure!(valid_id(id), "Некорректная заметка материала");
    }
    if let Some(id) = &m.meeting_id {
        ensure!(valid_id(id), "Некорректная встреча материала");
    }
    if let Some(id) = &m.attachment_id {
        ensure!(valid_id(id), "Некорректное вложение материала");
    }
    if let Some(path) = &m.path {
        ensure!(
            bounded(path, 4096) && !path.trim().is_empty(),
            "Некорректная ссылка на папку"
        );
    }
    if let Some(url) = &m.url {
        ensure!(
            bounded(url, 4096) && checked_url(url) && !url.is_empty(),
            "Используйте ссылку HTTP или HTTPS без пароля"
        );
    }
    ensure!(
        match m.kind.as_str() {
            "note" => m.note_id.is_some(),
            "file" => m.note_id.is_some() && m.attachment_id.is_some(),
            "meeting" => m.meeting_id.is_some(),
            "folder" => m.path.is_some(),
            "repository" => m.path.is_some() || m.url.is_some(),
            "link" => m.url.is_some(),
            _ => false,
        },
        "Укажите источник материала"
    );
    Ok(())
}
pub(crate) fn validate_artifacts(items: &[TaskArtifact]) -> Result<()> {
    ensure!(
        items.len() <= 20,
        "За один раз можно сохранить до 20 результатов"
    );
    for a in items {
        ensure!(
            valid_id(&a.id)
                && bounded(&a.title, 1024)
                && bounded(&a.kind, 80)
                && bounded(&a.text, 30_000)
                && a.url.as_deref().is_none_or(checked_url),
            "Некорректный результат агента"
        );
    }
    ensure!(
        serde_json::to_vec(items)?.len() <= 90_000,
        "Результаты агента слишком большие"
    );
    Ok(())
}

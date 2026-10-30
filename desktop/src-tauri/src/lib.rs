pub mod bridge;
pub mod models;
mod capture;
mod media;

use bridge::LibraryBridge;
use models::*;
use tauri::Manager;
use serde::Serialize;
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};

struct RecordingGate(AtomicBool);
struct RecordingPermit(Arc<RecordingGate>);
impl RecordingPermit {
    fn acquire(gate: Arc<RecordingGate>) -> Result<Self, HostError> {
        gate.0.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| HostError::new("busy", "A recording operation is already in progress."))?;
        Ok(Self(gate))
    }
}
impl Drop for RecordingPermit { fn drop(&mut self) { self.0.0.store(false, Ordering::Release); } }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SavedRecording { meeting: Meeting, interrupted: bool }

fn capture_error(_: String) -> HostError {
    HostError::new("recording_error", "Recording could not be completed. Check microphone permissions and available devices. Any captured audio remains available for recovery.")
}

async fn background<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, HostError> + Send + 'static,
) -> Result<T, HostError> {
    tauri::async_runtime::spawn_blocking(operation)
        .await
        .map_err(|_| {
            HostError::new(
                "engine_failure",
                "The library operation could not be completed. Your changes remain in the editor.",
            )
        })?
}
#[tauri::command]
async fn get_workspace(state: tauri::State<'_, LibraryBridge>) -> Result<Workspace, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.workspace()).await
}
#[tauri::command]
async fn get_meeting(
    state: tauri::State<'_, LibraryBridge>,
    meeting_id: String,
) -> Result<MeetingDetail, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.meeting(meeting_id)).await
}
#[tauri::command]
async fn choose_and_import(state: tauri::State<'_, LibraryBridge>) -> Result<Option<Meeting>, HostError> {
    let bridge = state.inner().clone();
    background(move || {
        #[cfg(windows)]
        {
            let selected = rfd::FileDialog::new()
                .add_filter("Audio and video", &["mp4", "mov", "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "ogg", "webm", "mkv", "aac"])
                .pick_file();
            selected.map(|path| bridge.import_meeting(&path, None)).transpose()
        }
        #[cfg(not(windows))]
        {
            let _ = bridge;
            Err(HostError::new("unsupported_platform", "Import is not available on this platform."))
        }
    }).await
}
#[tauri::command]
async fn start_recording(state: tauri::State<'_, Arc<capture::Recorder>>, bridge: tauri::State<'_, LibraryBridge>, gate: tauri::State<'_, Arc<RecordingGate>>, mode: String) -> Result<capture::RecordingStatus, HostError> {
    let recorder = state.inner().clone();
    let bridge = bridge.inner().clone();
    let permit = RecordingPermit::acquire(gate.inner().clone())?;
    background(move || {
        let _permit = permit;
        // Workspace initialisation establishes the private library ACL before
        // the recorder creates a child directory inheriting those permissions.
        bridge.workspace()?;
        recorder.start(mode).map_err(capture_error)
    }).await
}
#[tauri::command]
fn recording_status(state: tauri::State<'_, std::sync::Arc<capture::Recorder>>) -> capture::RecordingStatus { state.status() }

#[tauri::command]
async fn stop_recording(state: tauri::State<'_, Arc<capture::Recorder>>, bridge: tauri::State<'_, LibraryBridge>, gate: tauri::State<'_, Arc<RecordingGate>>, title: String) -> Result<SavedRecording, HostError> {
    let recorder = state.inner().clone(); let bridge = bridge.inner().clone();
    let permit = RecordingPermit::acquire(gate.inner().clone())?;
    background(move || {
        let _permit = permit;
        let completed = recorder.stop().map_err(capture_error)?;
        let meeting = bridge.import_meeting(&completed.path, Some(&title))?;
        if let Some(id) = &completed.status.session_id { let _ = recorder.mark_imported(id); }
        Ok(SavedRecording { meeting, interrupted: completed.status.phase == "interrupted" })
    }).await
}

#[tauri::command]
async fn recoverable_recordings(state: tauri::State<'_, std::sync::Arc<capture::Recorder>>) -> Result<Vec<capture::RecoverableRecording>, HostError> {
    let recorder = state.inner().clone();
    background(move || recorder.recoverable().map_err(capture_error)).await
}

#[tauri::command]
async fn recover_recording(state: tauri::State<'_, Arc<capture::Recorder>>, bridge: tauri::State<'_, LibraryBridge>, gate: tauri::State<'_, Arc<RecordingGate>>, session_id: String) -> Result<SavedRecording, HostError> {
    let recorder = state.inner().clone(); let bridge = bridge.inner().clone();
    let permit = RecordingPermit::acquire(gate.inner().clone())?;
    background(move || {
        let _permit = permit;
        let completed = recorder.recover(session_id.clone()).map_err(capture_error)?;
        let meeting = bridge.import_meeting(&completed.path, None)?;
        let _ = recorder.mark_imported(&session_id);
        Ok(SavedRecording { meeting, interrupted: true })
    }).await
}
#[tauri::command]
async fn save_note(
    state: tauri::State<'_, LibraryBridge>,
    input: SaveNoteInput,
) -> Result<Note, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.save_note(input)).await
}
#[tauri::command]
async fn save_folder(
    state: tauri::State<'_, LibraryBridge>,
    input: SaveFolderInput,
) -> Result<Folder, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.save_folder(input)).await
}
#[tauri::command]
async fn search_library(
    state: tauri::State<'_, LibraryBridge>,
    query: String,
    folder_id: Option<String>,
) -> Result<SearchResults, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.search(query, folder_id)).await
}
#[tauri::command]
async fn feature_operation(state: tauri::State<'_, LibraryBridge>, operation: String, args: serde_json::Value) -> Result<serde_json::Value, HostError> {
    let bridge = state.inner().clone();
    background(move || bridge.feature_operation(&operation, args)).await
}

fn local_navigation(url: &tauri::Url) -> bool {
    let bundled = (url.scheme() == "tauri" && url.host_str() == Some("localhost"))
        || (["http", "https"].contains(&url.scheme())
            && url.host_str() == Some("tauri.localhost")
            && url.port().is_none());
    let development = cfg!(debug_assertions)
        && url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port() == Some(1420);
    url.username().is_empty() && url.password().is_none() && (bundled || development)
}

fn library_commands<R: tauri::Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    builder.register_asynchronous_uri_scheme_protocol("after-media", |context, request, responder| {
        if context.webview_label() != "main" {
            responder.respond(tauri::http::Response::builder().status(403).body(Vec::new()).unwrap());
            return;
        }
        let bridge = context.app_handle().state::<LibraryBridge>().inner().clone();
        tauri::async_runtime::spawn_blocking(move || responder.respond(media::respond(&bridge, request)));
    }).invoke_handler(tauri::generate_handler![
        get_workspace,
        get_meeting,
        choose_and_import,
        start_recording,
        recording_status,
        stop_recording,
        recoverable_recordings,
        recover_recording,
        feature_operation,
        save_note,
        save_folder,
        search_library
    ])
}

fn application_context<R: tauri::Runtime>() -> tauri::Context<R> {
    tauri::generate_context!()
}

pub fn run() {
    library_commands(tauri::Builder::default())
        .setup(|app| {
            let resource_dir = app.path().resource_dir()?;
            let data_dir = app.path().app_local_data_dir()?;
            let bridge = LibraryBridge::bundled(&resource_dir, &data_dir)?;
            app.manage(std::sync::Arc::new(capture::Recorder::new(bridge.data_root())));
            app.manage(Arc::new(RecordingGate(AtomicBool::new(false))));
            app.manage(bridge);
            tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::App("index.html".into()),
            )
            .title("After")
            .inner_size(1240.0, 820.0)
            .min_inner_size(760.0, 560.0)
            .on_navigation(local_navigation)
            .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny)
            .build()?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let operation_running = window.try_state::<Arc<RecordingGate>>().is_some_and(|gate| gate.0.load(Ordering::Acquire));
                let recording_active = window.try_state::<Arc<capture::Recorder>>().is_some_and(|recorder| recorder.status().session_id.is_some());
                if operation_running || recording_active { api.prevent_close(); }
            }
        })
        .run(application_context())
        .expect("After desktop could not start");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_bundled_ui_and_exact_debug_origin_can_navigate() {
        for value in [
            "tauri://localhost/index.html",
            "http://tauri.localhost/index.html",
            "https://tauri.localhost/index.html",
        ] {
            assert!(local_navigation(&value.parse().unwrap()), "{value}");
        }
        for value in [
            "https://example.org",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "http://127.0.0.1:9999",
            "https://tauri.localhost.evil.test",
            "tauri://evil/index.html",
            "http://user@tauri.localhost/",
        ] {
            assert!(!local_navigation(&value.parse().unwrap()), "{value}");
        }
        assert_eq!(
            local_navigation(&"http://127.0.0.1:1420/".parse().unwrap()),
            cfg!(debug_assertions)
        );
    }
}

#[cfg(all(test, debug_assertions))]
mod ipc_tests {
    use super::*;
    use serde_json::{json, Value};
    use tauri::test::{get_ipc_response, mock_builder, MockRuntime, INVOKE_KEY};

    fn local_origin() -> &'static str {
        if cfg!(windows) {
            "http://tauri.localhost"
        } else {
            "tauri://localhost"
        }
    }

    fn request(
        window: &tauri::WebviewWindow<MockRuntime>,
        command: &str,
        arguments: Value,
        origin: &str,
    ) -> Result<Value, Value> {
        get_ipc_response(
            window,
            tauri::webview::InvokeRequest {
                cmd: command.into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: origin.parse().unwrap(),
                body: tauri::ipc::InvokeBody::Json(arguments),
                headers: Default::default(),
                invoke_key: INVOKE_KEY.into(),
            },
        )
        .map(|body| body.deserialize::<Value>().unwrap())
    }
    fn application(bridge: LibraryBridge) -> tauri::App<MockRuntime> {
        library_commands(mock_builder())
            .manage(bridge)
            .build(application_context())
            .unwrap()
    }
    fn window(
        app: &tauri::App<MockRuntime>,
        label: &str,
        fixture_root: &std::path::Path,
    ) -> tauri::WebviewWindow<MockRuntime> {
        // Tauri prepares this directory before dispatching to the runtime,
        // even for MockRuntime. Without an explicit location, Windows/Linux
        // tests create the actual appLocalDataDir instead of staying isolated.
        let webview_data = fixture_root.join("webviews").join(label);
        let window = tauri::WebviewWindowBuilder::new(app, label, Default::default())
            .data_directory(webview_data.clone())
            .build()
            .unwrap();
        assert!(
            webview_data.is_dir(),
            "The mock webview must use its owned fixture directory"
        );
        window
    }

    #[test]
    fn generated_acl_allows_only_local_main_window_and_registered_library_commands() {
        let fixture = tempfile::tempdir().unwrap();
        let engine = fixture.path().join("unexecutable-engine");
        std::fs::write(&engine, b"").unwrap();
        let bridge = LibraryBridge::for_development(engine, fixture.path().join("data")).unwrap();
        let app = application(bridge);
        let main = window(&app, "main", fixture.path());
        let untrusted = window(&app, "untrusted", fixture.path());
        // Authorized calls reach our typed boundary, whose unavailable-engine error
        // is distinct from the permission failure returned for every other case.
        let allowed = request(&main, "get_workspace", json!({}), local_origin()).unwrap_err();
        assert_eq!(allowed["code"], "engine_failure");
        let invalid = request(&main, "feature_operation", json!({"operation":"read_file","args":{}}), local_origin()).unwrap_err();
        assert_eq!(invalid["code"], "invalid_request");
        for (window, origin, command) in [
            (&main, "https://example.org", "get_workspace"),
            (&untrusted, local_origin(), "get_workspace"),
            (&main, "https://example.org", "feature_operation"),
            (&untrusted, local_origin(), "feature_operation"),
            (&main, local_origin(), "read_file"),
            (&main, local_origin(), "plugin:fs|read_text_file"),
            (&main, local_origin(), "plugin:shell|execute"),
        ] {
            let denied = request(window, command, json!({}), origin).unwrap_err();
            assert!(
                denied.is_string(),
                "A denied command must never reach a library operation: {denied}"
            );
            assert_ne!(denied["code"], "engine_failure");
        }
        assert!(!fixture.path().join("data/core.sqlite").exists());
    }

    #[test]
    #[ignore = "Set AFTER_TEST_ENGINE_PATH to the built canonical engine and run --ignored"]
    fn real_engine_is_reachable_through_typed_tauri_ipc_and_cas_errors_survive() {
        let engine = std::path::PathBuf::from(
            std::env::var_os("AFTER_TEST_ENGINE_PATH").expect("AFTER_TEST_ENGINE_PATH"),
        );
        let fixture = tempfile::tempdir().unwrap();
        let bridge = LibraryBridge::for_development(engine, fixture.path().join("data")).unwrap();
        let app = application(bridge);
        let main = window(&app, "main", fixture.path());
        let initial = request(&main, "get_workspace", json!({}), local_origin()).unwrap();
        assert_eq!(initial["notes"], json!([]));
        let folder = request(
            &main,
            "save_folder",
            json!({"input":{"name":"English"}}),
            local_origin(),
        )
        .unwrap();
        let created = request(
            &main,
            "save_note",
            json!({"input":{"title":"Draft", "text":"Phrasal verbs", "folderId":folder["id"]}}),
            local_origin(),
        )
        .unwrap();
        let input = json!({"input":{"id":created["id"], "title":"Edited", "text":"Phrasal verbs kept", "expectedRevision":created["revision"]}});
        let edited = request(&main, "save_note", input.clone(), local_origin()).unwrap();
        assert_eq!(edited["folderId"], folder["id"]);
        assert_eq!(
            request(&main, "save_note", input, local_origin()).unwrap_err()["code"],
            "conflict"
        );
        let workspace = request(&main, "get_workspace", json!({}), local_origin()).unwrap();
        assert_eq!(workspace["notes"][0]["title"], "Edited");
        assert_eq!(workspace["notes"][0]["revision"], 2);
        assert!(fixture.path().join("data/core.sqlite").is_file());
    }
}

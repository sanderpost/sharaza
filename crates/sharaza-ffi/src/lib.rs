use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sharaza_core::SharazaEngine;
use sharaza_core::image_ops::{
    beautify_image, decode_rgba_image, encode_rgba_image, stitch_scrolling_frames,
};
use sharaza_core::models::{
    AppConfig, BuiltinUrlShortener, CaptureMetadata, HistoryFilter, ImageEffectsConfig,
    ImageFormat, LinkFormat, ResolvedCredentials, TaskSettings, UploadResult, WorkflowPreset,
};
use sharaza_core::name_parser::{NameParser, NameParserType, UploadInfoParser};
use sharaza_core::sxcu::CustomUploaderItem;
use sharaza_core::tools::{ColorFormats, compute_hashes_bytes, compute_hashes_file, generate_qr_png};
use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::slice;
use tokio::runtime::Runtime;

pub struct SharazaCoreHandle {
    engine: SharazaEngine,
    runtime: Runtime,
}

#[repr(C)]
pub struct SharazaByteBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub width: u32,
    pub height: u32,
    pub status_code: i32,
    pub error: *mut c_char,
}

#[derive(Serialize)]
struct FfiEnvelope<T: Serialize> {
    ok: bool,
    data: Option<T>,
    error: Option<String>,
}

fn ok_json<T: Serialize>(data: T) -> *mut c_char {
    let s = serde_json::to_string(&FfiEnvelope {
        ok: true,
        data: Some(data),
        error: None,
    })
    .unwrap_or_else(|e| format!(r#"{{"ok":false,"data":null,"error":"{e}"}}"#));
    to_c_string(s)
}

fn err_json(msg: impl Into<String>) -> *mut c_char {
    let s = serde_json::to_string(&FfiEnvelope::<Value> {
        ok: false,
        data: None,
        error: Some(msg.into()),
    })
    .unwrap_or_else(|_| r#"{"ok":false,"data":null,"error":"serialization error"}"#.to_string());
    to_c_string(s)
}

fn to_c_string(s: String) -> *mut c_char {
    let sanitized = s.replace('\0', "");
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("invalid cstring").unwrap())
        .into_raw()
}

unsafe fn from_c_str(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("Null string pointer".to_string());
    }
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("Invalid UTF-8: {e}"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_core_open(
    data_dir_utf8: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut SharazaCoreHandle {
    let dir = match unsafe { from_c_str(data_dir_utf8) } {
        Ok(d) => d,
        Err(e) => {
            if !error_out.is_null() {
                unsafe { *error_out = to_c_string(e) };
            }
            return ptr::null_mut();
        }
    };

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            if !error_out.is_null() {
                unsafe { *error_out = to_c_string(format!("Tokio runtime init failed: {e}")) };
            }
            return ptr::null_mut();
        }
    };

    match SharazaEngine::open(&dir) {
        Ok(engine) => Box::into_raw(Box::new(SharazaCoreHandle { engine, runtime })),
        Err(e) => {
            if !error_out.is_null() {
                unsafe { *error_out = to_c_string(e.to_string()) };
            }
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_core_close(handle: *mut SharazaCoreHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_buffer_free(buf: SharazaByteBuffer) {
    if !buf.ptr.is_null() && buf.len > 0 {
        unsafe {
            let _ = Box::from_raw(slice::from_raw_parts_mut(buf.ptr, buf.len));
        }
    }
    if !buf.error.is_null() {
        unsafe {
            drop(CString::from_raw(buf.error));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_core_request_json(
    handle: *mut SharazaCoreHandle,
    op_utf8: *const c_char,
    payload_json_utf8: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return err_json("Null SharazaCoreHandle");
    }
    let core = unsafe { &*handle };
    let op = match unsafe { from_c_str(op_utf8) } {
        Ok(s) => s,
        Err(e) => return err_json(e),
    };
    let payload = if payload_json_utf8.is_null() {
        "{}".to_string()
    } else {
        match unsafe { from_c_str(payload_json_utf8) } {
            Ok(s) if !s.trim().is_empty() => s,
            Ok(_) => "{}".to_string(),
            Err(e) => return err_json(e),
        }
    };

    dispatch_json(core, &op, &payload)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_execute_image_workflow_bytes(
    handle: *mut SharazaCoreHandle,
    image_ptr: *const u8,
    image_len: usize,
    metadata_json_utf8: *const c_char,
    settings_json_utf8: *const c_char,
    creds_json_utf8: *const c_char,
) -> *mut c_char {
    if handle.is_null() || image_ptr.is_null() || image_len == 0 {
        return err_json("Invalid handle or empty image buffer");
    }
    let core = unsafe { &*handle };
    let bytes = unsafe { slice::from_raw_parts(image_ptr, image_len) };

    let meta: CaptureMetadata = unsafe { from_c_str(metadata_json_utf8) }
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let settings: TaskSettings = match unsafe { from_c_str(settings_json_utf8) }
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
    {
        Some(s) => s,
        None => match core.engine.config() {
            Ok(cfg) => cfg.default_settings,
            Err(e) => return err_json(e.to_string()),
        },
    };

    let creds: ResolvedCredentials = unsafe { from_c_str(creds_json_utf8) }
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    match core
        .runtime
        .block_on(core.engine.execute_image_workflow(bytes, meta, &settings, &creds))
    {
        Ok(report) => ok_json(report),
        Err(e) => err_json(e.to_string()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_beautify_image_png(
    png_ptr: *const u8,
    png_len: usize,
    effects_json_utf8: *const c_char,
) -> SharazaByteBuffer {
    if png_ptr.is_null() || png_len == 0 {
        return err_buffer("Empty PNG buffer");
    }
    let bytes = unsafe { slice::from_raw_parts(png_ptr, png_len) };
    let cfg: ImageEffectsConfig = unsafe { from_c_str(effects_json_utf8) }
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let rgba = match decode_rgba_image(bytes) {
        Ok(img) => img,
        Err(e) => return err_buffer(e.to_string()),
    };
    let out = beautify_image(&rgba, &cfg);
    let w = out.width();
    let h = out.height();
    match encode_rgba_image(&out, ImageFormat::PNG, 100) {
        Ok(png) => ok_buffer(png, w, h, 0),
        Err(e) => err_buffer(e.to_string()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_generate_qr_png(
    text_utf8: *const c_char,
    module_px: u32,
) -> SharazaByteBuffer {
    let text = match unsafe { from_c_str(text_utf8) } {
        Ok(s) => s,
        Err(e) => return err_buffer(e),
    };
    match generate_qr_png(&text, module_px) {
        Ok(png) => {
            let (w, h) = decode_rgba_image(&png)
                .map(|i| (i.width(), i.height()))
                .unwrap_or((0, 0));
            ok_buffer(png, w, h, 0)
        }
        Err(e) => err_buffer(e.to_string()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sharaza_stitch_scrolling_pngs(
    png_ptrs: *const *const u8,
    png_lens: *const usize,
    frame_count: usize,
    auto_ignore_bottom: bool,
) -> SharazaByteBuffer {
    if png_ptrs.is_null() || png_lens.is_null() || frame_count == 0 {
        return err_buffer("No scrolling frames provided");
    }
    let ptrs = unsafe { slice::from_raw_parts(png_ptrs, frame_count) };
    let lens = unsafe { slice::from_raw_parts(png_lens, frame_count) };
    let mut frames = Vec::with_capacity(frame_count);
    for i in 0..frame_count {
        if ptrs[i].is_null() || lens[i] == 0 {
            continue;
        }
        let raw = unsafe { slice::from_raw_parts(ptrs[i], lens[i]) };
        match decode_rgba_image(raw) {
            Ok(img) => frames.push(img),
            Err(e) => return err_buffer(format!("Frame {i} decode error: {e}")),
        }
    }
    match stitch_scrolling_frames(&frames, auto_ignore_bottom) {
        Ok((stitched, status)) => {
            let w = stitched.width();
            let h = stitched.height();
            let code = status as i32;
            match encode_rgba_image(&stitched, ImageFormat::PNG, 100) {
                Ok(png) => ok_buffer(png, w, h, code),
                Err(e) => err_buffer(e.to_string()),
            }
        }
        Err(e) => err_buffer(e.to_string()),
    }
}

fn ok_buffer(vec: Vec<u8>, width: u32, height: u32, status_code: i32) -> SharazaByteBuffer {
    let mut boxed = vec.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    SharazaByteBuffer {
        ptr,
        len,
        width,
        height,
        status_code,
        error: ptr::null_mut(),
    }
}

fn err_buffer(msg: impl Into<String>) -> SharazaByteBuffer {
    SharazaByteBuffer {
        ptr: ptr::null_mut(),
        len: 0,
        width: 0,
        height: 0,
        status_code: -1,
        error: to_c_string(msg.into()),
    }
}

fn dispatch_json(core: &SharazaCoreHandle, op: &str, payload: &str) -> *mut c_char {
    match op {
        "get_config" => match core.engine.config() {
            Ok(cfg) => ok_json(cfg),
            Err(e) => err_json(e.to_string()),
        },
        "save_config" => match serde_json::from_str::<AppConfig>(payload) {
            Ok(cfg) => match core.engine.save_config(&cfg) {
                Ok(()) => ok_json(json!({"saved": true})),
                Err(e) => err_json(e.to_string()),
            },
            Err(e) => err_json(format!("Invalid AppConfig JSON: {e}")),
        },
        "parse_name" => {
            #[derive(Deserialize)]
            struct Req {
                pattern: String,
                #[serde(default)]
                window_title: Option<String>,
                #[serde(default)]
                process_name: Option<String>,
                #[serde(default)]
                width: u32,
                #[serde(default)]
                height: u32,
                #[serde(default)]
                preview: bool,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => {
                    let mut p = NameParser::new(NameParserType::FileName);
                    p.window_text = req.window_title;
                    p.process_name = req.process_name;
                    p.image_width = req.width;
                    p.image_height = req.height;
                    p.is_preview_mode = req.preview;
                    p.auto_increment_number = if req.preview {
                        41
                    } else {
                        core.engine.storage.next_auto_increment().unwrap_or(0)
                    };
                    ok_json(json!({ "result": p.parse(&req.pattern) }))
                }
                Err(e) => err_json(e.to_string()),
            }
        }
        "format_upload_link" => {
            #[derive(Deserialize)]
            struct Req {
                result: UploadResult,
                format: LinkFormat,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => ok_json(json!({
                    "formatted": UploadInfoParser::format_link(&req.result, req.format)
                })),
                Err(e) => err_json(e.to_string()),
            }
        }
        "query_history" => {
            let filter: HistoryFilter = serde_json::from_str(payload).unwrap_or_default();
            match core.engine.storage.query_history(&filter) {
                Ok(items) => ok_json(items),
                Err(e) => err_json(e.to_string()),
            }
        }
        "delete_history" => {
            #[derive(Deserialize)]
            struct Req {
                ids: Vec<i64>,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.engine.storage.delete_history(&req.ids) {
                    Ok(n) => ok_json(json!({ "deleted": n })),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "clear_history" => match core.engine.storage.clear_history() {
            Ok(()) => ok_json(json!({ "cleared": true })),
            Err(e) => err_json(e.to_string()),
        },
        "history_stats" => match core.engine.storage.history_stats() {
            Ok(stats) => ok_json(stats),
            Err(e) => err_json(e.to_string()),
        },
        "import_sharex_history" => {
            #[derive(Deserialize)]
            struct Req {
                json_text: String,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.engine.storage.import_sharex_history_json(&req.json_text) {
                    Ok(count) => ok_json(json!({ "imported": count })),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "list_workflows" => match core.engine.storage.list_workflows() {
            Ok(list) => ok_json(list),
            Err(e) => err_json(e.to_string()),
        },
        "save_workflow" => match serde_json::from_str::<WorkflowPreset>(payload) {
            Ok(preset) => match core.engine.storage.save_workflow(&preset) {
                Ok(()) => ok_json(json!({ "saved": true })),
                Err(e) => err_json(e.to_string()),
            },
            Err(e) => err_json(e.to_string()),
        },
        "delete_workflow" => {
            #[derive(Deserialize)]
            struct Req {
                id: String,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.engine.storage.delete_workflow(&req.id) {
                    Ok(()) => ok_json(json!({ "deleted": true })),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "list_custom_uploaders" => match core.engine.storage.list_custom_uploaders() {
            Ok(list) => ok_json(list),
            Err(e) => err_json(e.to_string()),
        },
        "save_custom_uploader" => match CustomUploaderItem::from_sxcu_str(payload) {
            Ok(item) => match core.engine.storage.save_custom_uploader(&item) {
                Ok(()) => ok_json(item),
                Err(e) => err_json(e.to_string()),
            },
            Err(e) => err_json(e.to_string()),
        },
        "delete_custom_uploader" => {
            #[derive(Deserialize)]
            struct Req {
                name: String,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.engine.storage.delete_custom_uploader(&req.name) {
                    Ok(()) => ok_json(json!({ "deleted": true })),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "finalize_recording_workflow" => {
            #[derive(Deserialize)]
            struct Req {
                recorded_file_path: String,
                is_gif: bool,
                settings: TaskSettings,
                #[serde(default)]
                credentials: ResolvedCredentials,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.runtime.block_on(
                    core.engine.finalize_recording_workflow(
                        &req.recorded_file_path,
                        req.is_gif,
                        &req.settings,
                        &req.credentials,
                    ),
                ) {
                    Ok(rep) => ok_json(rep),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "upload_text_workflow" => {
            #[derive(Deserialize)]
            struct Req {
                text: String,
                settings: TaskSettings,
                #[serde(default)]
                credentials: ResolvedCredentials,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.runtime.block_on(core.engine.upload_text_workflow(
                    &req.text,
                    &req.settings,
                    &req.credentials,
                )) {
                    Ok(rep) => ok_json(rep),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "upload_file_workflow" => {
            #[derive(Deserialize)]
            struct Req {
                file_path: String,
                settings: TaskSettings,
                #[serde(default)]
                credentials: ResolvedCredentials,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match core.runtime.block_on(core.engine.upload_file_workflow(
                    &req.file_path,
                    &req.settings,
                    &req.credentials,
                )) {
                    Ok(rep) => ok_json(rep),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "shorten_url" => {
            #[derive(Deserialize)]
            struct Req {
                shortener: BuiltinUrlShortener,
                url: String,
                #[serde(default)]
                credentials: ResolvedCredentials,
                #[serde(default)]
                custom_uploader_name: Option<String>,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => {
                    let custom = req.custom_uploader_name.and_then(|name| {
                        core.engine
                            .storage
                            .list_custom_uploaders()
                            .ok()?
                            .into_iter()
                            .find(|u| u.display_name().eq_ignore_ascii_case(&name))
                    });
                    match core.runtime.block_on(core.engine.uploader.shorten_url(
                        req.shortener,
                        &req.url,
                        &req.credentials,
                        custom.as_ref(),
                    )) {
                        Ok(short_url) => ok_json(json!({ "shortened_url": short_url })),
                        Err(e) => err_json(e.to_string()),
                    }
                }
                Err(e) => err_json(e.to_string()),
            }
        }
        "compute_hashes_file" => {
            #[derive(Deserialize)]
            struct Req {
                file_path: String,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => match compute_hashes_file(&req.file_path) {
                    Ok(h) => ok_json(h),
                    Err(e) => err_json(e.to_string()),
                },
                Err(e) => err_json(e.to_string()),
            }
        }
        "compute_hashes_text" => {
            #[derive(Deserialize)]
            struct Req {
                text: String,
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => ok_json(compute_hashes_bytes(req.text.as_bytes())),
                Err(e) => err_json(e.to_string()),
            }
        }
        "convert_color" => {
            #[derive(Deserialize)]
            struct Req {
                r: u8,
                g: u8,
                b: u8,
                #[serde(default = "default_alpha")]
                a: u8,
            }
            fn default_alpha() -> u8 {
                255
            }
            match serde_json::from_str::<Req>(payload) {
                Ok(req) => ok_json(ColorFormats::from_rgba(req.r, req.g, req.b, req.a)),
                Err(e) => err_json(e.to_string()),
            }
        }
        other => err_json(format!("Unknown FFI operation: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn ffi_lifecycle_and_json_roundtrip() {
        let tmp = std::env::temp_dir().join(format!("sharaza_ffi_{}", std::process::id()));
        let c_dir = CString::new(tmp.to_string_lossy().to_string()).unwrap();
        let mut err_ptr: *mut c_char = ptr::null_mut();

        unsafe {
            let handle = sharaza_core_open(c_dir.as_ptr(), &mut err_ptr);
            assert!(!handle.is_null());
            assert!(err_ptr.is_null());

            let op = CString::new("parse_name").unwrap();
            let req = CString::new(r#"{"pattern":"shot_%i{4}","preview":true}"#).unwrap();
            let resp_ptr = sharaza_core_request_json(handle, op.as_ptr(), req.as_ptr());
            let resp_str = CStr::from_ptr(resp_ptr).to_str().unwrap().to_string();
            sharaza_string_free(resp_ptr);
            assert!(resp_str.contains("shot_0042"), "got: {resp_str}");

            let qr_text = CString::new("https://getsharex.com").unwrap();
            let qr_buf = sharaza_generate_qr_png(qr_text.as_ptr(), 4);
            assert!(!qr_buf.ptr.is_null());
            assert!(qr_buf.len > 100);
            sharaza_buffer_free(qr_buf);

            sharaza_core_close(handle);
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }
}

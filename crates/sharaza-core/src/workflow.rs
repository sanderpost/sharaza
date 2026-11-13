use crate::error::{CoreError, CoreResult};
use crate::image_ops::{
    apply_image_effects, beautify_image, create_thumbnail, decode_rgba_image, encode_rgba_image,
};
use crate::models::{
    AppConfig, CaptureMetadata, FileExistAction, HistoryItem, ResolvedCredentials, TaskSettings,
    UploadResult, WorkflowExecutionReport, after_capture_flags, after_upload_flags,
};
use crate::name_parser::{NameParser, NameParserType, UploadInfoParser};
use crate::storage::StorageManager;
use crate::sxcu::CustomUploaderItem;
use crate::uploader::UploaderManager;
use base64::Engine;
use chrono::Utc;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct SharazaEngine {
    pub storage: StorageManager,
    pub uploader: UploaderManager,
}

impl SharazaEngine {
    pub fn open<P: AsRef<Path>>(data_dir: P) -> CoreResult<Self> {
        let data_dir = data_dir.as_ref();
        fs::create_dir_all(data_dir)?;
        let db_path = data_dir.join("History.sqlite");
        let storage = StorageManager::open(db_path)?;
        let uploader = UploaderManager::new();
        Ok(Self { storage, uploader })
    }

    pub fn config(&self) -> CoreResult<AppConfig> {
        self.storage.load_app_config()
    }

    pub fn save_config(&self, cfg: &AppConfig) -> CoreResult<()> {
        self.storage.save_app_config(cfg)
    }

    pub fn format_capture_filename(
        &self,
        settings: &TaskSettings,
        metadata: &CaptureMetadata,
        ext: &str,
    ) -> CoreResult<String> {
        let auto_inc = self.storage.next_auto_increment()?;
        let mut parser = NameParser::new(NameParserType::FileName);
        parser.auto_increment_number = auto_inc;
        parser.max_name_length = settings.max_name_length;
        parser.max_title_length = settings.max_title_length;
        parser.image_width = metadata.width;
        parser.image_height = metadata.height;
        parser.window_text = metadata.window_title.clone();
        parser.process_name = metadata.process_name.clone();

        let pattern = if metadata.process_name.is_some() && !settings.name_pattern_window.is_empty()
        {
            &settings.name_pattern_window
        } else {
            &settings.name_pattern
        };

        let stem = parser.parse(pattern);
        let clean_stem = if stem.trim().is_empty() {
            "capture".to_string()
        } else {
            stem
        };
        Ok(format!("{clean_stem}.{}", ext.trim_start_matches('.')))
    }

    pub fn resolve_screenshots_folder(
        &self,
        settings: &TaskSettings,
        metadata: &CaptureMetadata,
    ) -> PathBuf {
        let mut parser = NameParser::new(NameParserType::FilePath);
        parser.window_text = metadata.window_title.clone();
        parser.process_name = metadata.process_name.clone();
        let base = parser.parse(&settings.screenshots_folder);
        let mut dir = PathBuf::from(base);
        if !settings.sub_folder_pattern.trim().is_empty() {
            let sub = parser.parse(&settings.sub_folder_pattern);
            if !sub.trim().is_empty() {
                dir = dir.join(sub);
            }
        }
        dir
    }

    /// Executes ShareX's `WorkerTask` pipeline (`DoAfterCaptureJobs` -> `DoFileJobs` -> `DoUploadJob` -> `DoAfterUploadJobs` -> `History`)
    /// for a captured or edited image (`input_png_or_rgba_bytes` encoded as PNG/JPEG/etc.).
    pub async fn execute_image_workflow(
        &self,
        image_bytes: &[u8],
        metadata: CaptureMetadata,
        settings: &TaskSettings,
        creds: &ResolvedCredentials,
    ) -> CoreResult<WorkflowExecutionReport> {
        let mut img = decode_rgba_image(image_bytes)?;
        let flags = settings.after_capture_tasks;
        let mut report = WorkflowExecutionReport::default();

        if (flags & after_capture_flags::BEAUTIFY_IMAGE) != 0 {
            img = beautify_image(&img, &settings.image_effects);
        }

        if (flags & after_capture_flags::ADD_IMAGE_EFFECTS) != 0 {
            img = apply_image_effects(&img, &settings.image_effects);
        }

        let final_meta = CaptureMetadata {
            width: img.width(),
            height: img.height(),
            ..metadata
        };

        let ext = settings.image_format.extension();
        let file_name = self.format_capture_filename(settings, &final_meta, ext)?;
        report.file_name = file_name.clone();

        let encoded_bytes = encode_rgba_image(&img, settings.image_format, settings.jpeg_quality)?;
        let png_for_clipboard = if settings.image_format == crate::models::ImageFormat::PNG {
            encoded_bytes.clone()
        } else {
            encode_rgba_image(&img, crate::models::ImageFormat::PNG, 100)?
        };

        if (flags & after_capture_flags::COPY_IMAGE_TO_CLIPBOARD) != 0 {
            report.copy_image_to_clipboard = true;
            report.processed_png_bytes_base64 =
                Some(base64::engine::general_purpose::STANDARD.encode(&png_for_clipboard));
        } else if (flags & after_capture_flags::BEAUTIFY_IMAGE) != 0
            || (flags & after_capture_flags::ADD_IMAGE_EFFECTS) != 0
        {
            report.processed_png_bytes_base64 =
                Some(base64::engine::general_purpose::STANDARD.encode(&png_for_clipboard));
        }

        report.pin_to_screen = (flags & after_capture_flags::PIN_TO_SCREEN) != 0;
        report.run_ocr = (flags & after_capture_flags::DO_OCR) != 0;
        report.scan_qr = (flags & after_capture_flags::SCAN_QR_CODE) != 0;

        let target_folder = self.resolve_screenshots_folder(settings, &final_meta);

        if (flags & after_capture_flags::SAVE_IMAGE_TO_FILE) != 0 {
            fs::create_dir_all(&target_folder)?;
            if let Some(dest_path) =
                resolve_target_path(&target_folder, &file_name, settings.file_exist_action)
            {
                fs::write(&dest_path, &encoded_bytes)?;
                report.saved_file_path = Some(dest_path.to_string_lossy().to_string());
            }
        }

        if (flags & after_capture_flags::SAVE_THUMBNAIL_IMAGE_TO_FILE) != 0 {
            fs::create_dir_all(&target_folder)?;
            let thumb = create_thumbnail(&img, settings.thumbnail_width, settings.thumbnail_height);
            let stem = Path::new(&file_name)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("capture");
            let thumb_name = format!("{stem}{}.{ext}", settings.thumbnail_name_suffix);
            let thumb_path = target_folder.join(thumb_name);
            let thumb_bytes =
                encode_rgba_image(&thumb, settings.image_format, settings.jpeg_quality)?;
            fs::write(&thumb_path, thumb_bytes)?;
            report.saved_thumbnail_path = Some(thumb_path.to_string_lossy().to_string());
        }

        // External CLI actions (`AfterCaptureTasks.PerformActions`)
        let mut active_bytes = encoded_bytes;
        if (flags & after_capture_flags::PERFORM_ACTIONS) != 0
            && let Some(ref saved) = report.saved_file_path
        {
            let mut current_path = PathBuf::from(saved);
            for action in settings.external_actions.iter().filter(|a| a.enabled) {
                match run_external_action(action, &current_path) {
                    Ok(Some(new_path)) if new_path.exists() => {
                        current_path = new_path;
                        report.saved_file_path = Some(current_path.to_string_lossy().to_string());
                        if let Ok(b) = fs::read(&current_path) {
                            active_bytes = b;
                        }
                    }
                    Ok(_) => {}
                    Err(e) => report
                        .warnings
                        .push(format!("External action '{}' failed: {e}", action.name)),
                }
            }
        }

        if let Some(ref saved_path) = report.saved_file_path {
            if (flags & after_capture_flags::COPY_FILE_TO_CLIPBOARD) != 0 {
                report.copy_file_to_clipboard = true;
            } else if (flags & after_capture_flags::COPY_FILE_PATH_TO_CLIPBOARD) != 0 {
                report.clipboard_text_to_copy = Some(saved_path.clone());
            } else if (flags & after_capture_flags::COPY_FOLDER_PATH_TO_CLIPBOARD) != 0
                && let Some(parent) = Path::new(saved_path).parent()
            {
                report.clipboard_text_to_copy = Some(parent.to_string_lossy().to_string());
            }

            if (flags & after_capture_flags::SHOW_IN_EXPLORER) != 0 {
                report.reveal_in_finder_path = Some(saved_path.clone());
            }
        }

        if (flags & after_capture_flags::UPLOAD_IMAGE_TO_HOST) != 0 {
            let custom_up = self.find_selected_custom_uploader(settings)?;
            let up_res = self
                .uploader
                .upload_image(
                    settings,
                    &report.file_name,
                    &active_bytes,
                    creds,
                    custom_up.as_ref(),
                )
                .await?;

            self.apply_after_upload_tasks(settings, &up_res, &mut report);
            report.upload_result = Some(up_res);
        }

        if (flags & after_capture_flags::DELETE_FILE) != 0
            && let Some(ref saved_path) = report.saved_file_path
        {
            let _ = fs::remove_file(saved_path);
        }

        // Persist in SQLite `History` table
        let mut tags = HashMap::new();
        if let Some(wt) = final_meta.window_title {
            tags.insert("WindowTitle".to_string(), wt);
        }
        if let Some(pn) = final_meta.process_name {
            tags.insert("ProcessName".to_string(), pn);
        }
        tags.insert(
            "Dimensions".to_string(),
            format!("{}x{}", final_meta.width, final_meta.height),
        );

        let up = report.upload_result.as_ref();
        let mut hist = HistoryItem {
            id: 0,
            file_name: report.file_name.clone(),
            file_path: report.saved_file_path.clone().unwrap_or_default(),
            date_time: Utc::now(),
            item_type: "Image".to_string(),
            host: up.map(|u| u.host.clone()).unwrap_or_default(),
            url: up.map(|u| u.url.clone()).unwrap_or_default(),
            thumbnail_url: up.map(|u| u.thumbnail_url.clone()).unwrap_or_default(),
            deletion_url: up.map(|u| u.deletion_url.clone()).unwrap_or_default(),
            shortened_url: up.map(|u| u.shortened_url.clone()).unwrap_or_default(),
            tags,
        };
        self.storage.append_history(&mut hist)?;
        report.history_item = Some(hist);

        Ok(report)
    }

    /// Records a completed native video/GIF screen recording and executes optional file upload + after-upload tasks.
    pub async fn finalize_recording_workflow(
        &self,
        recorded_file_path: &str,
        is_gif: bool,
        settings: &TaskSettings,
        creds: &ResolvedCredentials,
    ) -> CoreResult<WorkflowExecutionReport> {
        let src_path = Path::new(recorded_file_path);
        if !src_path.exists() {
            return Err(CoreError::InvalidConfig(format!(
                "Recorded file does not exist: {recorded_file_path}"
            )));
        }
        let file_name = src_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(if is_gif { "recording.gif" } else { "recording.mp4" })
            .to_string();

        let mut report = WorkflowExecutionReport {
            file_name: file_name.clone(),
            saved_file_path: Some(recorded_file_path.to_string()),
            ..Default::default()
        };

        let flags = settings.after_capture_tasks;
        if (flags & after_capture_flags::COPY_FILE_TO_CLIPBOARD) != 0 {
            report.copy_file_to_clipboard = true;
        } else if (flags & after_capture_flags::COPY_FILE_PATH_TO_CLIPBOARD) != 0 {
            report.clipboard_text_to_copy = Some(recorded_file_path.to_string());
        }
        if (flags & after_capture_flags::SHOW_IN_EXPLORER) != 0 {
            report.reveal_in_finder_path = Some(recorded_file_path.to_string());
        }

        if (flags & after_capture_flags::UPLOAD_IMAGE_TO_HOST) != 0 {
            let bytes = fs::read(src_path)?;
            let custom_up = self.find_selected_custom_uploader(settings)?;
            let up_res = self
                .uploader
                .upload_file(settings, &file_name, &bytes, creds, custom_up.as_ref())
                .await?;
            self.apply_after_upload_tasks(settings, &up_res, &mut report);
            report.upload_result = Some(up_res);
        }

        let up = report.upload_result.as_ref();
        let mut hist = HistoryItem {
            id: 0,
            file_name,
            file_path: recorded_file_path.to_string(),
            date_time: Utc::now(),
            item_type: if is_gif {
                "Image".to_string()
            } else {
                "Video".to_string()
            },
            host: up.map(|u| u.host.clone()).unwrap_or_default(),
            url: up.map(|u| u.url.clone()).unwrap_or_default(),
            thumbnail_url: up.map(|u| u.thumbnail_url.clone()).unwrap_or_default(),
            deletion_url: up.map(|u| u.deletion_url.clone()).unwrap_or_default(),
            shortened_url: up.map(|u| u.shortened_url.clone()).unwrap_or_default(),
            tags: HashMap::new(),
        };
        self.storage.append_history(&mut hist)?;
        report.history_item = Some(hist);

        Ok(report)
    }

    pub async fn upload_text_workflow(
        &self,
        text: &str,
        settings: &TaskSettings,
        creds: &ResolvedCredentials,
    ) -> CoreResult<WorkflowExecutionReport> {
        let meta = CaptureMetadata::default();
        let file_name = self.format_capture_filename(settings, &meta, "txt")?;
        let custom_up = self.find_selected_custom_uploader(settings)?;
        let up_res = self
            .uploader
            .upload_text(settings, &file_name, text, creds, custom_up.as_ref())
            .await?;

        let mut report = WorkflowExecutionReport {
            file_name: file_name.clone(),
            ..Default::default()
        };
        self.apply_after_upload_tasks(settings, &up_res, &mut report);

        let mut hist = HistoryItem {
            id: 0,
            file_name,
            file_path: String::new(),
            date_time: Utc::now(),
            item_type: "Text".to_string(),
            host: up_res.host.clone(),
            url: up_res.url.clone(),
            thumbnail_url: up_res.thumbnail_url.clone(),
            deletion_url: up_res.deletion_url.clone(),
            shortened_url: up_res.shortened_url.clone(),
            tags: HashMap::new(),
        };
        self.storage.append_history(&mut hist)?;
        report.upload_result = Some(up_res);
        report.history_item = Some(hist);
        Ok(report)
    }

    pub async fn upload_file_workflow(
        &self,
        file_path: &str,
        settings: &TaskSettings,
        creds: &ResolvedCredentials,
    ) -> CoreResult<WorkflowExecutionReport> {
        let path = Path::new(file_path);
        let file_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("upload.bin")
            .to_string();
        let bytes = fs::read(path)?;
        let custom_up = self.find_selected_custom_uploader(settings)?;
        let up_res = self
            .uploader
            .upload_file(settings, &file_name, &bytes, creds, custom_up.as_ref())
            .await?;

        let mut report = WorkflowExecutionReport {
            file_name: file_name.clone(),
            saved_file_path: Some(file_path.to_string()),
            ..Default::default()
        };
        self.apply_after_upload_tasks(settings, &up_res, &mut report);

        let mut hist = HistoryItem {
            id: 0,
            file_name,
            file_path: file_path.to_string(),
            date_time: Utc::now(),
            item_type: "File".to_string(),
            host: up_res.host.clone(),
            url: up_res.url.clone(),
            thumbnail_url: up_res.thumbnail_url.clone(),
            deletion_url: up_res.deletion_url.clone(),
            shortened_url: up_res.shortened_url.clone(),
            tags: HashMap::new(),
        };
        self.storage.append_history(&mut hist)?;
        report.upload_result = Some(up_res);
        report.history_item = Some(hist);
        Ok(report)
    }

    fn find_selected_custom_uploader(
        &self,
        settings: &TaskSettings,
    ) -> CoreResult<Option<CustomUploaderItem>> {
        let list = self.storage.list_custom_uploaders()?;
        if let Some(ref name) = settings.custom_uploader_name {
            if let Some(found) = list
                .iter()
                .find(|u| u.display_name().eq_ignore_ascii_case(name))
            {
                return Ok(Some(found.clone()));
            }
        }
        Ok(list.into_iter().next())
    }

    fn apply_after_upload_tasks(
        &self,
        settings: &TaskSettings,
        up_res: &UploadResult,
        report: &mut WorkflowExecutionReport,
    ) {
        if up_res.is_error() || up_res.primary_url().is_empty() {
            for err in &up_res.errors {
                report.warnings.push(err.clone());
            }
            return;
        }
        let uflags = settings.after_upload_tasks;

        if (uflags & after_upload_flags::COPY_URL_TO_CLIPBOARD) != 0 {
            let formatted = if !settings.clipboard_content_format.trim().is_empty() {
                UploadInfoParser::parse(
                    &settings.clipboard_content_format,
                    Some(up_res),
                    &report.file_name,
                    report.saved_file_path.as_deref(),
                    report.saved_thumbnail_path.as_deref(),
                )
            } else {
                up_res.primary_url().to_string()
            };
            if !formatted.is_empty() {
                report.clipboard_text_to_copy = Some(formatted);
            }
        }

        if (uflags & after_upload_flags::OPEN_URL) != 0 {
            let url_to_open = if !settings.open_url_format.trim().is_empty() {
                UploadInfoParser::parse(
                    &settings.open_url_format,
                    Some(up_res),
                    &report.file_name,
                    report.saved_file_path.as_deref(),
                    report.saved_thumbnail_path.as_deref(),
                )
            } else if !up_res.share_url.is_empty() {
                up_res.share_url.clone()
            } else {
                up_res.primary_url().to_string()
            };
            report.open_url = Some(url_to_open);
        } else if !up_res.share_url.is_empty() && (uflags & after_upload_flags::SHARE_URL) != 0 {
            report.open_url = Some(up_res.share_url.clone());
        }

        if (uflags & after_upload_flags::SHOW_QR_CODE) != 0 {
            report.show_qr_for_url = Some(up_res.primary_url().to_string());
        }
    }
}

fn resolve_target_path(folder: &Path, file_name: &str, policy: FileExistAction) -> Option<PathBuf> {
    let candidate = folder.join(file_name);
    if !candidate.exists() {
        return Some(candidate);
    }
    match policy {
        FileExistAction::Overwrite => Some(candidate),
        FileExistAction::Cancel => None,
        FileExistAction::UniqueName => {
            let stem = Path::new(file_name)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("capture");
            let ext = Path::new(file_name)
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            for idx in 2..10_000 {
                let next_name = if ext.is_empty() {
                    format!("{stem}_{idx}")
                } else {
                    format!("{stem}_{idx}.{ext}")
                };
                let next_path = folder.join(next_name);
                if !next_path.exists() {
                    return Some(next_path);
                }
            }
            Some(candidate)
        }
    }
}

fn run_external_action(
    action: &crate::models::ExternalProgramAction,
    input_path: &Path,
) -> CoreResult<Option<PathBuf>> {
    let input_str = input_path.to_string_lossy().to_string();
    let output_path = action.output_extension.as_ref().map(|ext| {
        let mut p = input_path.to_path_buf();
        p.set_extension(ext.trim_start_matches('.'));
        p
    });
    let output_str = output_path
        .as_ref()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| input_str.clone());

    let expanded = action
        .args_template
        .replace("%input", &input_str)
        .replace("%output", &output_str);
    let args: Vec<&str> = expanded.split_whitespace().collect();

    let status = Command::new(&action.path).args(&args).status()?;
    if !status.success() {
        return Err(CoreError::InvalidConfig(format!(
            "Process exited with {status}"
        )));
    }
    Ok(output_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    #[tokio::test]
    async fn executes_end_to_end_image_workflow_with_beautifier_save_and_sqlite_history() {
        let dir = std::env::temp_dir().join(format!("sharaza_wf_{}", uuid::Uuid::new_v4()));
        let engine = SharazaEngine::open(&dir).unwrap();

        let img = RgbaImage::from_pixel(160, 100, Rgba([30, 144, 255, 255]));
        let png = encode_rgba_image(&img, crate::models::ImageFormat::PNG, 100).unwrap();

        let mut settings = TaskSettings::default();
        settings.screenshots_folder = dir.join("Captures").to_string_lossy().to_string();
        settings.sub_folder_pattern = "".to_string();
        settings.name_pattern = "test_%i{3}".to_string();
        settings.after_capture_tasks = after_capture_flags::BEAUTIFY_IMAGE
            | after_capture_flags::COPY_IMAGE_TO_CLIPBOARD
            | after_capture_flags::SAVE_IMAGE_TO_FILE
            | after_capture_flags::SAVE_THUMBNAIL_IMAGE_TO_FILE;

        let meta = CaptureMetadata {
            window_title: Some("Terminal — zsh".to_string()),
            process_name: None,
            width: 160,
            height: 100,
        };

        let report = engine
            .execute_image_workflow(&png, meta, &settings, &ResolvedCredentials::default())
            .await
            .unwrap();

        assert!(report.copy_image_to_clipboard);
        let saved = PathBuf::from(report.saved_file_path.as_ref().unwrap());
        assert!(saved.exists());
        assert!(PathBuf::from(report.saved_thumbnail_path.as_ref().unwrap()).exists());

        // Verify UniqueName collision resolution on second run with same pattern
        settings.name_pattern = "fixed_name".to_string();
        let r1 = engine
            .execute_image_workflow(
                &png,
                CaptureMetadata::default(),
                &settings,
                &ResolvedCredentials::default(),
            )
            .await
            .unwrap();
        let r2 = engine
            .execute_image_workflow(
                &png,
                CaptureMetadata::default(),
                &settings,
                &ResolvedCredentials::default(),
            )
            .await
            .unwrap();
        assert!(r1.saved_file_path.unwrap().ends_with("fixed_name.png"));
        assert!(r2.saved_file_path.unwrap().ends_with("fixed_name_2.png"));

        let hist = engine
            .storage
            .query_history(&crate::models::HistoryFilter::default())
            .unwrap();
        assert_eq!(hist.len(), 3);

        let _ = fs::remove_dir_all(&dir);
    }
}

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Bitflags matching `ShareX.AfterCaptureTasks` (`ShareX/Enums.cs` lines 140-166).
pub mod after_capture_flags {
    pub const NONE: u32 = 0;
    pub const SHOW_QUICK_TASK_MENU: u32 = 1 << 0;
    pub const SHOW_AFTER_CAPTURE_WINDOW: u32 = 1 << 1;
    pub const BEAUTIFY_IMAGE: u32 = 1 << 2;
    pub const ADD_IMAGE_EFFECTS: u32 = 1 << 3;
    pub const ANNOTATE_IMAGE: u32 = 1 << 4;
    pub const OPEN_IN_PHOTO_EDITOR: u32 = 1 << 5;
    pub const COPY_IMAGE_TO_CLIPBOARD: u32 = 1 << 6;
    pub const PIN_TO_SCREEN: u32 = 1 << 7;
    pub const SEND_IMAGE_TO_PRINTER: u32 = 1 << 8;
    pub const SAVE_IMAGE_TO_FILE: u32 = 1 << 9;
    pub const SAVE_IMAGE_TO_FILE_WITH_DIALOG: u32 = 1 << 10;
    pub const SAVE_THUMBNAIL_IMAGE_TO_FILE: u32 = 1 << 11;
    pub const PERFORM_ACTIONS: u32 = 1 << 12;
    pub const COPY_FILE_TO_CLIPBOARD: u32 = 1 << 13;
    pub const COPY_FILE_PATH_TO_CLIPBOARD: u32 = 1 << 14;
    pub const COPY_FOLDER_PATH_TO_CLIPBOARD: u32 = 1 << 15;
    pub const SHOW_IN_EXPLORER: u32 = 1 << 16;
    pub const ANALYZE_IMAGE: u32 = 1 << 17;
    pub const SCAN_QR_CODE: u32 = 1 << 18;
    pub const DO_OCR: u32 = 1 << 19;
    pub const SHOW_BEFORE_UPLOAD_WINDOW: u32 = 1 << 20;
    pub const UPLOAD_IMAGE_TO_HOST: u32 = 1 << 21;
    pub const DELETE_FILE: u32 = 1 << 22;
}

/// Bitflags matching `ShareX.AfterUploadTasks` (`ShareX/Enums.cs` lines 169-178).
pub mod after_upload_flags {
    pub const NONE: u32 = 0;
    pub const SHOW_AFTER_UPLOAD_WINDOW: u32 = 1 << 0;
    pub const USE_URL_SHORTENER: u32 = 1 << 1;
    pub const SHARE_URL: u32 = 1 << 2;
    pub const COPY_URL_TO_CLIPBOARD: u32 = 1 << 3;
    pub const OPEN_URL: u32 = 1 << 4;
    pub const SHOW_QR_CODE: u32 = 1 << 5;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CaptureType {
    Fullscreen,
    ActiveMonitor,
    Monitor,
    Window,
    ActiveWindow,
    Region,
    LastRegion,
    ScrollingCapture,
    ScreenRecordingMp4,
    ScreenRecordingGif,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImageFormat {
    PNG,
    JPEG,
    WEBP,
    GIF,
    BMP,
}

impl ImageFormat {
    pub fn extension(self) -> &'static str {
        match self {
            ImageFormat::PNG => "png",
            ImageFormat::JPEG => "jpg",
            ImageFormat::WEBP => "webp",
            ImageFormat::GIF => "gif",
            ImageFormat::BMP => "bmp",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileExistAction {
    Overwrite,
    UniqueName,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BuiltinImageUploader {
    Imgur,
    VgyMe,
    Catbox,
    ZeroXZero,
    CustomImageUploader,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BuiltinTextUploader {
    Pastebin,
    GitHubGist,
    ZeroXZero,
    CustomTextUploader,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BuiltinFileUploader {
    Dropbox,
    NextcloudWebDav,
    Catbox,
    ZeroXZero,
    TempSh,
    S3PresignedPut,
    CustomFileUploader,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BuiltinUrlShortener {
    IsGd,
    VGd,
    TinyUrl,
    Bitly,
    CustomUrlShortener,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UrlSharingService {
    Email,
    Reddit,
    LinkedIn,
    Pinterest,
    GoogleImageSearch,
    BingVisualSearch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkFormat {
    Url,
    ShortenedUrl,
    MarkdownLink,
    MarkdownImage,
    MarkdownLinkedImage,
    HtmlLink,
    HtmlImage,
    HtmlLinkedImage,
    ForumLink,
    ForumImage,
    ForumLinkedImage,
    WikiImage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageEffectsConfig {
    pub beautify_padding: u32,
    pub beautify_corner_radius: u32,
    pub beautify_shadow_radius: u32,
    pub beautify_shadow_opacity: f32,
    pub beautify_bg_start_rgba: [u8; 4],
    pub beautify_bg_end_rgba: [u8; 4],
    pub border_size: u32,
    pub border_inside: bool,
    pub border_rgba: [u8; 4],
    pub watermark_text: String,
    pub resize_scale_percent: u32,
}

impl Default for ImageEffectsConfig {
    fn default() -> Self {
        Self {
            beautify_padding: 40,
            beautify_corner_radius: 14,
            beautify_shadow_radius: 18,
            beautify_shadow_opacity: 0.42,
            beautify_bg_start_rgba: [79, 70, 229, 255],
            beautify_bg_end_rgba: [14, 165, 233, 255],
            border_size: 0,
            border_inside: false,
            border_rgba: [255, 255, 255, 220],
            watermark_text: String::new(),
            resize_scale_percent: 100,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalProgramAction {
    pub name: String,
    pub path: String,
    pub args_template: String, // Supports %input and %output like ShareX ExternalProgram
    pub output_extension: Option<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskSettings {
    pub description: String,
    pub capture_type: CaptureType,
    pub after_capture_tasks: u32,
    pub after_upload_tasks: u32,
    pub screenshot_delay_ms: u64,
    pub capture_cursor: bool,
    pub capture_shadow: bool,
    pub capture_transparent: bool,
    pub screenshots_folder: String,
    pub sub_folder_pattern: String,
    pub name_pattern: String,
    pub name_pattern_window: String,
    pub max_name_length: usize,
    pub max_title_length: usize,
    pub image_format: ImageFormat,
    pub jpeg_quality: u8,
    pub file_exist_action: FileExistAction,
    pub thumbnail_width: u32,
    pub thumbnail_height: u32,
    pub thumbnail_name_suffix: String,
    pub image_effects: ImageEffectsConfig,
    pub image_uploader: BuiltinImageUploader,
    pub text_uploader: BuiltinTextUploader,
    pub file_uploader: BuiltinFileUploader,
    pub url_shortener: BuiltinUrlShortener,
    pub url_sharing_service: UrlSharingService,
    pub custom_uploader_name: Option<String>,
    pub result_force_https: bool,
    pub url_regex_replace_enabled: bool,
    pub url_regex_pattern: String,
    pub url_regex_replacement: String,
    pub auto_shorten_url_length: usize,
    pub clipboard_content_format: String,
    pub open_url_format: String,
    pub max_upload_retries: u32,
    pub recording_fps: u32,
    pub recording_gif_fps: u32,
    pub recording_bitrate: u32,
    pub recording_system_audio: bool,
    pub recording_microphone: bool,
    pub show_toast_notification: bool,
    pub play_sound_after_capture: bool,
    pub external_actions: Vec<ExternalProgramAction>,
}

impl Default for TaskSettings {
    fn default() -> Self {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        Self {
            description: "Default Workflow".to_string(),
            capture_type: CaptureType::Region,
            after_capture_tasks: after_capture_flags::COPY_IMAGE_TO_CLIPBOARD
                | after_capture_flags::SAVE_IMAGE_TO_FILE,
            after_upload_tasks: after_upload_flags::COPY_URL_TO_CLIPBOARD,
            screenshot_delay_ms: 0,
            capture_cursor: false,
            capture_shadow: true,
            capture_transparent: true,
            screenshots_folder: format!("{home}/Pictures/Sharaza"),
            sub_folder_pattern: "%y-%mo".to_string(),
            name_pattern: "%y-%mo-%d_%h-%mi-%s_%ra{4}".to_string(),
            name_pattern_window: "%pn_%y-%mo-%d_%h-%mi-%s".to_string(),
            max_name_length: 100,
            max_title_length: 50,
            image_format: ImageFormat::PNG,
            jpeg_quality: 90,
            file_exist_action: FileExistAction::UniqueName,
            thumbnail_width: 240,
            thumbnail_height: 0,
            thumbnail_name_suffix: "-thumb".to_string(),
            image_effects: ImageEffectsConfig::default(),
            image_uploader: BuiltinImageUploader::Imgur,
            text_uploader: BuiltinTextUploader::GitHubGist,
            file_uploader: BuiltinFileUploader::ZeroXZero,
            url_shortener: BuiltinUrlShortener::IsGd,
            url_sharing_service: UrlSharingService::Reddit,
            custom_uploader_name: None,
            result_force_https: false,
            url_regex_replace_enabled: false,
            url_regex_pattern: String::new(),
            url_regex_replacement: String::new(),
            auto_shorten_url_length: 0,
            clipboard_content_format: String::new(),
            open_url_format: String::new(),
            max_upload_retries: 1,
            recording_fps: 30,
            recording_gif_fps: 15,
            recording_bitrate: 8_000_000,
            recording_system_audio: true,
            recording_microphone: false,
            show_toast_notification: true,
            play_sound_after_capture: true,
            external_actions: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HotkeyBinding {
    pub id: String,
    pub action: String,
    pub key_code: u32,
    pub modifiers: u32, // Carbon modifiers: cmd=0x0100, shift=0x0200, option=0x0800, ctrl=0x1000
    pub display_shortcut: String,
    pub enabled: bool,
    pub workflow_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowPreset {
    pub id: String,
    pub name: String,
    pub settings: TaskSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub default_settings: TaskSettings,
    pub hotkeys_enabled: bool,
    pub hotkeys: Vec<HotkeyBinding>,
    pub remember_last_region: bool,
    pub last_region: Option<[i32; 4]>, // [x, y, width, height]
    pub launch_in_menu_bar: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            default_settings: TaskSettings::default(),
            hotkeys_enabled: true,
            hotkeys: vec![
                HotkeyBinding {
                    id: "capture_region".to_string(),
                    action: "CaptureRegion".to_string(),
                    key_code: 0x15, // kVK_ANSI_4
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧4".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
                HotkeyBinding {
                    id: "capture_fullscreen".to_string(),
                    action: "CaptureFullscreen".to_string(),
                    key_code: 0x14, // kVK_ANSI_3
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧3".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
                HotkeyBinding {
                    id: "capture_window".to_string(),
                    action: "CaptureActiveWindow".to_string(),
                    key_code: 0x13, // kVK_ANSI_2
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧2".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
                HotkeyBinding {
                    id: "screen_record".to_string(),
                    action: "ToggleScreenRecording".to_string(),
                    key_code: 0x17, // kVK_ANSI_5
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧5".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
                HotkeyBinding {
                    id: "ocr_region".to_string(),
                    action: "OCRRegion".to_string(),
                    key_code: 0x1F, // kVK_ANSI_O
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧O".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
                HotkeyBinding {
                    id: "color_picker".to_string(),
                    action: "ScreenColorPicker".to_string(),
                    key_code: 0x08, // kVK_ANSI_C
                    modifiers: 0x1000 | 0x0200, // Ctrl + Shift
                    display_shortcut: "⌃⇧C".to_string(),
                    enabled: true,
                    workflow_id: None,
                },
            ],
            remember_last_region: true,
            last_region: None,
            launch_in_menu_bar: true,
        }
    }
}

/// Exact structural match for `ShareX.HistoryLib.HistoryItem` (`HistoryManagerSQLite.cs`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryItem {
    pub id: i64,
    pub file_name: String,
    pub file_path: String,
    pub date_time: DateTime<Utc>,
    pub item_type: String,
    pub host: String,
    pub url: String,
    pub thumbnail_url: String,
    pub deletion_url: String,
    pub shortened_url: String,
    pub tags: HashMap<String, String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HistoryFilter {
    pub search_query: Option<String>,
    pub item_type: Option<String>,
    pub host: Option<String>,
    pub limit: usize,
    pub offset: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HistoryStats {
    pub total_count: usize,
    pub image_count: usize,
    pub video_count: usize,
    pub text_count: usize,
    pub file_count: usize,
    pub uploaded_count: usize,
    pub by_host: HashMap<String, usize>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CaptureMetadata {
    pub window_title: Option<String>,
    pub process_name: Option<String>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UploadResult {
    pub url: String,
    pub thumbnail_url: String,
    pub deletion_url: String,
    pub shortened_url: String,
    pub share_url: String,
    pub host: String,
    pub response_text: String,
    pub upload_duration_ms: u64,
    pub errors: Vec<String>,
}

impl UploadResult {
    pub fn primary_url(&self) -> &str {
        if !self.shortened_url.is_empty() {
            &self.shortened_url
        } else {
            &self.url
        }
    }

    pub fn is_error(&self) -> bool {
        !self.errors.is_empty()
    }
}

/// Credentials resolved at execution time from macOS Keychain (`Security.framework`) — never persisted to disk in plaintext.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolvedCredentials {
    pub imgur_client_id: Option<String>,
    pub imgur_bearer_token: Option<String>,
    pub vgyme_user_key: Option<String>,
    pub pastebin_api_dev_key: Option<String>,
    pub pastebin_api_user_key: Option<String>,
    pub github_gist_token: Option<String>,
    pub github_gist_public: bool,
    pub bitly_access_token: Option<String>,
    pub dropbox_access_token: Option<String>,
    pub nextcloud_webdav_url: Option<String>,
    pub nextcloud_username: Option<String>,
    pub nextcloud_password: Option<String>,
    pub s3_presigned_url: Option<String>,
    pub s3_public_base_url: Option<String>,
    pub custom_headers: HashMap<String, String>,
    pub custom_parameters: HashMap<String, String>,
}

/// Result returned to SwiftUI/AppKit after `SharazaEngine` completes the Rust core portion of a capture/file/text workflow.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WorkflowExecutionReport {
    pub file_name: String,
    pub saved_file_path: Option<String>,
    pub saved_thumbnail_path: Option<String>,
    pub processed_png_bytes_base64: Option<String>,
    pub copy_image_to_clipboard: bool,
    pub copy_file_to_clipboard: bool,
    pub clipboard_text_to_copy: Option<String>,
    pub reveal_in_finder_path: Option<String>,
    pub open_url: Option<String>,
    pub pin_to_screen: bool,
    pub run_ocr: bool,
    pub scan_qr: bool,
    pub show_qr_for_url: Option<String>,
    pub upload_result: Option<UploadResult>,
    pub history_item: Option<HistoryItem>,
    pub warnings: Vec<String>,
}

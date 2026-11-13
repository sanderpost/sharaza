import Foundation

/// Bitflags matching `sharaza_core::models::after_capture_flags` and `ShareX.AfterCaptureTasks`.
public struct AfterCaptureFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let showQuickTaskMenu       = AfterCaptureFlags(rawValue: 1 << 0)
    public static let showAfterCaptureWindow  = AfterCaptureFlags(rawValue: 1 << 1)
    public static let beautifyImage           = AfterCaptureFlags(rawValue: 1 << 2)
    public static let addImageEffects         = AfterCaptureFlags(rawValue: 1 << 3)
    public static let annotateImage           = AfterCaptureFlags(rawValue: 1 << 4)
    public static let openInPhotoEditor       = AfterCaptureFlags(rawValue: 1 << 5)
    public static let copyImageToClipboard    = AfterCaptureFlags(rawValue: 1 << 6)
    public static let pinToScreen             = AfterCaptureFlags(rawValue: 1 << 7)
    public static let sendImageToPrinter      = AfterCaptureFlags(rawValue: 1 << 8)
    public static let saveImageToFile         = AfterCaptureFlags(rawValue: 1 << 9)
    public static let saveImageWithDialog     = AfterCaptureFlags(rawValue: 1 << 10)
    public static let saveThumbnailToFile     = AfterCaptureFlags(rawValue: 1 << 11)
    public static let performActions          = AfterCaptureFlags(rawValue: 1 << 12)
    public static let copyFileToClipboard     = AfterCaptureFlags(rawValue: 1 << 13)
    public static let copyFilePathToClipboard = AfterCaptureFlags(rawValue: 1 << 14)
    public static let copyFolderPath          = AfterCaptureFlags(rawValue: 1 << 15)
    public static let showInFinder            = AfterCaptureFlags(rawValue: 1 << 16)
    public static let analyzeImage            = AfterCaptureFlags(rawValue: 1 << 17)
    public static let scanQRCode              = AfterCaptureFlags(rawValue: 1 << 18)
    public static let doOCR                   = AfterCaptureFlags(rawValue: 1 << 19)
    public static let showBeforeUploadWindow  = AfterCaptureFlags(rawValue: 1 << 20)
    public static let uploadImageToHost       = AfterCaptureFlags(rawValue: 1 << 21)
    public static let deleteFile              = AfterCaptureFlags(rawValue: 1 << 22)
}

/// Bitflags matching `sharaza_core::models::after_upload_flags` and `ShareX.AfterUploadTasks`.
public struct AfterUploadFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let showAfterUploadWindow = AfterUploadFlags(rawValue: 1 << 0)
    public static let useURLShortener       = AfterUploadFlags(rawValue: 1 << 1)
    public static let shareURL              = AfterUploadFlags(rawValue: 1 << 2)
    public static let copyURLToClipboard    = AfterUploadFlags(rawValue: 1 << 3)
    public static let openURL               = AfterUploadFlags(rawValue: 1 << 4)
    public static let showQRCode            = AfterUploadFlags(rawValue: 1 << 5)
}

public enum CaptureType: String, Codable, CaseIterable, Sendable, Identifiable {
    case Fullscreen
    case ActiveMonitor
    case Monitor
    case Window
    case ActiveWindow
    case Region
    case LastRegion
    case ScrollingCapture
    case ScreenRecordingMp4
    case ScreenRecordingGif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .Fullscreen: return "Capture Fullscreen"
        case .ActiveMonitor: return "Capture Active Monitor"
        case .Monitor: return "Capture Specific Monitor"
        case .Window: return "Capture Window…"
        case .ActiveWindow: return "Capture Active Window"
        case .Region: return "Capture Region"
        case .LastRegion: return "Capture Last Region"
        case .ScrollingCapture: return "Scrolling Capture"
        case .ScreenRecordingMp4: return "Record Screen (MP4)"
        case .ScreenRecordingGif: return "Record Screen (GIF)"
        }
    }
}

public enum ImageFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case PNG, JPEG, WEBP, GIF, BMP
    public var id: String { rawValue }
}

public enum FileExistAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case UniqueName, Overwrite, Cancel
    public var id: String { rawValue }
}

public enum BuiltinImageUploader: String, Codable, CaseIterable, Sendable, Identifiable {
    case Imgur, VgyMe, Catbox, ZeroXZero, CustomImageUploader
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .Imgur: return "Imgur"
        case .VgyMe: return "vgy.me"
        case .Catbox: return "catbox.moe"
        case .ZeroXZero: return "0x0.st"
        case .CustomImageUploader: return "Custom Uploader (.sxcu)"
        }
    }
}

public enum BuiltinTextUploader: String, Codable, CaseIterable, Sendable, Identifiable {
    case Pastebin, GitHubGist, ZeroXZero, CustomTextUploader
    public var id: String { rawValue }
}

public enum BuiltinFileUploader: String, Codable, CaseIterable, Sendable, Identifiable {
    case Dropbox, NextcloudWebDav, Catbox, ZeroXZero, TempSh, S3PresignedPut, CustomFileUploader
    public var id: String { rawValue }
}

public enum BuiltinUrlShortener: String, Codable, CaseIterable, Sendable, Identifiable {
    case IsGd, VGd, TinyUrl, Bitly, CustomUrlShortener
    public var id: String { rawValue }
}

public enum UrlSharingService: String, Codable, CaseIterable, Sendable, Identifiable {
    case Email, Reddit, LinkedIn, Pinterest, GoogleImageSearch, BingVisualSearch
    public var id: String { rawValue }
}

public enum LinkFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case Url, ShortenedUrl, MarkdownLink, MarkdownImage, MarkdownLinkedImage
    case HtmlLink, HtmlImage, HtmlLinkedImage, ForumLink, ForumImage, ForumLinkedImage, WikiImage
    public var id: String { rawValue }
}

public struct ImageEffectsConfig: Codable, Sendable, Equatable {
    public var beautify_padding: UInt32
    public var beautify_corner_radius: UInt32
    public var beautify_shadow_radius: UInt32
    public var beautify_shadow_opacity: Float
    public var beautify_bg_start_rgba: [UInt8]
    public var beautify_bg_end_rgba: [UInt8]
    public var border_size: UInt32
    public var border_inside: Bool
    public var border_rgba: [UInt8]
    public var watermark_text: String
    public var resize_scale_percent: UInt32

    public init(
        beautify_padding: UInt32 = 40,
        beautify_corner_radius: UInt32 = 14,
        beautify_shadow_radius: UInt32 = 18,
        beautify_shadow_opacity: Float = 0.42,
        beautify_bg_start_rgba: [UInt8] = [79, 70, 229, 255],
        beautify_bg_end_rgba: [UInt8] = [14, 165, 233, 255],
        border_size: UInt32 = 0,
        border_inside: Bool = false,
        border_rgba: [UInt8] = [255, 255, 255, 220],
        watermark_text: String = "",
        resize_scale_percent: UInt32 = 100
    ) {
        self.beautify_padding = beautify_padding
        self.beautify_corner_radius = beautify_corner_radius
        self.beautify_shadow_radius = beautify_shadow_radius
        self.beautify_shadow_opacity = beautify_shadow_opacity
        self.beautify_bg_start_rgba = beautify_bg_start_rgba
        self.beautify_bg_end_rgba = beautify_bg_end_rgba
        self.border_size = border_size
        self.border_inside = border_inside
        self.border_rgba = border_rgba
        self.watermark_text = watermark_text
        self.resize_scale_percent = resize_scale_percent
    }
}

public struct ExternalProgramAction: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var path: String
    public var args_template: String
    public var output_extension: String?
    public var enabled: Bool
}

public struct TaskSettings: Codable, Sendable, Equatable {
    public var description: String
    public var capture_type: CaptureType
    public var after_capture_tasks: UInt32
    public var after_upload_tasks: UInt32
    public var screenshot_delay_ms: UInt64
    public var capture_cursor: Bool
    public var capture_shadow: Bool
    public var capture_transparent: Bool
    public var screenshots_folder: String
    public var sub_folder_pattern: String
    public var name_pattern: String
    public var name_pattern_window: String
    public var max_name_length: Int
    public var max_title_length: Int
    public var image_format: ImageFormat
    public var jpeg_quality: UInt8
    public var file_exist_action: FileExistAction
    public var thumbnail_width: UInt32
    public var thumbnail_height: UInt32
    public var thumbnail_name_suffix: String
    public var image_effects: ImageEffectsConfig
    public var image_uploader: BuiltinImageUploader
    public var text_uploader: BuiltinTextUploader
    public var file_uploader: BuiltinFileUploader
    public var url_shortener: BuiltinUrlShortener
    public var url_sharing_service: UrlSharingService
    public var custom_uploader_name: String?
    public var result_force_https: Bool
    public var url_regex_replace_enabled: Bool
    public var url_regex_pattern: String
    public var url_regex_replacement: String
    public var auto_shorten_url_length: Int
    public var clipboard_content_format: String
    public var open_url_format: String
    public var max_upload_retries: UInt32
    public var recording_fps: UInt32
    public var recording_gif_fps: UInt32
    public var recording_bitrate: UInt32
    public var recording_system_audio: Bool
    public var recording_microphone: Bool
    public var show_toast_notification: Bool
    public var play_sound_after_capture: Bool
    public var external_actions: [ExternalProgramAction]

    public func hasAfterCapture(_ flag: AfterCaptureFlags) -> Bool {
        (after_capture_tasks & flag.rawValue) != 0
    }

    public mutating func setAfterCapture(_ flag: AfterCaptureFlags, enabled: Bool) {
        if enabled {
            after_capture_tasks |= flag.rawValue
        } else {
            after_capture_tasks &= ~flag.rawValue
        }
    }

    public func hasAfterUpload(_ flag: AfterUploadFlags) -> Bool {
        (after_upload_tasks & flag.rawValue) != 0
    }

    public mutating func setAfterUpload(_ flag: AfterUploadFlags, enabled: Bool) {
        if enabled {
            after_upload_tasks |= flag.rawValue
        } else {
            after_upload_tasks &= ~flag.rawValue
        }
    }
}

public struct HotkeyBinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var action: String
    public var key_code: UInt32
    public var modifiers: UInt32
    public var display_shortcut: String
    public var enabled: Bool
    public var workflow_id: String?
}

public struct WorkflowPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var settings: TaskSettings
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var default_settings: TaskSettings
    public var hotkeys_enabled: Bool
    public var hotkeys: [HotkeyBinding]
    public var remember_last_region: Bool
    public var last_region: [Int32]?
    public var launch_in_menu_bar: Bool
}

public struct HistoryItem: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var file_name: String
    public var file_path: String
    public var date_time: String
    public var item_type: String
    public var host: String
    public var url: String
    public var thumbnail_url: String
    public var deletion_url: String
    public var shortened_url: String
    public var tags: [String: String]

    public var primaryURL: String {
        !shortened_url.isEmpty ? shortened_url : url
    }
}

public struct HistoryFilter: Codable, Sendable {
    public var search_query: String?
    public var item_type: String?
    public var host: String?
    public var limit: Int
    public var offset: Int

    public init(search_query: String? = nil, item_type: String? = nil, host: String? = nil, limit: Int = 200, offset: Int = 0) {
        self.search_query = search_query
        self.item_type = item_type
        self.host = host
        self.limit = limit
        self.offset = offset
    }
}

public struct HistoryStats: Codable, Sendable {
    public var total_count: Int
    public var image_count: Int
    public var video_count: Int
    public var text_count: Int
    public var file_count: Int
    public var uploaded_count: Int
    public var by_host: [String: Int]
}

public struct CaptureMetadata: Codable, Sendable {
    public var window_title: String?
    public var process_name: String?
    public var width: UInt32
    public var height: UInt32

    public init(window_title: String? = nil, process_name: String? = nil, width: UInt32 = 0, height: UInt32 = 0) {
        self.window_title = window_title
        self.process_name = process_name
        self.width = width
        self.height = height
    }
}

public struct UploadResult: Codable, Sendable, Equatable {
    public var url: String
    public var thumbnail_url: String
    public var deletion_url: String
    public var shortened_url: String
    public var share_url: String
    public var host: String
    public var response_text: String
    public var upload_duration_ms: UInt64
    public var errors: [String]

    public var primaryURL: String {
        !shortened_url.isEmpty ? shortened_url : url
    }
}

public struct ResolvedCredentials: Codable, Sendable {
    public var imgur_client_id: String?
    public var imgur_bearer_token: String?
    public var vgyme_user_key: String?
    public var pastebin_api_dev_key: String?
    public var pastebin_api_user_key: String?
    public var github_gist_token: String?
    public var github_gist_public: Bool
    public var bitly_access_token: String?
    public var dropbox_access_token: String?
    public var nextcloud_webdav_url: String?
    public var nextcloud_username: String?
    public var nextcloud_password: String?
    public var s3_presigned_url: String?
    public var s3_public_base_url: String?
    public var custom_headers: [String: String]
    public var custom_parameters: [String: String]

    public init(
        imgur_client_id: String? = nil,
        imgur_bearer_token: String? = nil,
        vgyme_user_key: String? = nil,
        pastebin_api_dev_key: String? = nil,
        pastebin_api_user_key: String? = nil,
        github_gist_token: String? = nil,
        github_gist_public: Bool = false,
        bitly_access_token: String? = nil,
        dropbox_access_token: String? = nil,
        nextcloud_webdav_url: String? = nil,
        nextcloud_username: String? = nil,
        nextcloud_password: String? = nil,
        s3_presigned_url: String? = nil,
        s3_public_base_url: String? = nil,
        custom_headers: [String: String] = [:],
        custom_parameters: [String: String] = [:]
    ) {
        self.imgur_client_id = imgur_client_id
        self.imgur_bearer_token = imgur_bearer_token
        self.vgyme_user_key = vgyme_user_key
        self.pastebin_api_dev_key = pastebin_api_dev_key
        self.pastebin_api_user_key = pastebin_api_user_key
        self.github_gist_token = github_gist_token
        self.github_gist_public = github_gist_public
        self.bitly_access_token = bitly_access_token
        self.dropbox_access_token = dropbox_access_token
        self.nextcloud_webdav_url = nextcloud_webdav_url
        self.nextcloud_username = nextcloud_username
        self.nextcloud_password = nextcloud_password
        self.s3_presigned_url = s3_presigned_url
        self.s3_public_base_url = s3_public_base_url
        self.custom_headers = custom_headers
        self.custom_parameters = custom_parameters
    }
}

public struct WorkflowExecutionReport: Codable, Sendable {
    public var file_name: String
    public var saved_file_path: String?
    public var saved_thumbnail_path: String?
    public var processed_png_bytes_base64: String?
    public var copy_image_to_clipboard: Bool
    public var copy_file_to_clipboard: Bool
    public var clipboard_text_to_copy: String?
    public var reveal_in_finder_path: String?
    public var open_url: String?
    public var pin_to_screen: Bool
    public var run_ocr: Bool
    public var scan_qr: Bool
    public var show_qr_for_url: String?
    public var upload_result: UploadResult?
    public var history_item: HistoryItem?
    public var warnings: [String]
}

public struct CustomUploaderItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { Name.isEmpty ? RequestURL : Name }
    public var Version: String
    public var Name: String
    public var DestinationType: String
    public var RequestMethod: String
    public var RequestURL: String
    public var Parameters: [String: String]
    public var Headers: [String: String]
    public var Body: String
    public var Arguments: [String: String]
    public var FileFormName: String
    public var Data: String
    public var URL: String
    public var ThumbnailURL: String
    public var DeletionURL: String
    public var ErrorMessage: String
}

public struct FileHashes: Codable, Sendable, Equatable {
    public var crc32: String
    public var md5: String
    public var sha1: String
    public var sha256: String
    public var sha384: String
    public var sha512: String
}

public struct ColorFormats: Codable, Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8
    public var hex: String
    public var hex_upper: String
    public var argb_hex: String
    public var rgb_css: String
    public var rgba_css: String
    public var decimal: UInt32
    public var hsb: [Float]
    public var hsl: [Float]
    public var cmyk: [Float]
}

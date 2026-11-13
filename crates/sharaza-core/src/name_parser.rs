use crate::models::{LinkFormat, UploadResult};
use chrono::{DateTime, Datelike, Local, Timelike, Utc};
use percent_encoding::{AsciiSet, CONTROLS, utf8_percent_encode};
use rand::Rng;
use std::fs;
use std::path::Path;
use uuid::Uuid;

/// Exact ShareX character sets (`ShareX.HelpersLib/Helpers.cs`):
/// - Numbers: `0123456789`
/// - Alphanumeric: `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`
/// - AlphanumericInverse: `0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ`
/// - Base56 (unambiguous): `23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz`
/// - Hexadecimal: `0123456789ABCDEF`
const NUMBERS: &[u8] = b"0123456789";
const ALPHANUMERIC: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ALPHANUMERIC_INVERSE: &[u8] =
    b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const BASE56: &[u8] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";
const HEX_LOWER: &[u8] = b"0123456789abcdef";
const HEX_UPPER: &[u8] = b"0123456789ABCDEF";

const ADJECTIVES: &[&str] = &[
    "Agile", "Amber", "Arctic", "Astral", "Bold", "Bright", "Calm", "Clever", "Cobalt", "Cosmic",
    "Crisp", "Crystal", "Daring", "Dazzling", "Eager", "Emerald", "Fierce", "Gentle", "Golden",
    "Grand", "Happy", "Keen", "Lively", "Lucid", "Lunar", "Mellow", "Mighty", "Nimble", "Noble",
    "Plucky", "Proud", "Quick", "Quiet", "Radiant", "Rapid", "Royal", "Serene", "Sharp", "Silent",
    "Silver", "Sleek", "Smart", "Solar", "Steady", "Stellar", "Sunny", "Swift", "Vivid", "Warm",
    "Witty",
];

const ANIMALS: &[&str] = &[
    "Albatross", "Badger", "Beaver", "Bison", "Bobcat", "Condor", "Cougar", "Coyote", "Crane",
    "Dolphin", "Eagle", "Falcon", "Ferret", "Finch", "Fox", "Gazelle", "Gecko", "Heron", "Husky",
    "Ibex", "Jaguar", "Kestrel", "Koala", "Lemur", "Leopard", "Lynx", "Marmot", "Marten", "Meerkat",
    "Narwhal", "Ocelot", "Orca", "Osprey", "Otter", "Owl", "Panda", "Panther", "Pelican", "Penguin",
    "Puffin", "Quokka", "Raven", "RedPanda", "Robin", "Seal", "Sparrow", "Stoat", "Tiger", "Walrus",
    "Wolf",
];

const EMOJIS: &[&str] = &[
    "🚀", "✨", "🔥", "⚡", "🌈", "🎯", "🎨", "📸", "🍀", "🌊", "🦊", "🦉", "🐬", "🌟", "💎", "🧩",
];

const URL_PATH_ENCODE_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'<')
    .add(b'>')
    .add(b'`')
    .add(b'{')
    .add(b'}')
    .add(b'|')
    .add(b'\\')
    .add(b'^');

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NameParserType {
    Default,
    Text,
    FileName,
    FilePath,
    Url,
}

#[derive(Debug, Clone)]
pub struct NameParser {
    pub parser_type: NameParserType,
    pub max_name_length: usize,
    pub max_title_length: usize,
    pub auto_increment_number: u64,
    pub image_width: u32,
    pub image_height: u32,
    pub window_text: Option<String>,
    pub process_name: Option<String>,
    pub allow_file_read: bool,
    pub is_preview_mode: bool,
    pub fixed_timestamp: Option<DateTime<Local>>,
}

impl NameParser {
    pub fn new(parser_type: NameParserType) -> Self {
        Self {
            parser_type,
            max_name_length: 0,
            max_title_length: 0,
            auto_increment_number: 0,
            image_width: 0,
            image_height: 0,
            window_text: None,
            process_name: None,
            allow_file_read: true,
            is_preview_mode: false,
            fixed_timestamp: None,
        }
    }

    pub fn parse_simple(parser_type: NameParserType, pattern: &str) -> String {
        let mut parser = Self::new(parser_type);
        parser.parse(pattern)
    }

    /// Reconstructs `ShareX.HelpersLib.NameParser.Parse(string pattern)` (`NameParser.cs` lines 77-338).
    pub fn parse(&mut self, pattern: &str) -> String {
        if pattern.is_empty() {
            return String::new();
        }

        let mut s = pattern.to_string();

        if let Some(ref wt) = self.window_text {
            let mut window_text = self.sanitize_input(wt);
            if self.max_title_length > 0 {
                window_text = truncate_chars(&window_text, self.max_title_length);
            }
            s = s.replace("%t", &window_text);
        }

        if let Some(ref pn) = self.process_name {
            let proc_name = self.sanitize_input(pn);
            s = s.replace("%pn", &proc_name);
        }

        let width_str = if self.image_width > 0 {
            self.image_width.to_string()
        } else {
            String::new()
        };
        let height_str = if self.image_height > 0 {
            self.image_height.to_string()
        } else {
            String::new()
        };
        s = s.replace("%width", &width_str);
        s = s.replace("%height", &height_str);

        let dt = self.fixed_timestamp.unwrap_or_else(Local::now);
        let month_name_en = english_month_name(dt.month());
        let day_name_en = english_weekday_name(dt.weekday());

        s = s
            .replace("%mon2", month_name_en)
            .replace("%mon", month_name_en)
            .replace("%yy", &format!("{:02}", dt.year() % 100))
            .replace("%y", &dt.year().to_string())
            .replace("%mo", &format!("{:02}", dt.month()))
            .replace("%d", &format!("{:02}", dt.day()));

        // ShareX rule: if `%pm` is present before `%h` substitution, `%h` uses 12-hour format (`HourTo12`).
        let hour_str = if s.contains("%pm") {
            let h12 = match dt.hour() % 12 {
                0 => 12,
                v => v,
            };
            format!("{h12:02}")
        } else {
            format!("{:02}", dt.hour())
        };

        let iso_week = dt.iso_week().week();
        let unix_secs = dt.with_timezone(&Utc).timestamp();
        let am_pm = if dt.hour() >= 12 { "PM" } else { "AM" };

        s = s
            .replace("%h", &hour_str)
            .replace("%mi", &format!("{:02}", dt.minute()))
            .replace("%s", &format!("{:02}", dt.second()))
            .replace("%ms", &format!("{:03}", dt.timestamp_subsec_millis()))
            .replace("%wy", &iso_week.to_string())
            .replace("%w2", day_name_en)
            .replace("%w", day_name_en)
            .replace("%pm", am_pm)
            .replace("%unix", &unix_secs.to_string());

        // Auto-increment tokens (%ib, %iB, %iAa, %iaA, %ia, %iA, %ix, %iX, %i)
        if contains_increment_token(&s) {
            self.auto_increment_number = self.auto_increment_number.saturating_add(1);
            let num = self.auto_increment_number;

            for (token, vals) in list_entry_with_values(&s, "%ib", 2) {
                let base = vals[0].clamp(2, 62) as usize;
                let pad = vals[1].max(0) as usize;
                let repl = pad_zeroes(&to_base(num, base, ALPHANUMERIC_INVERSE), pad);
                s = s.replace(&token, &repl);
            }
            for (token, vals) in list_entry_with_values(&s, "%iB", 2) {
                let base = vals[0].clamp(2, 62) as usize;
                let pad = vals[1].max(0) as usize;
                let repl = pad_zeroes(&to_base(num, base, ALPHANUMERIC), pad);
                s = s.replace(&token, &repl);
            }

            for (token, pad) in list_entry_with_value(&s, "%iAa") {
                let repl = pad_zeroes(&to_base(num, 62, ALPHANUMERIC), pad.max(0) as usize);
                s = s.replace(&token, &repl);
            }
            s = s.replace("%iAa", &to_base(num, 62, ALPHANUMERIC));

            for (token, pad) in list_entry_with_value(&s, "%iaA") {
                let repl = pad_zeroes(&to_base(num, 62, ALPHANUMERIC_INVERSE), pad.max(0) as usize);
                s = s.replace(&token, &repl);
            }
            s = s.replace("%iaA", &to_base(num, 62, ALPHANUMERIC_INVERSE));

            for (token, pad) in list_entry_with_value(&s, "%ia") {
                let repl = pad_zeroes(&to_base(num, 36, ALPHANUMERIC), pad.max(0) as usize)
                    .to_ascii_lowercase();
                s = s.replace(&token, &repl);
            }
            s = s.replace("%ia", &to_base(num, 36, ALPHANUMERIC).to_ascii_lowercase());

            for (token, pad) in list_entry_with_value(&s, "%iA") {
                let repl = pad_zeroes(&to_base(num, 36, ALPHANUMERIC), pad.max(0) as usize)
                    .to_ascii_uppercase();
                s = s.replace(&token, &repl);
            }
            s = s.replace("%iA", &to_base(num, 36, ALPHANUMERIC).to_ascii_uppercase());

            for (token, pad) in list_entry_with_value(&s, "%ix") {
                let width = pad.max(0) as usize;
                s = s.replace(&token, &format!("{num:0width$x}"));
            }
            s = s.replace("%ix", &format!("{num:x}"));

            for (token, pad) in list_entry_with_value(&s, "%iX") {
                let width = pad.max(0) as usize;
                s = s.replace(&token, &format!("{num:0width$X}"));
            }
            s = s.replace("%iX", &format!("{num:X}"));

            for (token, pad) in list_entry_with_value(&s, "%i") {
                let width = pad.max(0) as usize;
                s = s.replace(&token, &format!("{num:0width$}"));
            }
            s = s.replace("%i", &num.to_string());
        }

        let username = whoami::username();
        let hostname = whoami::fallible::hostname().unwrap_or_else(|_| "mac".to_string());
        s = s
            .replace("%un", &username)
            .replace("%uln", &username)
            .replace("%cn", &hostname);

        if self.parser_type == NameParserType::Text {
            s = s.replace("%n", "\n");
        }

        let mut rng = rand::thread_rng();
        s = replace_all_dynamic(&s, "%radjective", || {
            ADJECTIVES[rng.gen_range(0..ADJECTIVES.len())].to_string()
        });
        s = replace_all_dynamic(&s, "%ranimal", || {
            ANIMALS[rng.gen_range(0..ANIMALS.len())].to_string()
        });

        for (token, arg) in list_entry_with_argument(&s, "%rf") {
            if !self.allow_file_read {
                s = s.replace(&token, "");
                continue;
            }
            let preview = self.is_preview_mode;
            s = replace_all_dynamic(&s, &token, || match fs::read_to_string(&arg) {
                Ok(contents) => {
                    let lines: Vec<&str> = contents.lines().filter(|l| !l.is_empty()).collect();
                    if lines.is_empty() {
                        String::new()
                    } else {
                        let mut r = rand::thread_rng();
                        lines[r.gen_range(0..lines.len())].to_string()
                    }
                }
                Err(e) => {
                    if preview {
                        format!("File read error: {e}")
                    } else {
                        String::new()
                    }
                }
            });
        }

        for (token, count) in list_entry_with_value(&s, "%rna") {
            let n = count.clamp(0, 4096) as usize;
            s = replace_all_dynamic(&s, &token, || random_chars(BASE56, n));
        }
        for (token, count) in list_entry_with_value(&s, "%rn") {
            let n = count.clamp(0, 4096) as usize;
            s = replace_all_dynamic(&s, &token, || random_chars(NUMBERS, n));
        }
        for (token, count) in list_entry_with_value(&s, "%ra") {
            let n = count.clamp(0, 4096) as usize;
            s = replace_all_dynamic(&s, &token, || random_chars(ALPHANUMERIC, n));
        }
        for (token, count) in list_entry_with_value(&s, "%rx") {
            let n = count.clamp(0, 4096) as usize;
            s = replace_all_dynamic(&s, &token, || random_chars(HEX_LOWER, n));
        }
        for (token, count) in list_entry_with_value(&s, "%rX") {
            let n = count.clamp(0, 4096) as usize;
            s = replace_all_dynamic(&s, &token, || random_chars(HEX_UPPER, n));
        }
        for (token, count) in list_entry_with_value(&s, "%remoji") {
            let n = count.clamp(0, 1024) as usize;
            s = replace_all_dynamic(&s, &token, || {
                let mut r = rand::thread_rng();
                (0..n)
                    .map(|_| EMOJIS[r.gen_range(0..EMOJIS.len())])
                    .collect()
            });
        }

        s = replace_all_dynamic(&s, "%rna", || random_chars(BASE56, 1));
        s = replace_all_dynamic(&s, "%rn", || random_chars(NUMBERS, 1));
        s = replace_all_dynamic(&s, "%ra", || random_chars(ALPHANUMERIC, 1));
        s = replace_all_dynamic(&s, "%rx", || random_chars(HEX_LOWER, 1));
        s = replace_all_dynamic(&s, "%rX", || random_chars(HEX_UPPER, 1));
        s = replace_all_dynamic(&s, "%guid", || Uuid::new_v4().to_string().to_ascii_lowercase());
        s = replace_all_dynamic(&s, "%GUID", || Uuid::new_v4().to_string().to_ascii_uppercase());
        s = replace_all_dynamic(&s, "%remoji", || {
            let mut r = rand::thread_rng();
            EMOJIS[r.gen_range(0..EMOJIS.len())].to_string()
        });

        match self.parser_type {
            NameParserType::FileName => {
                s = sanitize_file_name(&s);
            }
            NameParserType::FilePath => {
                s = sanitize_file_path(&s);
            }
            NameParserType::Url => {
                s = utf8_percent_encode(&s, URL_PATH_ENCODE_SET).to_string();
            }
            NameParserType::Default | NameParserType::Text => {}
        }

        if self.max_name_length > 0 {
            s = truncate_chars(&s, self.max_name_length);
        }

        s
    }

    fn sanitize_input(&self, input: &str) -> String {
        let mut s = input.trim().replace(' ', "_");
        if matches!(
            self.parser_type,
            NameParserType::FileName | NameParserType::FilePath
        ) {
            s = sanitize_file_name(&s);
        }
        s
    }
}

/// Reconstructs `ShareX.UploadInfoParser` (`ShareX/UploadInfoParser.cs`).
pub struct UploadInfoParser;

impl UploadInfoParser {
    pub fn format_link(result: &UploadResult, format: LinkFormat) -> String {
        let url = &result.url;
        let short = if result.shortened_url.is_empty() {
            url.as_str()
        } else {
            result.shortened_url.as_str()
        };
        let thumb = if result.thumbnail_url.is_empty() {
            url.as_str()
        } else {
            result.thumbnail_url.as_str()
        };
        match format {
            LinkFormat::Url => url.clone(),
            LinkFormat::ShortenedUrl => short.to_string(),
            LinkFormat::MarkdownLink => format!("[{url}]({url})"),
            LinkFormat::MarkdownImage => format!("![]({url})"),
            LinkFormat::MarkdownLinkedImage => format!("[![]({thumb})]({url})"),
            LinkFormat::HtmlLink => format!("<a href=\"{url}\">{url}</a>"),
            LinkFormat::HtmlImage => format!("<img src=\"{url}\">"),
            LinkFormat::HtmlLinkedImage => format!("<a href=\"{url}\"><img src=\"{thumb}\"></a>"),
            LinkFormat::ForumLink => format!("[url]{url}[/url]"),
            LinkFormat::ForumImage => format!("[img]{url}[/img]"),
            LinkFormat::ForumLinkedImage => format!("[url={url}][img]{thumb}[/img][/url]"),
            LinkFormat::WikiImage => format!("[{url}]"),
        }
    }

    pub fn parse(
        pattern: &str,
        result: Option<&UploadResult>,
        file_name: &str,
        file_path: Option<&str>,
        thumbnail_path: Option<&str>,
    ) -> String {
        if pattern.is_empty() {
            return String::new();
        }
        let mut out = NameParser::parse_simple(NameParserType::Text, pattern);

        if let Some(res) = result {
            let primary = if !res.primary_url().is_empty() {
                res.primary_url().to_string()
            } else {
                file_path.unwrap_or("").to_string()
            };
            out = out
                .replace("$result", &primary)
                .replace("$url", &res.url)
                .replace("$shorturl", &res.shortened_url)
                .replace("$thumbnailurl", &res.thumbnail_url)
                .replace("$deletionurl", &res.deletion_url)
                .replace("$uploadtime", &res.upload_duration_ms.to_string());
        }

        let file_name_no_ext = Path::new(file_name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let folder_path = file_path
            .and_then(|p| Path::new(p).parent())
            .and_then(|p| p.to_str())
            .unwrap_or("");
        let folder_name = Path::new(folder_path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let thumb_name = thumbnail_path
            .and_then(|p| Path::new(p).file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let thumb_no_ext = thumbnail_path
            .and_then(|p| Path::new(p).file_stem())
            .and_then(|s| s.to_str())
            .unwrap_or("");

        out.replace("$filenamenoext", file_name_no_ext)
            .replace("$filename", file_name)
            .replace("$filepath", file_path.unwrap_or(""))
            .replace("$folderpath", folder_path)
            .replace("$foldername", folder_name)
            .replace("$thumbnailfilenamenoext", thumb_no_ext)
            .replace("$thumbnailfilename", thumb_name)
    }
}

pub fn sanitize_file_name(input: &str) -> String {
    input
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect()
}

pub fn sanitize_file_path(input: &str) -> String {
    input
        .split('/')
        .map(|seg| {
            if seg.is_empty() {
                String::new()
            } else {
                sanitize_file_name(seg)
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn contains_increment_token(s: &str) -> bool {
    ["%ib", "%iB", "%iAa", "%iaA", "%ia", "%iA", "%ix", "%iX", "%i"]
        .iter()
        .any(|tok| s.contains(tok))
}

fn to_base(mut value: u64, base: usize, alphabet: &[u8]) -> String {
    let base = base.min(alphabet.len()).max(2) as u64;
    if value == 0 {
        return (alphabet[0] as char).to_string();
    }
    let mut digits = Vec::new();
    while value > 0 {
        let rem = (value % base) as usize;
        digits.push(alphabet[rem] as char);
        value /= base;
    }
    digits.reverse();
    digits.into_iter().collect()
}

fn pad_zeroes(s: &str, total_len: usize) -> String {
    let count = s.chars().count();
    if count >= total_len {
        s.to_string()
    } else {
        format!("{}{}", "0".repeat(total_len - count), s)
    }
}

fn truncate_chars(s: &str, max_len: usize) -> String {
    s.chars().take(max_len).collect()
}

fn random_chars(alphabet: &[u8], count: usize) -> String {
    let mut rng = rand::thread_rng();
    (0..count)
        .map(|_| alphabet[rng.gen_range(0..alphabet.len())] as char)
        .collect()
}

fn replace_all_dynamic<F: FnMut() -> String>(text: &str, needle: &str, mut generator: F) -> String {
    if needle.is_empty() || !text.contains(needle) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(idx) = rest.find(needle) {
        out.push_str(&rest[..idx]);
        out.push_str(&generator());
        rest = &rest[idx + needle.len()..];
    }
    out.push_str(rest);
    out
}

fn list_entry_with_arguments(text: &str, entry: &str, elements: usize) -> Vec<(String, Vec<String>)> {
    let prefix = format!("{entry}{{");
    let mut results = Vec::new();
    let mut search_from = 0;
    while let Some(rel_start) = text[search_from..].find(&prefix) {
        let start = search_from + rel_start;
        let inner_start = start + prefix.len();
        if let Some(rel_end) = text[inner_start..].find('}') {
            let end = inner_start + rel_end;
            let full_token = text[start..=end].to_string();
            let inner = &text[inner_start..end];
            let mut parts: Vec<String> = inner.split(',').map(|p| p.to_string()).collect();
            if parts.len() < elements {
                parts.resize(elements, String::new());
            }
            results.push((full_token, parts));
            search_from = end + 1;
        } else {
            break;
        }
    }
    results
}

fn list_entry_with_argument(text: &str, entry: &str) -> Vec<(String, String)> {
    list_entry_with_arguments(text, entry, 1)
        .into_iter()
        .map(|(tok, mut args)| (tok, args.remove(0)))
        .collect()
}

fn list_entry_with_values(text: &str, entry: &str, elements: usize) -> Vec<(String, Vec<i32>)> {
    list_entry_with_arguments(text, entry, elements)
        .into_iter()
        .map(|(tok, args)| {
            let nums = args
                .into_iter()
                .map(|a| a.trim().parse::<i32>().unwrap_or(0))
                .collect();
            (tok, nums)
        })
        .collect()
}

fn list_entry_with_value(text: &str, entry: &str) -> Vec<(String, i32)> {
    list_entry_with_values(text, entry, 1)
        .into_iter()
        .map(|(tok, vals)| (tok, vals[0]))
        .collect()
}

fn english_month_name(month: u32) -> &'static str {
    match month {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        _ => "Unknown",
    }
}

fn english_weekday_name(weekday: chrono::Weekday) -> &'static str {
    match weekday {
        chrono::Weekday::Mon => "Monday",
        chrono::Weekday::Tue => "Tuesday",
        chrono::Weekday::Wed => "Wednesday",
        chrono::Weekday::Thu => "Thursday",
        chrono::Weekday::Fri => "Friday",
        chrono::Weekday::Sat => "Saturday",
        chrono::Weekday::Sun => "Sunday",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn parses_date_time_and_12h_pm_semantics() {
        let mut p = NameParser::new(NameParserType::FileName);
        p.fixed_timestamp = Some(Local.with_ymd_and_hms(2026, 11, 13, 16, 5, 9).unwrap());
        assert_eq!(p.parse("%y-%mo-%d_%h-%mi-%s"), "2026-11-13_16-05-09");
        assert_eq!(
            p.parse("%yy_%mon2_%w2_%h-%mi_%pm"),
            "26_November_Friday_04-05_PM"
        );
    }

    #[test]
    fn parses_window_dimensions_and_sanitizes() {
        let mut p = NameParser::new(NameParserType::FileName);
        p.window_text = Some("Cursor: main.rs / sharaza*".to_string());
        p.process_name = Some("Cursor IDE".to_string());
        p.max_title_length = 14;
        p.image_width = 2560;
        p.image_height = 1440;
        let out = p.parse("%pn_%t_%widthx%height");
        assert_eq!(out, "Cursor_IDE_Cursor__main.r_2560x1440");
    }

    #[test]
    fn parses_auto_increment_bases_and_padding() {
        let mut p = NameParser::new(NameParserType::Default);
        p.auto_increment_number = 9;
        assert_eq!(p.parse("%i{4}"), "0010");
        assert_eq!(p.auto_increment_number, 10);
        // Next call increments to 11 -> hex b / B
        assert_eq!(p.parse("%ix{3}_%iX{2}"), "00b_0B");
        assert_eq!(p.auto_increment_number, 11);
    }

    #[test]
    fn enforces_allow_file_read_security_gate() {
        let tmp = std::env::temp_dir().join("sharaza_nameparser_rf_test.txt");
        fs::write(&tmp, "secret_line\n").unwrap();
        let pattern = format!("prefix_%rf{{{}}}_suffix", tmp.display());

        let mut blocked = NameParser::new(NameParserType::Text);
        blocked.allow_file_read = false;
        assert_eq!(blocked.parse(&pattern), "prefix__suffix");

        let mut allowed = NameParser::new(NameParserType::Text);
        allowed.allow_file_read = true;
        assert_eq!(allowed.parse(&pattern), "prefix_secret_line_suffix");
        let _ = fs::remove_file(&tmp);
    }

    #[test]
    fn parses_random_tokens_independently() {
        let mut p = NameParser::new(NameParserType::FileName);
        let out = p.parse("%ra{12}_%rn{6}_%rx{8}_%guid");
        let parts: Vec<&str> = out.split('_').collect();
        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0].len(), 12);
        assert_eq!(parts[1].len(), 6);
        assert!(parts[1].chars().all(|c| c.is_ascii_digit()));
        assert_eq!(parts[2].len(), 8);
        assert!(parts[2].chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(parts[3].len(), 36);
    }

    #[test]
    fn formats_upload_info_links() {
        let res = UploadResult {
            url: "https://i.imgur.com/abc123.png".to_string(),
            thumbnail_url: "https://i.imgur.com/abc123s.png".to_string(),
            shortened_url: "https://is.gd/xyz".to_string(),
            deletion_url: "https://imgur.com/delete/del999".to_string(),
            upload_duration_ms: 320,
            ..Default::default()
        };
        assert_eq!(
            UploadInfoParser::format_link(&res, LinkFormat::MarkdownImage),
            "![](https://i.imgur.com/abc123.png)"
        );
        assert_eq!(
            UploadInfoParser::format_link(&res, LinkFormat::ForumLinkedImage),
            "[url=https://i.imgur.com/abc123.png][img]https://i.imgur.com/abc123s.png[/img][/url]"
        );
        let parsed = UploadInfoParser::parse(
            "$filename -> $shorturl ($url) in $uploadtimems",
            Some(&res),
            "shot.png",
            Some("/Users/test/Pictures/shot.png"),
            None,
        );
        assert_eq!(
            parsed,
            "shot.png -> https://is.gd/xyz (https://i.imgur.com/abc123.png) in 320ms"
        );
    }
}

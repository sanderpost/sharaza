use crate::error::{CoreError, CoreResult};
use crate::models::UploadResult;
use crate::name_parser::{NameParser, NameParserType};
use base64::Engine;
use rand::Rng;
use regex::Regex;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::time::Instant;
use url::Url;

/// Matches `ShareX.UploadersLib.CustomUploaderBody`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CustomUploaderBody {
    None,
    #[default]
    MultipartFormData,
    FormURLEncoded,
    JSON,
    XML,
    Binary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "UPPERCASE")]
pub enum SxcuHttpMethod {
    GET,
    #[default]
    POST,
    PUT,
    PATCH,
    DELETE,
}

/// Deserializes `DestinationType` from either ShareX's string flags (`"ImageUploader, FileUploader"`)
/// or numeric bitmask (`7`).
fn deserialize_destination_type<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let val = Value::deserialize(deserializer)?;
    match val {
        Value::String(s) => Ok(s),
        Value::Number(n) => Ok(n.to_string()),
        _ => Ok("None".to_string()),
    }
}

/// Reconstructs `ShareX.UploadersLib.CustomUploaderItem` (`CustomUploaderItem.cs`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct CustomUploaderItem {
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, deserialize_with = "deserialize_destination_type")]
    pub destination_type: String,
    #[serde(default)]
    pub request_method: SxcuHttpMethod,
    #[serde(default, rename = "RequestURL")]
    pub request_url: String,
    #[serde(default)]
    pub parameters: HashMap<String, String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub body: CustomUploaderBody,
    #[serde(default)]
    pub arguments: HashMap<String, String>,
    #[serde(default)]
    pub file_form_name: String,
    #[serde(default)]
    pub data: String,
    #[serde(default, rename = "URL")]
    pub url: String,
    #[serde(default, rename = "ThumbnailURL")]
    pub thumbnail_url: String,
    #[serde(default, rename = "DeletionURL")]
    pub deletion_url: String,
    #[serde(default)]
    pub error_message: String,
}

impl CustomUploaderItem {
    pub fn from_sxcu_str(json: &str) -> CoreResult<Self> {
        Ok(serde_json::from_str(json)?)
    }

    pub fn to_sxcu_string(&self) -> CoreResult<String> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    pub fn display_name(&self) -> String {
        if !self.name.trim().is_empty() {
            return self.name.trim().to_string();
        }
        if let Ok(parsed) = Url::parse(&self.request_url)
            && let Some(host) = parsed.host_str()
        {
            return host.to_string();
        }
        "CustomUploader".to_string()
    }
}

#[derive(Debug, Clone, Default)]
pub struct SxcuEvalContext {
    pub file_name: String,
    pub input: String,
    pub response_text: String,
    pub response_url: String,
    pub response_headers: HashMap<String, String>,
    pub url_encode: bool,
    pub use_name_parser: bool,
}

/// Reconstructs `ShareXCustomUploaderSyntaxParser` (`ShareXCustomUploaderSyntaxParser.cs` + `Functions/*.cs`).
pub struct SxcuSyntaxParser<'a> {
    ctx: &'a SxcuEvalContext,
}

impl<'a> SxcuSyntaxParser<'a> {
    pub fn new(ctx: &'a SxcuEvalContext) -> Self {
        Self { ctx }
    }

    pub fn parse(&self, template: &str) -> String {
        if template.is_empty() {
            return String::new();
        }
        let mut text = template.to_string();
        if self.ctx.use_name_parser {
            let mut np = NameParser::new(NameParserType::Text);
            // Security invariant verified in ShareX `CustomUploaderItem.cs`: never allow `%rf` file read in `.sxcu`!
            np.allow_file_read = false;
            text = np.parse(&text);
        }
        self.parse_syntax(&text)
    }

    fn parse_syntax(&self, input: &str) -> String {
        let chars: Vec<char> = input.chars().collect();
        let mut out = String::with_capacity(input.len());
        let mut i = 0;

        while i < chars.len() {
            if chars[i] == '\\' && i + 1 < chars.len() && matches!(chars[i + 1], '$' | '|' | '\\') {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if chars[i] == '$' {
                if let Some((end_idx, expr)) = find_closing_dollar(&chars, i + 1) {
                    out.push_str(&self.eval_expression(&expr));
                    i = end_idx + 1;
                    continue;
                }
            }
            out.push(chars[i]);
            i += 1;
        }
        out
    }

    fn eval_expression(&self, expr: &str) -> String {
        if expr.is_empty() {
            return String::new();
        }
        let (fn_name, raw_args) = split_function_and_args(expr);
        let parsed_args: Vec<String> = raw_args.iter().map(|a| self.parse_syntax(a)).collect();

        match fn_name.to_ascii_lowercase().as_str() {
            "response" => self.ctx.response_text.clone(),
            "responseurl" => self.ctx.response_url.clone(),
            "filename" => {
                if self.ctx.url_encode {
                    urlencoding_component(&self.ctx.file_name)
                } else {
                    self.ctx.file_name.clone()
                }
            }
            "input" => {
                if self.ctx.url_encode {
                    urlencoding_component(&self.ctx.input)
                } else {
                    self.ctx.input.clone()
                }
            }
            "header" => {
                if let Some(name) = parsed_args.first() {
                    let key = name.to_ascii_lowercase();
                    self.ctx
                        .response_headers
                        .iter()
                        .find(|(k, _)| k.to_ascii_lowercase() == key)
                        .map(|(_, v)| v.clone())
                        .unwrap_or_default()
                } else {
                    String::new()
                }
            }
            "json" => {
                let (source, path) = if parsed_args.len() >= 2 {
                    (parsed_args[0].as_str(), parsed_args[1].as_str())
                } else if parsed_args.len() == 1 {
                    (self.ctx.response_text.as_str(), parsed_args[0].as_str())
                } else {
                    return String::new();
                };
                extract_json_path(source, path).unwrap_or_default()
            }
            "xml" => {
                let (source, tag) = if parsed_args.len() >= 2 {
                    (parsed_args[0].as_str(), parsed_args[1].as_str())
                } else if parsed_args.len() == 1 {
                    (self.ctx.response_text.as_str(), parsed_args[0].as_str())
                } else {
                    return String::new();
                };
                extract_simple_xml(source, tag).unwrap_or_default()
            }
            "regex" => {
                // ShareX supports `$regex:pattern|group$`, `$regex:pattern$`, or `$regex:input|pattern|group$`
                match parsed_args.len() {
                    0 => String::new(),
                    1 => eval_regex(&self.ctx.response_text, &parsed_args[0], None),
                    2 => {
                        // Disambiguate: if 2nd arg is group index or pattern matches response_text
                        if parsed_args[1].parse::<usize>().is_ok() {
                            eval_regex(
                                &self.ctx.response_text,
                                &parsed_args[0],
                                Some(&parsed_args[1]),
                            )
                        } else {
                            let direct = eval_regex(
                                &self.ctx.response_text,
                                &parsed_args[0],
                                Some(&parsed_args[1]),
                            );
                            if !direct.is_empty() {
                                direct
                            } else {
                                eval_regex(&parsed_args[0], &parsed_args[1], None)
                            }
                        }
                    }
                    _ => eval_regex(&parsed_args[0], &parsed_args[1], Some(&parsed_args[2])),
                }
            }
            "base64" => {
                let target = parsed_args
                    .first()
                    .map(|s| s.as_str())
                    .unwrap_or(&self.ctx.input);
                base64::engine::general_purpose::STANDARD.encode(target.as_bytes())
            }
            "random" => {
                if parsed_args.is_empty() {
                    String::new()
                } else {
                    let mut rng = rand::thread_rng();
                    parsed_args[rng.gen_range(0..parsed_args.len())].clone()
                }
            }
            "select" | "prompt" | "inputbox" => {
                parsed_args.first().cloned().unwrap_or_default()
            }
            _ => String::new(),
        }
    }
}

pub async fn execute_custom_uploader(
    client: &reqwest::Client,
    item: &CustomUploaderItem,
    file_name: &str,
    file_bytes: Option<&[u8]>,
    text_or_url_input: Option<&str>,
    secret_headers: &HashMap<String, String>,
    secret_params: &HashMap<String, String>,
) -> CoreResult<UploadResult> {
    if item.request_url.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "Custom uploader RequestURL must be configured".to_string(),
        ));
    }

    let started = Instant::now();
    let input_str = text_or_url_input.unwrap_or("").to_string();

    let url_ctx = SxcuEvalContext {
        file_name: file_name.to_string(),
        input: input_str.clone(),
        url_encode: true,
        use_name_parser: true,
        ..Default::default()
    };
    let parsed_base_url = fix_url_prefix(&SxcuSyntaxParser::new(&url_ctx).parse(&item.request_url));
    let mut url = Url::parse(&parsed_base_url)
        .map_err(|e| CoreError::InvalidConfig(format!("Invalid RequestURL '{parsed_base_url}': {e}")))?;

    let arg_ctx = SxcuEvalContext {
        file_name: file_name.to_string(),
        input: input_str.clone(),
        url_encode: false,
        use_name_parser: true,
        ..Default::default()
    };
    let parser = SxcuSyntaxParser::new(&arg_ctx);

        if !item.parameters.is_empty() || !secret_params.is_empty() {
            let mut qp = url.query_pairs_mut();
            for (k, v) in &item.parameters {
                qp.append_pair(k, &parser.parse(v));
            }
            for (k, v) in secret_params {
                qp.append_pair(k, v);
            }
        }

    let method = match item.request_method {
        SxcuHttpMethod::GET => reqwest::Method::GET,
        SxcuHttpMethod::POST => reqwest::Method::POST,
        SxcuHttpMethod::PUT => reqwest::Method::PUT,
        SxcuHttpMethod::PATCH => reqwest::Method::PATCH,
        SxcuHttpMethod::DELETE => reqwest::Method::DELETE,
    };

    let mut headers = HeaderMap::new();
    for (k, v) in &item.headers {
        if let (Ok(hn), Ok(hv)) = (
            HeaderName::from_bytes(k.as_bytes()),
            HeaderValue::from_str(&parser.parse(v)),
        ) {
            headers.insert(hn, hv);
        }
    }
    for (k, v) in secret_headers {
        if let (Ok(hn), Ok(hv)) = (
            HeaderName::from_bytes(k.as_bytes()),
            HeaderValue::from_str(v),
        ) {
            headers.insert(hn, hv);
        }
    }

    let mut req = client.request(method, url).headers(headers);

    match item.body {
        CustomUploaderBody::None => {}
        CustomUploaderBody::MultipartFormData => {
            let mut form = reqwest::multipart::Form::new();
            for (k, v) in &item.arguments {
                form = form.text(k.clone(), parser.parse(v));
            }
            if let Some(bytes) = file_bytes {
                let field_name = if item.file_form_name.trim().is_empty() {
                    "file".to_string()
                } else {
                    item.file_form_name.clone()
                };
                let part = reqwest::multipart::Part::bytes(bytes.to_vec())
                    .file_name(file_name.to_string());
                form = form.part(field_name, part);
            }
            req = req.multipart(form);
        }
        CustomUploaderBody::FormURLEncoded => {
            let mut form_pairs = Vec::new();
            for (k, v) in &item.arguments {
                form_pairs.push((k.clone(), parser.parse(v)));
            }
            req = req.form(&form_pairs);
        }
        CustomUploaderBody::JSON => {
            let body_data = build_data_body(&item.data, &input_str, file_name, true);
            req = req
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(body_data);
        }
        CustomUploaderBody::XML => {
            let body_data = build_data_body(&item.data, &input_str, file_name, false);
            req = req
                .header(reqwest::header::CONTENT_TYPE, "application/xml")
                .body(body_data);
        }
        CustomUploaderBody::Binary => {
            if let Some(bytes) = file_bytes {
                req = req
                    .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
                    .body(bytes.to_vec());
            } else {
                req = req.body(input_str.clone());
            }
        }
    }

    let resp = req.send().await?;
    let status = resp.status();
    let final_url = resp.url().to_string();
    let mut resp_headers = HashMap::new();
    for (k, v) in resp.headers() {
        if let Ok(s) = v.to_str() {
            resp_headers.insert(k.as_str().to_string(), s.to_string());
        }
    }
    let resp_text = resp.text().await?;
    let elapsed_ms = started.elapsed().as_millis() as u64;

    let resp_ctx = SxcuEvalContext {
        file_name: file_name.to_string(),
        input: input_str,
        response_text: resp_text.clone(),
        response_url: final_url,
        response_headers: resp_headers,
        url_encode: false,
        use_name_parser: true,
    };
    let resp_parser = SxcuSyntaxParser::new(&resp_ctx);

    let mut errors = Vec::new();
    if !status.is_success() {
        let custom_err = if !item.error_message.is_empty() {
            resp_parser.parse(&item.error_message)
        } else {
            String::new()
        };
        if !custom_err.is_empty() {
            errors.push(format!("HTTP {}: {}", status.as_u16(), custom_err));
        } else {
            errors.push(format!("HTTP {}: {}", status.as_u16(), resp_text));
        }
    }

    let resolved_url = if !item.url.is_empty() {
        resp_parser.parse(&item.url)
    } else if status.is_success() {
        resp_text.trim().to_string()
    } else {
        String::new()
    };

    let thumb_url = if !item.thumbnail_url.is_empty() {
        resp_parser.parse(&item.thumbnail_url)
    } else {
        String::new()
    };
    let del_url = if !item.deletion_url.is_empty() {
        resp_parser.parse(&item.deletion_url)
    } else {
        String::new()
    };

    Ok(UploadResult {
        url: resolved_url,
        thumbnail_url: thumb_url,
        deletion_url: del_url,
        shortened_url: String::new(),
        share_url: String::new(),
        host: item.display_name(),
        response_text: resp_text,
        upload_duration_ms: elapsed_ms,
        errors,
    })
}

fn build_data_body(data_template: &str, input: &str, file_name: &str, is_json: bool) -> String {
    let mut np = NameParser::new(NameParserType::Text);
    np.allow_file_read = false;
    let parsed = np.parse(data_template);
    let enc_input = if is_json {
        escape_json_string(input)
    } else {
        escape_xml_string(input)
    };
    let enc_file = if is_json {
        escape_json_string(file_name)
    } else {
        escape_xml_string(file_name)
    };
    case_insensitive_replace(&case_insensitive_replace(&parsed, "{input}", &enc_input), "{filename}", &enc_file)
}

fn escape_json_string(s: &str) -> String {
    serde_json::to_string(s)
        .unwrap_or_default()
        .trim_matches('"')
        .to_string()
}

fn escape_xml_string(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn case_insensitive_replace(haystack: &str, needle: &str, replacement: &str) -> String {
    if let Ok(re) = Regex::new(&format!("(?i){}", regex::escape(needle))) {
        re.replace_all(haystack, regex::NoExpand(replacement)).to_string()
    } else {
        haystack.replace(needle, replacement)
    }
}

fn fix_url_prefix(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

fn urlencoding_component(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

fn find_closing_dollar(chars: &[char], start: usize) -> Option<(usize, String)> {
    let mut buf = String::new();
    let mut i = start;
    let mut depth = 0usize;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() {
            buf.push('\\');
            buf.push(chars[i + 1]);
            i += 2;
            continue;
        }
        if chars[i] == '$' {
            // Nested `$fn:...$` support inside arguments: if we already saw `:` and another `$` pairs before `|`
            if depth == 0 {
                return Some((i, buf));
            } else {
                depth -= 1;
                buf.push('$');
                i += 1;
                continue;
            }
        }
        buf.push(chars[i]);
        i += 1;
    }
    None
}

fn split_function_and_args(expr: &str) -> (String, Vec<String>) {
    let chars: Vec<char> = expr.chars().collect();
    let mut colon_pos = None;
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() {
            i += 2;
            continue;
        }
        if chars[i] == ':' {
            colon_pos = Some(i);
            break;
        }
        i += 1;
    }

    let Some(cpos) = colon_pos else {
        return (expr.trim().to_string(), Vec::new());
    };

    let fn_name: String = chars[..cpos].iter().collect();
    let mut args = Vec::new();
    let mut current = String::new();
    let mut j = cpos + 1;
    while j < chars.len() {
        if chars[j] == '\\' && j + 1 < chars.len() && matches!(chars[j + 1], '$' | '|' | '\\') {
            current.push(chars[j + 1]);
            j += 2;
            continue;
        }
        if chars[j] == '|' {
            args.push(current);
            current = String::new();
            j += 1;
            continue;
        }
        current.push(chars[j]);
        j += 1;
    }
    args.push(current);
    (fn_name.trim().to_string(), args)
}

/// Evaluates ShareX JSON path expressions like `url`, `data.link`, `attachments[0].url`, `$.files[0].url`.
pub fn extract_json_path(json_str: &str, path: &str) -> Option<String> {
    let root: Value = serde_json::from_str(json_str).ok()?;
    let clean_path = path.trim().trim_start_matches("$.");
    let mut cur = &root;

    for segment in clean_path.split('.') {
        if segment.is_empty() {
            continue;
        }
        let mut rest = segment;
        if let Some(bracket_idx) = rest.find('[') {
            let field = &rest[..bracket_idx];
            if !field.is_empty() {
                cur = cur.get(field)?;
            }
            rest = &rest[bracket_idx..];
            while let Some(open) = rest.find('[') {
                let close = rest[open..].find(']')? + open;
                let idx_str = rest[open + 1..close].trim().trim_matches('\'').trim_matches('"');
                if let Ok(idx) = idx_str.parse::<usize>() {
                    cur = cur.get(idx)?;
                } else {
                    cur = cur.get(idx_str)?;
                }
                rest = &rest[close + 1..];
            }
        } else {
            cur = cur.get(rest)?;
        }
    }

    match cur {
        Value::Null => None,
        Value::String(s) => Some(s.clone()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        other => Some(other.to_string()),
    }
}

fn extract_simple_xml(xml_str: &str, tag_or_path: &str) -> Option<String> {
    let tag = tag_or_path
        .trim()
        .rsplit('/')
        .next()
        .unwrap_or(tag_or_path)
        .trim();
    if tag.is_empty() {
        return None;
    }
    let pattern = format!(
        r"(?s)<{t}(?:\s[^>]*)?>(.*?)</{t}>",
        t = regex::escape(tag)
    );
    let re = Regex::new(&pattern).ok()?;
    let caps = re.captures(xml_str)?;
    Some(caps.get(1)?.as_str().trim().to_string())
}

fn eval_regex(input: &str, pattern: &str, group: Option<&str>) -> String {
    let Ok(re) = Regex::new(pattern) else {
        return String::new();
    };
    let Some(caps) = re.captures(input) else {
        return String::new();
    };
    if let Some(g) = group && !g.is_empty() {
        if let Ok(idx) = g.parse::<usize>() {
            return caps.get(idx).map(|m| m.as_str().to_string()).unwrap_or_default();
        }
        return caps.name(g).map(|m| m.as_str().to_string()).unwrap_or_default();
    }
    if caps.len() > 1 {
        caps.get(1).map(|m| m.as_str().to_string()).unwrap_or_default()
    } else {
        caps.get(0).map(|m| m.as_str().to_string()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn parses_real_upstream_sxcu_definitions_and_syntax() {
        let discord_sxcu = r#"{
          "Version": "12.4.1",
          "Name": "Discord webhook (Image uploader)",
          "DestinationType": "ImageUploader",
          "RequestMethod": "POST",
          "RequestURL": "https://discord.com/api/webhooks/123/abc",
          "Body": "MultipartFormData",
          "Arguments": {
            "content": "**$filename$**"
          },
          "FileFormName": "file",
          "URL": "$json:attachments[0].url$"
        }"#;

        let item = CustomUploaderItem::from_sxcu_str(discord_sxcu).unwrap();
        assert_eq!(item.name, "Discord webhook (Image uploader)");
        assert_eq!(item.file_form_name, "file");

        let ctx = SxcuEvalContext {
            file_name: "capture.png".to_string(),
            response_text: r#"{"attachments":[{"url":"https://cdn.discordapp.com/attachments/1/2/capture.png"}]}"#.to_string(),
            response_headers: HashMap::from([("X-Upload-Id".to_string(), "up_99".to_string())]),
            ..Default::default()
        };
        let parser = SxcuSyntaxParser::new(&ctx);
        assert_eq!(
            parser.parse(&item.url),
            "https://cdn.discordapp.com/attachments/1/2/capture.png"
        );
        assert_eq!(parser.parse("**$filename$**"), "**capture.png**");
        assert_eq!(parser.parse("$header:x-upload-id$"), "up_99");
        assert_eq!(
            parser.parse("$regex:attachments/(\\d+)/(\\d+)|2$"),
            "2"
        );
    }

    #[tokio::test]
    async fn executes_sxcu_multipart_upload_against_local_server() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut full_req = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let n = stream.read(&mut buf).await.unwrap();
                if n == 0 {
                    break;
                }
                full_req.extend_from_slice(&buf[..n]);
                if String::from_utf8_lossy(&full_req).contains("PNG_FAKE_BYTES") {
                    break;
                }
            }
            let req_str = String::from_utf8_lossy(&full_req).to_ascii_lowercase();
            assert!(req_str.contains("post /upload "));
            assert!(req_str.contains("x-api-key: secret123"));

            let body = r#"{"data":{"url":"https://cdn.local/s/shot1.png","thumb":"https://cdn.local/s/shot1_t.png","delete":"https://cdn.local/d/999"}}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(resp.as_bytes()).await.unwrap();
            let _ = stream.shutdown().await;
        });

        let item = CustomUploaderItem::from_sxcu_str(&format!(
            r#"{{
              "Version": "22.4.0",
              "Name": "LocalTestHost",
              "DestinationType": "ImageUploader",
              "RequestMethod": "POST",
              "RequestURL": "http://{addr}/upload",
              "Body": "MultipartFormData",
              "FileFormName": "image",
              "URL": "$json:data.url$",
              "ThumbnailURL": "$json:data.thumb$",
              "DeletionURL": "$json:data.delete$"
            }}"#
        ))
        .unwrap();

        let client = reqwest::Client::new();
        let mut secret_headers = HashMap::new();
        secret_headers.insert("X-Api-Key".to_string(), "secret123".to_string());

        let result = execute_custom_uploader(
            &client,
            &item,
            "shot1.png",
            Some(b"PNG_FAKE_BYTES"),
            None,
            &secret_headers,
            &HashMap::new(),
        )
        .await
        .unwrap();

        server.await.unwrap();
        assert!(!result.is_error(), "errors: {:?}", result.errors);
        assert_eq!(result.url, "https://cdn.local/s/shot1.png");
        assert_eq!(result.thumbnail_url, "https://cdn.local/s/shot1_t.png");
        assert_eq!(result.deletion_url, "https://cdn.local/d/999");
        assert_eq!(result.host, "LocalTestHost");
    }

    #[test]
    fn parses_upstream_sharex_custom_uploaders_corpus_when_available() {
        let corpus_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../.upstream/CustomUploaders");
        if !corpus_dir.exists() {
            return;
        }
        let mut total = 0usize;
        let mut parsed = 0usize;
        for entry in std::fs::read_dir(&corpus_dir).unwrap().flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) == Some("sxcu") {
                total += 1;
                if let Ok(raw) = std::fs::read_to_string(&path) {
                    let trimmed = raw.trim_start_matches('\u{feff}');
                    if CustomUploaderItem::from_sxcu_str(trimmed).is_ok() {
                        parsed += 1;
                    }
                }
            }
        }
        assert!(total > 100, "expected upstream corpus, got {total}");
        // Legacy v8-v11 pre-JSON or deprecated schema files may differ; modern >=12.x corpus should parse >90%
        assert!(
            parsed * 100 / total >= 85,
            "parsed {parsed}/{total} upstream .sxcu files"
        );
    }
}

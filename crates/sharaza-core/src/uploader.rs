use crate::error::{CoreError, CoreResult};
use crate::models::{
    BuiltinFileUploader, BuiltinImageUploader, BuiltinTextUploader, BuiltinUrlShortener,
    ResolvedCredentials, TaskSettings, UploadResult, UrlSharingService,
};
use crate::sxcu::{CustomUploaderItem, execute_custom_uploader};
use regex::Regex;
use serde_json::{Value, json};
use std::time::Instant;

/// Default public anonymous ShareX-compatible Imgur Client-ID fallback if user hasn't configured their own.
const DEFAULT_IMGUR_CLIENT_ID: &str = "546c25a59c58ad7";

pub struct UploaderManager {
    client: reqwest::Client,
}

impl Default for UploaderManager {
    fn default() -> Self {
        Self::new()
    }
}

impl UploaderManager {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent("Sharaza/0.1.0 (macOS; ShareX-compatible)")
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .unwrap_or_default();
        Self { client }
    }

    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }

    pub async fn upload_image(
        &self,
        settings: &TaskSettings,
        file_name: &str,
        image_bytes: &[u8],
        creds: &ResolvedCredentials,
        custom_uploader: Option<&CustomUploaderItem>,
    ) -> CoreResult<UploadResult> {
        let max_attempts = settings.max_upload_retries.saturating_add(1).max(1);
        let mut last_res = UploadResult::default();

        for attempt in 0..max_attempts {
            if attempt > 0 {
                tokio::time::sleep(std::time::Duration::from_millis(900)).await;
            }
            let res = match settings.image_uploader {
                BuiltinImageUploader::Imgur => {
                    self.upload_imgur(file_name, image_bytes, creds).await
                }
                BuiltinImageUploader::VgyMe => {
                    self.upload_vgyme(file_name, image_bytes, creds).await
                }
                BuiltinImageUploader::Catbox => self.upload_catbox(file_name, image_bytes).await,
                BuiltinImageUploader::ZeroXZero => {
                    self.upload_0x0st(file_name, image_bytes).await
                }
                BuiltinImageUploader::CustomImageUploader => {
                    let item = custom_uploader.ok_or_else(|| {
                        CoreError::InvalidConfig(
                            "No custom uploader (.sxcu) selected for CustomImageUploader"
                                .to_string(),
                        )
                    })?;
                    execute_custom_uploader(
                        &self.client,
                        item,
                        file_name,
                        Some(image_bytes),
                        None,
                        &creds.custom_headers,
                        &creds.custom_parameters,
                    )
                    .await
                }
            };

            match res {
                Ok(mut ok_res) if !ok_res.is_error() => {
                    self.post_process_result(settings, &mut ok_res, creds, custom_uploader)
                        .await;
                    return Ok(ok_res);
                }
                Ok(err_res) => last_res = err_res,
                Err(e) => {
                    last_res.errors.push(e.to_string());
                }
            }
        }

        Ok(last_res)
    }

    pub async fn upload_text(
        &self,
        settings: &TaskSettings,
        file_name: &str,
        text: &str,
        creds: &ResolvedCredentials,
        custom_uploader: Option<&CustomUploaderItem>,
    ) -> CoreResult<UploadResult> {
        let mut res = match settings.text_uploader {
            BuiltinTextUploader::Pastebin => self.upload_pastebin(file_name, text, creds).await?,
            BuiltinTextUploader::GitHubGist => {
                self.upload_github_gist(file_name, text, creds).await?
            }
            BuiltinTextUploader::ZeroXZero => {
                self.upload_0x0st(file_name, text.as_bytes()).await?
            }
            BuiltinTextUploader::CustomTextUploader => {
                let item = custom_uploader.ok_or_else(|| {
                    CoreError::InvalidConfig(
                        "No custom uploader (.sxcu) selected for CustomTextUploader".to_string(),
                    )
                })?;
                execute_custom_uploader(
                    &self.client,
                    item,
                    file_name,
                    Some(text.as_bytes()),
                    Some(text),
                    &creds.custom_headers,
                    &creds.custom_parameters,
                )
                .await?
            }
        };

        if !res.is_error() {
            self.post_process_result(settings, &mut res, creds, custom_uploader)
                .await;
        }
        Ok(res)
    }

    pub async fn upload_file(
        &self,
        settings: &TaskSettings,
        file_name: &str,
        file_bytes: &[u8],
        creds: &ResolvedCredentials,
        custom_uploader: Option<&CustomUploaderItem>,
    ) -> CoreResult<UploadResult> {
        let mut res = match settings.file_uploader {
            BuiltinFileUploader::Dropbox => {
                self.upload_dropbox(file_name, file_bytes, creds).await?
            }
            BuiltinFileUploader::NextcloudWebDav => {
                self.upload_nextcloud_webdav(file_name, file_bytes, creds)
                    .await?
            }
            BuiltinFileUploader::Catbox => self.upload_catbox(file_name, file_bytes).await?,
            BuiltinFileUploader::ZeroXZero => self.upload_0x0st(file_name, file_bytes).await?,
            BuiltinFileUploader::TempSh => self.upload_tempsh(file_name, file_bytes).await?,
            BuiltinFileUploader::S3PresignedPut => {
                self.upload_s3_presigned(file_name, file_bytes, creds)
                    .await?
            }
            BuiltinFileUploader::CustomFileUploader => {
                let item = custom_uploader.ok_or_else(|| {
                    CoreError::InvalidConfig(
                        "No custom uploader (.sxcu) selected for CustomFileUploader".to_string(),
                    )
                })?;
                execute_custom_uploader(
                    &self.client,
                    item,
                    file_name,
                    Some(file_bytes),
                    None,
                    &creds.custom_headers,
                    &creds.custom_parameters,
                )
                .await?
            }
        };

        if !res.is_error() {
            self.post_process_result(settings, &mut res, creds, custom_uploader)
                .await;
        }
        Ok(res)
    }

    pub async fn shorten_url(
        &self,
        shortener: BuiltinUrlShortener,
        target_url: &str,
        creds: &ResolvedCredentials,
        custom_uploader: Option<&CustomUploaderItem>,
    ) -> CoreResult<String> {
        match shortener {
            BuiltinUrlShortener::IsGd => {
                let resp = self
                    .client
                    .get("https://is.gd/create.php")
                    .query(&[("format", "simple"), ("url", target_url)])
                    .send()
                    .await?;
                if !resp.status().is_success() {
                    return Err(CoreError::UploadFailed(format!(
                        "is.gd HTTP {}",
                        resp.status()
                    )));
                }
                Ok(resp.text().await?.trim().to_string())
            }
            BuiltinUrlShortener::VGd => {
                let resp = self
                    .client
                    .get("https://v.gd/create.php")
                    .query(&[("format", "simple"), ("url", target_url)])
                    .send()
                    .await?;
                if !resp.status().is_success() {
                    return Err(CoreError::UploadFailed(format!(
                        "v.gd HTTP {}",
                        resp.status()
                    )));
                }
                Ok(resp.text().await?.trim().to_string())
            }
            BuiltinUrlShortener::TinyUrl => {
                let resp = self
                    .client
                    .get("https://tinyurl.com/api-create.php")
                    .query(&[("url", target_url)])
                    .send()
                    .await?;
                if !resp.status().is_success() {
                    return Err(CoreError::UploadFailed(format!(
                        "TinyURL HTTP {}",
                        resp.status()
                    )));
                }
                Ok(resp.text().await?.trim().to_string())
            }
            BuiltinUrlShortener::Bitly => {
                let token = creds
                    .bitly_access_token
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| {
                        CoreError::InvalidConfig(
                            "Bitly access token is not configured in macOS Keychain".to_string(),
                        )
                    })?;
                let resp = self
                    .client
                    .post("https://api-ssl.bitly.com/v4/shorten")
                    .bearer_auth(token)
                    .json(&json!({ "long_url": target_url }))
                    .send()
                    .await?;
                let val: Value = resp.json().await?;
                val.get("link")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .ok_or_else(|| CoreError::UploadFailed(format!("Bitly error: {val}")))
            }
            BuiltinUrlShortener::CustomUrlShortener => {
                let item = custom_uploader.ok_or_else(|| {
                    CoreError::InvalidConfig(
                        "No custom uploader (.sxcu) selected for CustomUrlShortener".to_string(),
                    )
                })?;
                let res = execute_custom_uploader(
                    &self.client,
                    item,
                    "url.txt",
                    None,
                    Some(target_url),
                    &creds.custom_headers,
                    &creds.custom_parameters,
                )
                .await?;
                if res.is_error() {
                    return Err(CoreError::UploadFailed(res.errors.join("; ")));
                }
                Ok(res.url)
            }
        }
    }

    pub fn build_share_service_url(service: UrlSharingService, target_url: &str) -> String {
        let encoded =
            percent_encoding::utf8_percent_encode(target_url, percent_encoding::NON_ALPHANUMERIC)
                .to_string();
        match service {
            UrlSharingService::Email => format!("mailto:?body={encoded}"),
            UrlSharingService::Reddit => format!("https://www.reddit.com/submit?url={encoded}"),
            UrlSharingService::LinkedIn => {
                format!("https://www.linkedin.com/sharing/share-offsite/?url={encoded}")
            }
            UrlSharingService::Pinterest => {
                format!("https://pinterest.com/pin/create/button/?url={encoded}&media={encoded}")
            }
            UrlSharingService::GoogleImageSearch => {
                format!("https://lens.google.com/uploadbyurl?url={encoded}")
            }
            UrlSharingService::BingVisualSearch => {
                format!("https://www.bing.com/images/searchbyimage?cbir=sbi&imgurl={encoded}")
            }
        }
    }

    async fn post_process_result(
        &self,
        settings: &TaskSettings,
        res: &mut UploadResult,
        creds: &ResolvedCredentials,
        custom_uploader: Option<&CustomUploaderItem>,
    ) {
        if settings.url_regex_replace_enabled
            && !settings.url_regex_pattern.is_empty()
            && let Ok(re) = Regex::new(&settings.url_regex_pattern)
        {
            res.url = re
                .replace_all(&res.url, settings.url_regex_replacement.as_str())
                .to_string();
        }

        if settings.result_force_https && res.url.starts_with("http://") {
            res.url = res.url.replacen("http://", "https://", 1);
        }

        let should_shorten = (settings.after_upload_tasks
            & crate::models::after_upload_flags::USE_URL_SHORTENER)
            != 0
            || (settings.auto_shorten_url_length > 0
                && res.url.len() > settings.auto_shorten_url_length);

        if should_shorten && !res.url.is_empty() {
            match self
                .shorten_url(settings.url_shortener, &res.url, creds, custom_uploader)
                .await
            {
                Ok(short) => res.shortened_url = short,
                Err(e) => res.errors.push(format!("URL shortener error: {e}")),
            }
        }

        if (settings.after_upload_tasks & crate::models::after_upload_flags::SHARE_URL) != 0 {
            res.share_url =
                Self::build_share_service_url(settings.url_sharing_service, res.primary_url());
        }
    }

    async fn upload_imgur(
        &self,
        file_name: &str,
        bytes: &[u8],
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let started = Instant::now();
        let auth_header = if let Some(ref bearer) = creds.imgur_bearer_token
            && !bearer.is_empty()
        {
            format!("Bearer {bearer}")
        } else {
            let cid = creds
                .imgur_client_id
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or(DEFAULT_IMGUR_CLIENT_ID);
            format!("Client-ID {cid}")
        };

        let part =
            reqwest::multipart::Part::bytes(bytes.to_vec()).file_name(file_name.to_string());
        let form = reqwest::multipart::Form::new().part("image", part);

        let resp = self
            .client
            .post("https://api.imgur.com/3/image")
            .header(reqwest::header::AUTHORIZATION, auth_header)
            .multipart(form)
            .send()
            .await?;

        let status = resp.status();
        let text = resp.text().await?;
        let elapsed_ms = started.elapsed().as_millis() as u64;
        let json_val: Value = serde_json::from_str(&text).unwrap_or(Value::Null);

        if status.is_success()
            && let Some(data) = json_val.get("data")
        {
            let link = data
                .get("link")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            let id = data.get("id").and_then(|v| v.as_str()).unwrap_or_default();
            let deletehash = data
                .get("deletehash")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let thumb = if !id.is_empty() {
                format!("https://i.imgur.com/{id}m.png")
            } else {
                String::new()
            };
            let del = if !deletehash.is_empty() {
                format!("https://imgur.com/delete/{deletehash}")
            } else {
                String::new()
            };
            return Ok(UploadResult {
                url: link,
                thumbnail_url: thumb,
                deletion_url: del,
                host: "Imgur".to_string(),
                response_text: text,
                upload_duration_ms: elapsed_ms,
                ..Default::default()
            });
        }

        Ok(UploadResult {
            host: "Imgur".to_string(),
            response_text: text.clone(),
            upload_duration_ms: elapsed_ms,
            errors: vec![format!("Imgur HTTP {}: {}", status.as_u16(), text)],
            ..Default::default()
        })
    }

    async fn upload_vgyme(
        &self,
        file_name: &str,
        bytes: &[u8],
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let userkey = creds
            .vgyme_user_key
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig("vgy.me user key is required in Keychain".to_string())
            })?;
        let started = Instant::now();
        let part =
            reqwest::multipart::Part::bytes(bytes.to_vec()).file_name(file_name.to_string());
        let form = reqwest::multipart::Form::new()
            .text("userkey", userkey.to_string())
            .part("file", part);

        let resp = self
            .client
            .post("https://vgy.me/upload")
            .multipart(form)
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        let val: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        let is_err = !status.is_success()
            || val.get("error").and_then(|v| v.as_bool()).unwrap_or(false);

        Ok(UploadResult {
            url: val
                .get("image")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            deletion_url: val
                .get("delete")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            host: "vgy.me".to_string(),
            response_text: text.clone(),
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if is_err {
                vec![format!("vgy.me error: {text}")]
            } else {
                Vec::new()
            },
            ..Default::default()
        })
    }

    async fn upload_catbox(&self, file_name: &str, bytes: &[u8]) -> CoreResult<UploadResult> {
        let started = Instant::now();
        let part =
            reqwest::multipart::Part::bytes(bytes.to_vec()).file_name(file_name.to_string());
        let form = reqwest::multipart::Form::new()
            .text("reqtype", "fileupload")
            .part("fileToUpload", part);
        let resp = self
            .client
            .post("https://catbox.moe/user/api.php")
            .multipart(form)
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        let trimmed = text.trim().to_string();
        let ok = status.is_success() && trimmed.starts_with("http");
        Ok(UploadResult {
            url: if ok { trimmed.clone() } else { String::new() },
            host: "catbox.moe".to_string(),
            response_text: text,
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if ok {
                Vec::new()
            } else {
                vec![format!("catbox.moe HTTP {}: {}", status.as_u16(), trimmed)]
            },
            ..Default::default()
        })
    }

    async fn upload_0x0st(&self, file_name: &str, bytes: &[u8]) -> CoreResult<UploadResult> {
        let started = Instant::now();
        let part =
            reqwest::multipart::Part::bytes(bytes.to_vec()).file_name(file_name.to_string());
        let form = reqwest::multipart::Form::new().part("file", part);
        let resp = self
            .client
            .post("https://0x0.st")
            .multipart(form)
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        let trimmed = text.trim().to_string();
        let ok = status.is_success() && trimmed.starts_with("http");
        Ok(UploadResult {
            url: if ok { trimmed.clone() } else { String::new() },
            host: "0x0.st".to_string(),
            response_text: text,
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if ok {
                Vec::new()
            } else {
                vec![format!("0x0.st HTTP {}: {}", status.as_u16(), trimmed)]
            },
            ..Default::default()
        })
    }

    async fn upload_tempsh(&self, file_name: &str, bytes: &[u8]) -> CoreResult<UploadResult> {
        let started = Instant::now();
        let part =
            reqwest::multipart::Part::bytes(bytes.to_vec()).file_name(file_name.to_string());
        let form = reqwest::multipart::Form::new().part("file", part);
        let resp = self
            .client
            .post("https://temp.sh/upload")
            .multipart(form)
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        let trimmed = text.trim().to_string();
        let ok = status.is_success() && trimmed.starts_with("http");
        Ok(UploadResult {
            url: if ok { trimmed.clone() } else { String::new() },
            host: "temp.sh".to_string(),
            response_text: text,
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if ok {
                Vec::new()
            } else {
                vec![format!("temp.sh HTTP {}: {}", status.as_u16(), trimmed)]
            },
            ..Default::default()
        })
    }

    async fn upload_pastebin(
        &self,
        file_name: &str,
        text: &str,
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let dev_key = creds
            .pastebin_api_dev_key
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig("Pastebin API developer key is required".to_string())
            })?;
        let started = Instant::now();
        let mut params = vec![
            ("api_option", "paste"),
            ("api_dev_key", dev_key),
            ("api_paste_code", text),
            ("api_paste_name", file_name),
            ("api_paste_private", "1"),
        ];
        if let Some(ref uk) = creds.pastebin_api_user_key
            && !uk.is_empty()
        {
            params.push(("api_user_key", uk.as_str()));
        }
        let resp = self
            .client
            .post("https://pastebin.com/api/api_post.php")
            .form(&params)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.text().await?;
        let trimmed = body.trim().to_string();
        let ok = status.is_success() && trimmed.starts_with("http");
        Ok(UploadResult {
            url: if ok { trimmed.clone() } else { String::new() },
            host: "Pastebin".to_string(),
            response_text: body,
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if ok {
                Vec::new()
            } else {
                vec![format!("Pastebin error: {trimmed}")]
            },
            ..Default::default()
        })
    }

    async fn upload_github_gist(
        &self,
        file_name: &str,
        text: &str,
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let token = creds
            .github_gist_token
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig(
                    "GitHub Personal Access Token (gist scope) is required in Keychain".to_string(),
                )
            })?;
        let started = Instant::now();
        let payload = json!({
            "description": "Uploaded via Sharaza",
            "public": creds.github_gist_public,
            "files": {
                file_name: { "content": text }
            }
        });
        let resp = self
            .client
            .post("https://api.github.com/gists")
            .bearer_auth(token)
            .header(reqwest::header::ACCEPT, "application/vnd.github+json")
            .json(&payload)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.text().await?;
        let val: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
        let url = val
            .get("html_url")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let ok = status.is_success() && !url.is_empty();
        Ok(UploadResult {
            url,
            host: "GitHub Gist".to_string(),
            response_text: body.clone(),
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if ok {
                Vec::new()
            } else {
                vec![format!("GitHub Gist HTTP {}: {}", status.as_u16(), body)]
            },
            ..Default::default()
        })
    }

    async fn upload_s3_presigned(
        &self,
        file_name: &str,
        bytes: &[u8],
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let presigned = creds
            .s3_presigned_url
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig("S3 PUT endpoint/presigned URL is required".to_string())
            })?;
        let started = Instant::now();
        let target_url = presigned.replace("{filename}", file_name);
        let resp = self
            .client
            .put(&target_url)
            .body(bytes.to_vec())
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        let public_url = if let Some(ref base) = creds.s3_public_base_url
            && !base.is_empty()
        {
            format!("{}/{}", base.trim_end_matches('/'), file_name)
        } else {
            target_url.split('?').next().unwrap_or(&target_url).to_string()
        };
        Ok(UploadResult {
            url: if status.is_success() {
                public_url
            } else {
                String::new()
            },
            host: "Amazon S3".to_string(),
            response_text: text.clone(),
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if status.is_success() {
                Vec::new()
            } else {
                vec![format!("S3 HTTP {}: {}", status.as_u16(), text)]
            },
            ..Default::default()
        })
    }

    async fn upload_dropbox(
        &self,
        file_name: &str,
        bytes: &[u8],
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let token = creds
            .dropbox_access_token
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig(
                    "Dropbox OAuth access token is required in macOS Keychain".to_string(),
                )
            })?;
        let started = Instant::now();
        let dropbox_path = format!("/Sharaza/{file_name}");
        let api_arg = json!({
            "path": dropbox_path,
            "mode": "add",
            "autorename": true,
            "mute": false
        })
        .to_string();

        let up_resp = self
            .client
            .post("https://content.dropboxapi.com/2/files/upload")
            .bearer_auth(token)
            .header("Dropbox-API-Arg", api_arg)
            .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
            .body(bytes.to_vec())
            .send()
            .await?;

        let up_status = up_resp.status();
        let up_text = up_resp.text().await?;
        if !up_status.is_success() {
            return Ok(UploadResult {
                host: "Dropbox".to_string(),
                response_text: up_text.clone(),
                upload_duration_ms: started.elapsed().as_millis() as u64,
                errors: vec![format!("Dropbox upload HTTP {}: {}", up_status.as_u16(), up_text)],
                ..Default::default()
            });
        }

        let up_json: Value = serde_json::from_str(&up_text).unwrap_or(Value::Null);
        let actual_path = up_json
            .get("path_lower")
            .and_then(|v| v.as_str())
            .unwrap_or(&dropbox_path);

        let share_resp = self
            .client
            .post("https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings")
            .bearer_auth(token)
            .json(&json!({ "path": actual_path }))
            .send()
            .await?;
        let share_text = share_resp.text().await?;
        let share_val: Value = serde_json::from_str(&share_text).unwrap_or(Value::Null);
        let shared_url = share_val
            .get("url")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .replace("?dl=0", "?raw=1");

        Ok(UploadResult {
            url: shared_url,
            host: "Dropbox".to_string(),
            response_text: share_text,
            upload_duration_ms: started.elapsed().as_millis() as u64,
            ..Default::default()
        })
    }

    async fn upload_nextcloud_webdav(
        &self,
        file_name: &str,
        bytes: &[u8],
        creds: &ResolvedCredentials,
    ) -> CoreResult<UploadResult> {
        let base_url = creds
            .nextcloud_webdav_url
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidConfig(
                    "Nextcloud/ownCloud WebDAV URL is required in macOS Keychain".to_string(),
                )
            })?;
        let started = Instant::now();
        let target_url = format!("{}/{}", base_url.trim_end_matches('/'), file_name);
        let mut req = self.client.put(&target_url).body(bytes.to_vec());
        if let Some(ref user) = creds.nextcloud_username
            && !user.is_empty()
        {
            req = req.basic_auth(user, creds.nextcloud_password.as_deref());
        }
        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await?;
        Ok(UploadResult {
            url: if status.is_success() {
                target_url
            } else {
                String::new()
            },
            host: "Nextcloud / WebDAV".to_string(),
            response_text: text.clone(),
            upload_duration_ms: started.elapsed().as_millis() as u64,
            errors: if status.is_success() {
                Vec::new()
            } else {
                vec![format!("WebDAV HTTP {}: {}", status.as_u16(), text)]
            },
            ..Default::default()
        })
    }
}

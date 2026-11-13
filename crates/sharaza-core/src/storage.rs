use crate::error::CoreResult;
use crate::models::{AppConfig, HistoryFilter, HistoryItem, HistoryStats, WorkflowPreset};
use crate::sxcu::CustomUploaderItem;
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Thread-safe SQLite manager reproducing `ShareX.HistoryLib.HistoryManagerSQLite`
/// (`ShareX.HistoryLib/Managers/HistoryManagerSQLite.cs`) while storing Sharaza app state.
pub struct StorageManager {
    db_path: PathBuf,
    conn: Mutex<Connection>,
}

impl StorageManager {
    pub fn open<P: AsRef<Path>>(db_path: P) -> CoreResult<Self> {
        let db_path = db_path.as_ref().to_path_buf();
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(&db_path)?;
        conn.busy_timeout(std::time::Duration::from_millis(5000))?;
        let mgr = Self {
            db_path,
            conn: Mutex::new(conn),
        };
        mgr.ensure_schema()?;
        Ok(mgr)
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    fn ensure_schema(&self) -> CoreResult<()> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        // Exact upstream ShareX `History` table schema (`HistoryManagerSQLite.cs` lines 69-81)
        conn.execute_batch(
            r#"
CREATE TABLE IF NOT EXISTS History (
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    FileName TEXT,
    FilePath TEXT,
    DateTime TEXT,
    Type TEXT,
    Host TEXT,
    URL TEXT,
    ThumbnailURL TEXT,
    DeletionURL TEXT,
    ShortenedURL TEXT,
    Tags TEXT
);

CREATE INDEX IF NOT EXISTS idx_history_datetime ON History(DateTime DESC);
CREATE INDEX IF NOT EXISTS idx_history_type ON History(Type);

CREATE TABLE IF NOT EXISTS sharaza_kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sharaza_workflows (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sharaza_custom_uploaders (
    name TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL
);
"#,
        )?;
        Ok(())
    }

    pub fn append_history(&self, item: &mut HistoryItem) -> CoreResult<i64> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let tags_json = if item.tags.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&item.tags)?)
        };
        conn.execute(
            r#"INSERT INTO History
               (FileName, FilePath, DateTime, Type, Host, URL, ThumbnailURL, DeletionURL, ShortenedURL, Tags)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"#,
            params![
                empty_to_none(&item.file_name),
                empty_to_none(&item.file_path),
                item.date_time.to_rfc3339(),
                empty_to_none(&item.item_type),
                empty_to_none(&item.host),
                empty_to_none(&item.url),
                empty_to_none(&item.thumbnail_url),
                empty_to_none(&item.deletion_url),
                empty_to_none(&item.shortened_url),
                tags_json,
            ],
        )?;
        let id = conn.last_insert_rowid();
        item.id = id;
        Ok(id)
    }

    pub fn update_history(&self, item: &HistoryItem) -> CoreResult<()> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let tags_json = if item.tags.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&item.tags)?)
        };
        conn.execute(
            r#"UPDATE History SET
               FileName = ?1, FilePath = ?2, DateTime = ?3, Type = ?4, Host = ?5,
               URL = ?6, ThumbnailURL = ?7, DeletionURL = ?8, ShortenedURL = ?9, Tags = ?10
               WHERE Id = ?11"#,
            params![
                empty_to_none(&item.file_name),
                empty_to_none(&item.file_path),
                item.date_time.to_rfc3339(),
                empty_to_none(&item.item_type),
                empty_to_none(&item.host),
                empty_to_none(&item.url),
                empty_to_none(&item.thumbnail_url),
                empty_to_none(&item.deletion_url),
                empty_to_none(&item.shortened_url),
                tags_json,
                item.id,
            ],
        )?;
        Ok(())
    }

    pub fn delete_history(&self, ids: &[i64]) -> CoreResult<usize> {
        let mut conn = self.conn.lock().expect("sqlite mutex poisoned");
        let tx = conn.transaction()?;
        let mut deleted = 0usize;
        {
            let mut stmt = tx.prepare("DELETE FROM History WHERE Id = ?1")?;
            for id in ids {
                deleted += stmt.execute(params![id])?;
            }
        }
        tx.commit()?;
        Ok(deleted)
    }

    pub fn clear_history(&self) -> CoreResult<()> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute("DELETE FROM History", [])?;
        Ok(())
    }

    pub fn query_history(&self, filter: &HistoryFilter) -> CoreResult<Vec<HistoryItem>> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let limit = if filter.limit == 0 { 200 } else { filter.limit };
        let search_like = filter
            .search_query
            .as_ref()
            .filter(|s| !s.trim().is_empty())
            .map(|s| format!("%{}%", s.trim()));
        let type_filter = filter
            .item_type
            .as_ref()
            .filter(|s| !s.trim().is_empty() && !s.eq_ignore_ascii_case("All"))
            .cloned();
        let host_filter = filter
            .host
            .as_ref()
            .filter(|s| !s.trim().is_empty() && !s.eq_ignore_ascii_case("All"))
            .cloned();

        let mut stmt = conn.prepare(
            r#"SELECT Id, FileName, FilePath, DateTime, Type, Host, URL, ThumbnailURL, DeletionURL, ShortenedURL, Tags
               FROM History
               WHERE (?1 IS NULL OR FileName LIKE ?1 OR FilePath LIKE ?1 OR URL LIKE ?1 OR ShortenedURL LIKE ?1 OR Tags LIKE ?1)
                 AND (?2 IS NULL OR Type = ?2)
                 AND (?3 IS NULL OR Host = ?3)
               ORDER BY Id DESC
               LIMIT ?4 OFFSET ?5"#,
        )?;

        let rows = stmt.query_map(
            params![
                search_like,
                type_filter,
                host_filter,
                limit as i64,
                filter.offset as i64
            ],
            |row| {
                let dt_raw: Option<String> = row.get(3)?;
                let date_time = dt_raw
                    .as_deref()
                    .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                    .map(|dt| dt.with_timezone(&Utc))
                    .unwrap_or_else(Utc::now);
                let tags_raw: Option<String> = row.get(10)?;
                let tags: HashMap<String, String> = tags_raw
                    .as_deref()
                    .and_then(|s| serde_json::from_str(s).ok())
                    .unwrap_or_default();

                Ok(HistoryItem {
                    id: row.get(0)?,
                    file_name: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    file_path: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    date_time,
                    item_type: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                    host: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                    url: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                    thumbnail_url: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
                    deletion_url: row.get::<_, Option<String>>(8)?.unwrap_or_default(),
                    shortened_url: row.get::<_, Option<String>>(9)?.unwrap_or_default(),
                    tags,
                })
            },
        )?;

        let mut items = Vec::new();
        for item in rows {
            items.push(item?);
        }
        Ok(items)
    }

    pub fn history_stats(&self) -> CoreResult<HistoryStats> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let mut stats = HistoryStats::default();
        let mut stmt = conn.prepare("SELECT Type, Host, URL FROM History")?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            ))
        })?;

        for row in rows {
            let (t, host, url) = row?;
            stats.total_count += 1;
            match t.to_ascii_lowercase().as_str() {
                "image" => stats.image_count += 1,
                "video" => stats.video_count += 1,
                "text" => stats.text_count += 1,
                _ => stats.file_count += 1,
            }
            if !url.is_empty() {
                stats.uploaded_count += 1;
            }
            if !host.is_empty() {
                *stats.by_host.entry(host).or_insert(0) += 1;
            }
        }
        Ok(stats)
    }

    /// Migrates upstream ShareX `History.json` array or NDJSON records (`HistoryManagerSQLite.MigrateFromJSON`).
    pub fn import_sharex_history_json(&self, json_text: &str) -> CoreResult<usize> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct ShareXJsonHistoryItem {
            #[serde(default)]
            file_name: String,
            #[serde(default)]
            file_path: String,
            #[serde(default)]
            date_time: Option<String>,
            #[serde(default)]
            r#type: String,
            #[serde(default)]
            host: String,
            #[serde(default, rename = "URL")]
            url: String,
            #[serde(default, rename = "ThumbnailURL")]
            thumbnail_url: String,
            #[serde(default, rename = "DeletionURL")]
            deletion_url: String,
            #[serde(default, rename = "ShortenedURL")]
            shortened_url: String,
            #[serde(default)]
            tags: Option<HashMap<String, String>>,
        }

        let trimmed = json_text.trim();
        let parsed_items: Vec<ShareXJsonHistoryItem> = if trimmed.starts_with('[') {
            serde_json::from_str(trimmed)?
        } else {
            // ShareX JSON history also supports comma-separated top-level objects without outer brackets
            let wrapped = format!("[{}]", trimmed.trim_end_matches(','));
            serde_json::from_str(&wrapped)?
        };

        let mut count = 0usize;
        for raw in parsed_items {
            let dt = raw
                .date_time
                .as_deref()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(Utc::now);
            let mut item = HistoryItem {
                id: 0,
                file_name: raw.file_name,
                file_path: raw.file_path,
                date_time: dt,
                item_type: raw.r#type,
                host: raw.host,
                url: raw.url,
                thumbnail_url: raw.thumbnail_url,
                deletion_url: raw.deletion_url,
                shortened_url: raw.shortened_url,
                tags: raw.tags.unwrap_or_default(),
            };
            self.append_history(&mut item)?;
            count += 1;
        }
        Ok(count)
    }

    pub fn load_app_config(&self) -> CoreResult<AppConfig> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM sharaza_kv WHERE key = 'app_config'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        match raw {
            Some(json) => Ok(serde_json::from_str(&json)?),
            None => {
                let default_cfg = AppConfig::default();
                drop(conn);
                self.save_app_config(&default_cfg)?;
                Ok(default_cfg)
            }
        }
    }

    pub fn save_app_config(&self, config: &AppConfig) -> CoreResult<()> {
        let json = serde_json::to_string_pretty(config)?;
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute(
            "INSERT INTO sharaza_kv (key, value) VALUES ('app_config', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![json],
        )?;
        Ok(())
    }

    pub fn next_auto_increment(&self) -> CoreResult<u64> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let current: u64 = conn
            .query_row(
                "SELECT value FROM sharaza_kv WHERE key = 'auto_increment'",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0);
        let next = current.saturating_add(1);
        conn.execute(
            "INSERT INTO sharaza_kv (key, value) VALUES ('auto_increment', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![next.to_string()],
        )?;
        Ok(current)
    }

    pub fn list_workflows(&self) -> CoreResult<Vec<WorkflowPreset>> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let mut stmt =
            conn.prepare("SELECT payload_json FROM sharaza_workflows ORDER BY name ASC")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(serde_json::from_str(&r?)?);
        }
        Ok(out)
    }

    pub fn save_workflow(&self, preset: &WorkflowPreset) -> CoreResult<()> {
        let json = serde_json::to_string(preset)?;
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute(
            "INSERT INTO sharaza_workflows (id, name, payload_json) VALUES (?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, payload_json = excluded.payload_json",
            params![preset.id, preset.name, json],
        )?;
        Ok(())
    }

    pub fn delete_workflow(&self, id: &str) -> CoreResult<()> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute("DELETE FROM sharaza_workflows WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn list_custom_uploaders(&self) -> CoreResult<Vec<CustomUploaderItem>> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        let mut stmt = conn
            .prepare("SELECT payload_json FROM sharaza_custom_uploaders ORDER BY name ASC")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(serde_json::from_str(&r?)?);
        }
        Ok(out)
    }

    pub fn save_custom_uploader(&self, item: &CustomUploaderItem) -> CoreResult<()> {
        let key = item.display_name();
        let json = serde_json::to_string_pretty(item)?;
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute(
            "INSERT INTO sharaza_custom_uploaders (name, payload_json) VALUES (?1, ?2)
             ON CONFLICT(name) DO UPDATE SET payload_json = excluded.payload_json",
            params![key, json],
        )?;
        Ok(())
    }

    pub fn delete_custom_uploader(&self, name: &str) -> CoreResult<()> {
        let conn = self.conn.lock().expect("sqlite mutex poisoned");
        conn.execute(
            "DELETE FROM sharaza_custom_uploaders WHERE name = ?1",
            params![name],
        )?;
        Ok(())
    }
}

fn empty_to_none(s: &str) -> Option<&str> {
    if s.is_empty() { None } else { Some(s) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_history_roundtrip_and_sharex_json_migration() {
        let tmp = std::env::temp_dir().join(format!(
            "sharaza_test_history_{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        let store = StorageManager::open(&tmp).unwrap();

        let mut tags = HashMap::new();
        tags.insert("ProcessName".to_string(), "Xcode".to_string());
        tags.insert("WindowTitle".to_string(), "SharazaApp.swift".to_string());

        let mut item = HistoryItem {
            id: 0,
            file_name: "2026-11-13_shot.png".to_string(),
            file_path: "/tmp/2026-11-13_shot.png".to_string(),
            date_time: Utc::now(),
            item_type: "Image".to_string(),
            host: "Imgur".to_string(),
            url: "https://i.imgur.com/test.png".to_string(),
            thumbnail_url: String::new(),
            deletion_url: "https://imgur.com/delete/xyz".to_string(),
            shortened_url: "https://is.gd/abc".to_string(),
            tags,
        };
        let id = store.append_history(&mut item).unwrap();
        assert!(id > 0);

        let rows = store
            .query_history(&HistoryFilter {
                search_query: Some("Xcode".to_string()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].url, "https://i.imgur.com/test.png");
        assert_eq!(rows[0].tags.get("ProcessName").unwrap(), "Xcode");

        let sharex_json = r#"[
          {
            "FileName": "imported.png",
            "FilePath": "/Users/demo/imported.png",
            "DateTime": "2026-11-10T12:00:00Z",
            "Type": "Image",
            "Host": "vgy.me",
            "URL": "https://vgy.me/u/imp.png"
          }
        ]"#;
        let imported = store.import_sharex_history_json(sharex_json).unwrap();
        assert_eq!(imported, 1);

        let stats = store.history_stats().unwrap();
        assert_eq!(stats.total_count, 2);
        assert_eq!(stats.image_count, 2);
        assert_eq!(stats.uploaded_count, 2);

        let _ = fs::remove_file(&tmp);
    }
}

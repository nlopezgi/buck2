/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under both the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree and the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree.
 */

use std::collections::HashMap;
use std::sync::Arc;

use allocative::Allocative;
use anyhow::Context;
use buck2_common::invocation_paths::InvocationPaths;
use buck2_common::legacy_configs::LegacyBuckConfig;
use buck2_core::fs::fs_util;
use buck2_core::fs::paths::abs_norm_path::AbsNormPath;
use buck2_core::fs::paths::file_name::FileName;
use buck2_core::fs::project::ProjectRoot;
use buck2_core::rollout_percentage::RolloutPercentage;
use buck2_execute::digest_config::DigestConfig;
use buck2_execute::execute::blocking::BlockingExecutor;
use buck2_execute::materialize::materializer::MaterializationMethod;
use buck2_execute_impl::materializers::deferred::DeferredMaterializerConfigs;
use buck2_execute_impl::materializers::sqlite::MaterializerState;
use buck2_execute_impl::materializers::sqlite::MaterializerStateSqliteDb;
use buck2_execute_impl::materializers::sqlite::DB_SCHEMA_VERSION;
use chrono::Utc;
use derive_more::Display;

#[derive(Allocative)]
pub struct DiskStateOptions {
    pub sqlite_materializer_state: bool,
    // In future, this will include the config for dep files on disk
}

#[derive(Display, Allocative)]
pub struct MaterializerStateIdentity(String);

impl DiskStateOptions {
    pub fn new(
        root_config: &LegacyBuckConfig,
        materialization_method: MaterializationMethod,
    ) -> anyhow::Result<Self> {
        let sqlite_materializer_state = matches!(
            // We can only enable materializer state on sqlite if you use deferred materializer
            materialization_method,
            MaterializationMethod::Deferred | MaterializationMethod::DeferredSkipFinalArtifacts
        ) && root_config
            .parse::<RolloutPercentage>("buck2", "sqlite_materializer_state")?
            .unwrap_or_else(RolloutPercentage::never)
            .roll();
        Ok(Self {
            sqlite_materializer_state,
        })
    }
}

pub(crate) async fn maybe_initialize_materializer_sqlite_db(
    options: &DiskStateOptions,
    paths: &InvocationPaths,
    io_executor: Arc<dyn BlockingExecutor>,
    root_config: &LegacyBuckConfig,
    deferred_materializer_configs: &DeferredMaterializerConfigs,
    fs: ProjectRoot,
    digest_config: DigestConfig,
) -> anyhow::Result<(
    Option<(MaterializerStateSqliteDb, MaterializerStateIdentity)>,
    Option<MaterializerState>,
)> {
    if !options.sqlite_materializer_state {
        // When sqlite materializer state is disabled, we should always delete the materializer state db.
        // Otherwise, artifacts in buck-out will diverge from the state stored in db.
        io_executor
            .execute_io_inline(|| fs.remove_path_recursive(&paths.materializer_state_path()))
            .await?;
        return Ok((None, None));
    }

    let timestamp_key = "timestamp_on_initialization";

    let mut metadata = buck2_events::metadata::collect();
    let timestamp_on_initialization = Utc::now().to_rfc3339();
    metadata.insert(timestamp_key.to_owned(), timestamp_on_initialization);

    let mut versions = HashMap::from([
        ("schema_version".to_owned(), DB_SCHEMA_VERSION.to_string()),
        (
            "defer_write_actions".to_owned(),
            deferred_materializer_configs
                .defer_write_actions
                .to_string(),
        ),
    ]);
    if let Some(buckconfig_version) =
        root_config.parse("buck2", "sqlite_materializer_state_version")?
    {
        versions.insert("buckconfig_version".to_owned(), buckconfig_version);
    }
    if let Some(hostname) = metadata.get("hostname") {
        versions.insert("hostname".to_owned(), hostname.to_owned());
    }

    // Most things in the rest of `metadata` should go in the metadata sqlite table.
    // TODO(scottcao): Narrow down what metadata we need and and insert them into the
    // metadata table before a feature rollout.
    let (mut db, load_result) = MaterializerStateSqliteDb::initialize(
        paths.materializer_state_path(),
        versions,
        metadata,
        io_executor,
        digest_config,
    )
    .await?;

    let identity = db
        .created_by_table()
        .get(timestamp_key)
        .context("Error reading creation metadata")?
        .map(MaterializerStateIdentity)
        .with_context(|| format!("disk state is missing `{}`", timestamp_key))?;

    let materializer_state = match load_result {
        Ok(s) => Some(s),
        // We know path not found or version mismatch is normal, but some sqlite failures
        // are worth logging here. TODO(scottcao): Refine our error types and figure out what
        // errors to log
        Err(_e) => None,
    };
    Ok((Some((db, identity)), materializer_state))
}

// Once we start storing disk state in the cache directory, we need to make sure
// buck2 always deletes the cache directory if the cache is disabled.
// Otherwise, buck-out state can diverge from the state of on-disk cache when
// cache is disabled, causing buck2 to use stale cache when reading from the
// cache is re-enabled. One way this can happen is that someone can build on
// an older revision with a buck2 that doesn't understand the cache directory
// in between 2 builds on newer revisions with buck2 that reads from the cache
// (for ex., as a part of a bisect), then the state can become stale.
// There are 2 (not foolproof) mitigations planned:
// 1) Read from the logs what the last buck2 invocation was and check that the
// last buck2 supported on-disk state. If not, delete the disk state.
// 2) Start always deleting the cache directory now until we add support for disk
// state in buck2.
// The following implements mitigation #2 by always deleting disk state.

/// Recursively deletes all elements under `cache_dir_path`, except for known dirs
/// listed in `known_dir_names`.
pub(crate) fn delete_unknown_disk_state(
    cache_dir_path: &AbsNormPath,
    known_dir_names: &[&FileName],
    fs: ProjectRoot,
) -> anyhow::Result<()> {
    let res: anyhow::Result<()> = try {
        if cache_dir_path.exists() {
            for entry in fs_util::read_dir(cache_dir_path)? {
                let entry = entry?;
                let filename = entry.file_name();
                let filename = filename
                    .to_str()
                    .context("Filename is not UTF-8")
                    .and_then(FileName::new)?;

                // known_dir_names is always small, so this contains isn't expensive
                if !known_dir_names.contains(&filename) || !entry.path().is_dir() {
                    fs.remove_path_recursive(&cache_dir_path.join(filename))?;
                }
            }
        }
    };

    res.with_context(|| {
        format!(
            "deleting unrecognized caches in {} to prevent them from going stale",
            &cache_dir_path
        )
    })
}

#[cfg(test)]
mod tests {
    use buck2_core::fs::paths::forward_rel_path::ForwardRelativePath;
    use buck2_core::fs::project::ProjectRootTemp;
    use buck2_core::fs::project_rel_path::ProjectRelativePath;
    use dupe::Dupe;

    use super::*;

    #[test]
    fn test_delete_all_from_cache_dir() {
        let fs_temp = ProjectRootTemp::new().unwrap();
        let fs = fs_temp.path();
        let cache_dir_path = fs.resolve(ProjectRelativePath::unchecked_new("buck-out/v2/cache"));
        let materializer_state_db = cache_dir_path.join(ForwardRelativePath::unchecked_new(
            "materializer_state/db.sqlite",
        ));
        let command_hashes_db = cache_dir_path.join(ForwardRelativePath::unchecked_new(
            "command_hashes/db.sqlite",
        ));
        fs.create_file(&materializer_state_db, false).unwrap();
        fs.create_file(&command_hashes_db, false).unwrap();
        assert!(materializer_state_db.exists());
        assert!(command_hashes_db.exists());

        delete_unknown_disk_state(&cache_dir_path, &[], fs.dupe()).unwrap();

        assert!(!materializer_state_db.exists());
        assert!(!command_hashes_db.exists());
    }

    #[test]
    fn test_delete_from_cache_dir_with_known_dirs() {
        let fs_temp = ProjectRootTemp::new().unwrap();
        let fs = fs_temp.path();
        let cache_dir_path = fs.resolve(ProjectRelativePath::unchecked_new("buck-out/v2/cache"));
        let materializer_state_db = cache_dir_path.join(ForwardRelativePath::unchecked_new(
            "materializer_state/db.sqlite",
        ));
        let command_hashes_db = cache_dir_path.join(ForwardRelativePath::unchecked_new(
            "command_hashes/db.sqlite",
        ));
        fs.create_file(&materializer_state_db, false).unwrap();
        fs.create_file(&command_hashes_db, false).unwrap();
        assert!(materializer_state_db.exists());
        assert!(command_hashes_db.exists());

        delete_unknown_disk_state(
            &cache_dir_path,
            &[FileName::unchecked_new("materializer_state")],
            fs.dupe(),
        )
        .unwrap();

        assert!(materializer_state_db.exists());
        assert!(!command_hashes_db.exists());
    }
}

# ArchivePar2 Shell Automation Utility

This utility suite provides a robust framework for **data backups focusing on long-term integrity**. By combining **Zstandard (zstd)** for high-speed compression, **PAR2** for error correction, and **BLAKE3** for cryptographic hashing, it ensures that your archived data is not only compressed but also recoverable and verifiable.

---

## Quick Start & Dependencies

### Technical Dependencies

To function correctly, the suite requires the following tools to be installed on your system:

* **`zstd`**: High-performance compression.
* **`par2`**: Reed-Solomon error correction.
* **`pv`** (Pipe Viewer): For real-time progress bars.
* **`b3sum`**: For ultra-fast BLAKE3 hashing.

# 🚀 Quick Start

### Installation & Environment Set Up

Clone the repository directly into your dedicated scripts workspace directory:

```bash
# Create and jump into your scripts directory
mkdir -p ~/scripts && cd ~/scripts

# Clone the orchestrator repository
git clone https://github.com/Kilobyte4621/archivepar2.git
```

Source the scripts directly inside your active configuration file (`~/.bashrc` or `~/.zshrc`) to map it as a persistent shell utility:

```bash
echo "source ~/scripts/archivepar2/archivepar2.sh" >> ~/.bashrc
echo "source ~/scripts/archivepar2/restorepar2.sh" >> ~/.bashrc
echo "source ~/scripts/archivepar2/backup.sh" >> ~/.bashrc
echo "source ~/scripts/archivepar2/folderbkp.sh" >> ~/.bashrc
source ~/.bashrc
```
> 💡 Pro-Tip (Dynamic Sourcing): If you prefer not to hardcode individual source lines manually, you can use the `add2bash` utility available in the **shellutilities** repository. This tool allows you to dynamically sweep, clean, and import an entire directory of independent .sh function scripts directly into your active profile environment in one clean sweep.

Once sourced, invoke the engine natively from anywhere in your filesystem simply by typing:

```bash
cd /backup/destination/location
backup /path/to/origin/location1
folderbkp /path/to/origin/location2
```

And to restore backed-up data:

```bash
cd /restoring/backup/location
restorepar2 /backup/destination/location/location1-bak extract
```
---

## 1. Core Component: `archivepar2` (v0.17)

The `archivepar2` function is the primary archive creation engine. It transforms a target directory into a compressed, integrity-verified, and error-recoverable backup using TAR, Zstandard, BLAKE3, and PAR2.

Starting with **v0.17**, the utility uses a **versioned backup layout** with atomic publication, isolation of in-progress work, and configurable retention. The current implementation emphasizes synchronous integrity verification, controlled process lifecycles, interruption handling, transactional replacement of backups, and reliable resource cleanup.

### Key Functionalities

- **Intelligent Path Sanitization:** Sanitizes the source folder name for the backup directory, converting it to lowercase, replacing spaces with underscores, and removing special characters.
- **Flexible Archiving Modes:**
  - **Split Mode (Default):** Splits the compressed archive into parts, defaulting to **2 GB** per part, facilitating storage and transfer.
  - **Single Mode (`--SINGLE`):** Creates a single `.tar.zst` archive without splitting.
- **Configurable Integrity Checks:**
  - **Default Mode:** Performs a post-compression `tar --diff` check against the source directory.
  - **Fast Mode (`--FAST`):** Skips the post-compression TAR content comparison.
- **Cryptographic Integrity Manifests:** Generates a `.blake3` manifest containing the archive's global BLAKE3 hash and the hashes of the archive parts, enabling later integrity verification.
- **Transactional Replacement (v0.17):** The new archive is generated in an isolated staging directory, validated end-to-end, and only published on success. If anything fails before publication, the previous backup remains intact and usable.
- **Versioned Layout (v0.17):** Each backup is stored in its own `v<timestamp>/` directory, with a `current` symlink pointing to the active version. Publication uses atomic directory rename plus an atomic symlink swap.
- **Automatic Migration (v0.17):** Existing legacy layouts are migrated to the versioned layout automatically, preserving all files. Use `--NO-MIGRATE` to opt out.
- **Configurable Retention (v0.17):** Old versions can be pruned automatically based on a configurable count (`--KEEP N` or `ARCHIVEPAR2_KEEP`).
- **Layered Locking (v0.17):** Prevents concurrent invocations against the same backup directory from corrupting each other, using multiple layers (flock, mkdir lockdir, PID file) so it degrades gracefully across filesystems.
- **Synchronous Hash Generation:** Coordinates global BLAKE3 hash generation with the main workflow, checks the hashing process's exit status, and validates the manifest before proceeding to PAR2 generation.
- **Strict Manifest Validation:** Validates the global hash entry's format and rejects malformed, missing, or duplicate entries.
- **Managed Background Processes:** Launches long-running jobs in controlled process groups, tracks their status, and handles termination and reaping.
- **Interruption and Failure Handling:** Handles termination signals and coordinates cleanup when a job fails or the operation is interrupted.
- **Centralized Resource Cleanup:** Tracks temporary files, FIFOs, status files, process IDs, and process groups so cleanup can remove temporary resources and attempt to terminate remaining jobs.
- **Shell-State Restoration:** Restores the caller's working directory, `pipefail` setting, signal traps, and relevant shell options after execution.
- **Performance Logging:** Maintains a session log containing execution details, performance metrics, and operation status.

### Arguments and Flags

- `--SINGLE`: Creates one `.tar.zst` archive instead of splitting it into multiple parts.
- `--FAST`: Skips the post-compression `tar --diff` content integrity check.
- `--KEEP N` (v0.17): Retains **N** old versions in addition to the active version. Default: `3`.
- `--NO-MIGRATE` (v0.17): Disables the automatic migration from the legacy layout. When set, `archivepar2` operates in the legacy layout and does not create `v<timestamp>/` directories or the `current` symlink.
- `Size` (e.g., `500M`, `4G`): Sets the maximum size of each archive part in split mode. The default is `2G`.

#### Environment Variables

- `ARCHIVEPAR2_KEEP=N` (v0.17): Fallback for `--KEEP N`. The command-line flag has precedence. Used only when `--KEEP` is not passed.

### Detailed Workflow of `archivepar2`

#### 1. Environment and Argument Handling

- Validates the input and requires a source directory.
- Parses `--SINGLE`, `--FAST`, `--KEEP N`, `--NO-MIGRATE`, and an optional custom split size.
- Resolves `--KEEP` precedence: flag > `ARCHIVEPAR2_KEEP` > default `3`.
- Enables `pipefail` during execution so that failures in commands within pipelines, such as `tar`, `zstd`, or other pipeline components, are not silently ignored.
- Preserves the relevant shell state so temporary changes do not unintentionally affect the calling shell.

#### 2. Path Sanitization and Session Logging

- Sanitizes the source folder name to construct the backup directory name.
- Initializes a session log recording relevant execution details, including the start timestamp, source path, selected arguments, and performance information.
- Uses consistent helper-function naming to distinguish internal implementation details from public functionality.

#### 3. Locking and Concurrency Control (v0.17)

Before any heavy work, `archivepar2` acquires a **per-backup-directory lock** to prevent two concurrent invocations from corrupting each other. The lock is acquired using a multi-layer strategy:

1. **Layer 1 — `flock(2)`:** A file lock on `.archivepar2.lock`, held via file descriptor 9. If `flock` is available, this is the primary mechanism.
2. **Layer 2 — `mkdir lockdir`:** An atomic directory creation of `.archivepar2.lockdir/`. This works on any POSIX-compliant filesystem and is the universal fallback.
3. **Layer 3 — PID metadata:** Inside `.archivepar2.lockdir/`, `pid`, `time`, and `cmd` files identify the process currently holding the lock.

If any layer indicates the lock is held by another active process, `archivepar2` aborts immediately, without consuming CPU on the pipeline. A message identifies the holder PID, start time, command, and the directory to remove if a manual override is needed.

**Stale lock recovery:** If a lockdir is found but its recorded PID is not an active `archivepar2` process, the lockdir is considered stale and removed automatically.

**Filesystem caveat:** On filesystems with unreliable locking semantics (SSHFS, some FUSE mounts, CIFS, SMB, 9P), a warning is logged. In these cases, `mkdir lockdir` provides best-effort protection but is not a hard guarantee.

#### 4. Layout Detection and Migration (v0.17)

`archivepar2` recognizes three layouts:

- **legacy:** Files (`<out>.tar.zst.part-*`, `<out>.blake3`, `<out>.par2`, etc.) sit directly in the backup directory. This is the v0.16 and earlier layout.
- **versioned:** Each backup lives in its own `v<timestamp>/` subdirectory, and a `current` symlink points to the active version.
- **empty:** No recognizable backup artifacts present.

Unless `--NO-MIGRATE` is set, an existing legacy layout is migrated automatically:

1. A new version directory `v<timestamp>/` is created.
2. All legacy artifacts are moved into it (`mv`, not copy — atomic on the same filesystem).
3. The `current` symlink is created pointing to the new version directory.

The migration is **non-destructive**: if a step fails, the files are moved back and the migration aborts, leaving the legacy layout intact. On the next successful run, the migration retries.

If `--NO-MIGRATE` is set and the layout is legacy, `archivepar2` continues operating in the legacy layout. New backups are published directly into the backup directory (files sit at the top level, no `current` symlink). This preserves backward compatibility for users who prefer the flat layout.

#### 5. Staging and Isolation (v0.17)

Generation happens in an isolated staging directory `.staging.<run_id>/` inside the backup directory. All heavy work is performed there:

- Compression (TAR → Zstandard → split)
- BLAKE3 manifest generation
- TAR content integrity check
- PAR2 recovery data generation

The active backup is **not touched** until publication. If the operation fails, is interrupted, or the validation does not pass, the staging directory is removed and the previous backup remains intact and usable.

Staging is placed inside the backup directory to guarantee it resides on the same filesystem as the final destination. This allows publication via `rename(2)`, which is atomic and does not copy data.

Orphaned staging directories from prior interrupted runs are cleaned up automatically on the next successful lock acquisition.

#### 6. Compression and Archive Splitting

- **Split Mode (Default):** Compresses the source directory and divides the resulting archive into parts according to the configured maximum size. The default part size is `2G`.
- **Single Mode:** Produces one `.tar.zst` file without splitting.
- Uses progress reporting during the relevant archive-processing stages.

#### 7. TAR Content Integrity Verification

- Unless `--FAST` is specified, runs a post-compression `tar --diff` comparison between the source directory and the compressed archive (read from staging).
- Treats verification as a managed job and checks its completion status before proceeding.
- Stops the operation when the content integrity check fails rather than reporting an unsuccessful archive as successfully verified.

#### 8. BLAKE3 Manifest Generation and Validation

- Generates a BLAKE3 manifest containing the global hash of the complete archive and hashes for its individual archive parts. The manifest is generated in staging.
- Calculates the global BLAKE3 hash during compression and coordinates its completion with the main workflow.
- Uses a FIFO-based communication mechanism and a status file to coordinate the global hashing job with the main function.
- Checks the hashing process's exit status before treating the manifest as complete.
- Validates the global manifest entry, requiring a correctly formatted 64-character hexadecimal BLAKE3 digest and rejecting missing, malformed, or duplicate global entries.
- Applies managed process and status handling to hashing operations used during the workflow, including resume-related verification where applicable.
- Validates the manifest before proceeding to PAR2 generation.

#### 9. PAR2 Recovery Data Generation

- Generates PAR2 recovery data in staging to provide redundancy that can help repair damaged or missing archive data, subject to the available recovery blocks.
- Manages the PAR2 job's process lifecycle and checks its outcome rather than relying solely on whether the command was launched.
- Routes failures through the function's error-handling and cleanup mechanisms.

#### 10. Publication and Versioned Commit (v0.17)

Once generation, validation, and PAR2 creation have succeeded in staging, `archivepar2` publishes the result.

**In versioned mode** (`use_legacy_commit=0`):

1. The staging directory is renamed to a new `v<timestamp>/` directory. This is a single `rename(2)` on the same filesystem — atomic and immediate.
2. A `current.tmp` symlink is created pointing to the new version.
3. `current.tmp` is renamed over `current` via `mv -T`. This is the atomic publication point.
4. Old versions beyond the retention count are pruned.

Consumers that resolve `current` see either the old version or the new version, never an inconsistent state.

**In legacy mode** (`use_legacy_commit=1`, used when `--NO-MIGRATE` is set):

1. Each file in staging is moved into the backup directory, in the order: parts → manifest → PAR2.
2. The staging directory is removed.
3. Obsolete parts from the previous backup that are not overwritten by the new one are pruned (based on the newly published manifest).

This preserves the flat layout but does not provide the same atomicity guarantee as versioned mode.

#### 11. Retention (v0.17)

In versioned mode, after a successful commit, `archivepar2` prunes old versions. The active version (`current`) is always preserved. At most `KEEP` old versions are retained.

The count is resolved from, in order of precedence:

1. `--KEEP N` on the command line
2. `ARCHIVEPAR2_KEEP` environment variable
3. Default: `3`

For example, with `--KEEP 3`, up to 4 versions are kept (active + 3 old).

#### 12. Background Process Lifecycle Management

- Launches background jobs through a dedicated helper that establishes and tracks process groups.
- Uses a process-group handshake and acknowledgement mechanism to coordinate job startup and registration.
- Tracks job process IDs and process-group IDs so the function can monitor and manage jobs consistently.
- Waits for managed jobs and checks their exit statuses.
- Handles termination requests, including escalation from `SIGTERM` to `SIGKILL` when necessary.
- Registers process groups that remain after forced termination so centralized cleanup can make another termination attempt.
- Treats unresolved process termination as a failure condition instead of assuming that sending a signal guarantees the process has exited.

#### 13. Centralized Cleanup and Shell-State Restoration

- Centralizes cleanup for success, failure, and interruption paths.
- Releases the lock and removes the staging directory.
- Removes temporary resources created during execution, including temporary files, FIFOs, and job status files.
- Attempts to terminate and reap tracked background jobs and process groups.
- Restores the original working directory and relevant shell settings, including the previous `pipefail` state, signal traps, and `nullglob` state.
- Uses a consistent internal helper prefix to reduce the risk of collisions with unrelated shell functions and variables.

#### 14. Error Handling and Final Status

- Reports missing or invalid input and other detected failures explicitly.
- Propagates errors from managed jobs and verification steps instead of treating successful process launch as proof of successful completion.
- Uses cleanup paths to handle failed operations and interrupted execution.
- Retains performance reporting and final status information in the session log.

### Files Created by `archivepar2`

The utility creates several files and directories in the backup directory (`<out>-bak/`). Some of them are part of the backup itself and persist; others are infrastructure and are cleaned up automatically.

| Path | Purpose | Lifecycle |
|---|---|---|
| `v<timestamp>/` | One version of the backup (parts, manifest, PAR2) | Persists; pruned by retention |
| `current` | Symlink to the active version | Persists; atomically swapped on each new version |
| `<out>.log` | Session log, appended on every run | Persists; never rotated (by design) |
| `.archivepar2.lock` | Lock file used by `flock(2)` | **Persists** (see note below) |
| `.archivepar2.lockdir/` | Lock directory used by the `mkdir` layer | Created and removed on each run |
| `.staging.<run_id>/` | Isolated generation directory | Created and removed on each run |

#### About `.archivepar2.lock`

The `.archivepar2.lock` file is a **zero-byte file** used to hold a `flock(2)` lock. It is intentionally **not removed** after `archivepar2` finishes.

**Why it stays:**

`flock(2)` associates the lock with the open file descriptor, not with the directory entry. If the file were unlinked at the end of a run, a race could occur:

1. Process A holds the lock, opens a file descriptor to inode X.
2. Process A finishes, closes the descriptor, and unlinks the file. Inode X is scheduled for deletion.
3. Process B, before inode X is actually deleted, opens the file path and gets a file descriptor to inode X.
4. Process C creates a **new** file at the same path, which gets a **different** inode Y.
5. B and C now hold locks on different inodes. They do not block each other.

Keeping the file in place avoids this race. All invocations targeting the same backup directory use the same inode, and `flock(2)` behaves correctly.

**Impact:** None beyond a single hidden 0-byte file in the backup directory. The file is filtered out of the backup parts glob and does not interfere with restore operations.

A future revision may relocate this file to `$XDG_RUNTIME_DIR` to remove the visual clutter without reintroducing the race.

### Version Comparison: v0.14 vs. v0.17

Version 0.17 builds on v0.16 by introducing versioned layout, transactional replacement, layered locking, and configurable retention, while retaining the earlier improvements to BLAKE3 manifest generation, background process management, failure detection, and cleanup.

| Feature | v0.14 | v0.17 |
|---|---|---|
| Archive modes | Split and single-archive modes | Retains split and single-archive modes |
| Split-size configuration | Configurable part sizes | Retains configurable part sizes |
| TAR content verification | Post-compression `tar --diff`, unless `--FAST` is used | Retains the optional comparison and integrates it with managed job-status checks |
| Global BLAKE3 hash | Manifest generation without synchronization safeguards | Global hash calculated during compression, with process-status checks and manifest validation |
| Manifest validation | Less comprehensive validation | Rejects missing, malformed, or duplicate global hash entries |
| Background jobs | Less comprehensive process lifecycle management | Explicit process tracking, process groups, startup coordination, and exit-status checks |
| Interruption handling | Less comprehensive cleanup coordination | Signal handling, termination escalation, and tracked process-group cleanup attempts |
| Temporary resources | Less centralized resource management | Centralized cleanup of temporary files, FIFOs, and status files |
| Shell-state preservation | Less comprehensive restoration | Restores relevant shell state, including `pipefail`, traps, working directory, and `nullglob` |
| Error reporting | Existing error handling | Stronger failure detection across hashing, verification, and managed jobs |
| **Backup layout** | Flat (files directly in the backup directory) | **Versioned** (`v<timestamp>/` + `current` symlink), with automatic legacy migration |
| **Publication** | Direct write to the backup directory | **Transactional**: staging + atomic publish; previous backup preserved until success |
| **Concurrency** | No protection against concurrent runs | **Layered locking**: `flock` + `mkdir lockdir` + PID metadata |
| **Retention** | None (manual cleanup) | **`--KEEP N`** / `ARCHIVEPAR2_KEEP`, default 3 |
| **Stale parts handling** | Removed at start of next run | Versioned layout isolates parts; obsolete parts pruned only within legacy mode |

#### Main Improvements in v0.17

1. **Versioned layout:** Each backup is stored in a `v<timestamp>/` directory, with a `current` symlink pointing to the active version. This makes the backup self-describing and eliminates stale-part contamination between runs.
2. **Transactional replacement:** Generation happens in staging; publication happens atomically. A failed run leaves the previous backup untouched.
3. **Automatic migration:** Legacy flat layouts are migrated to the versioned layout on the first run, without data loss. `--NO-MIGRATE` opts out.
4. **Layered locking:** Concurrent invocations against the same backup directory are detected and aborted early, with clear diagnostic messages.
5. **Configurable retention:** `--KEEP N` or `ARCHIVEPAR2_KEEP` controls how many old versions are kept. Default is 3.
6. **Retained from v0.16:** Improved BLAKE3 manifest generation, stronger manifest validation, explicit background process management, centralized cleanup, and better shell-state preservation.
7. **Documented cleanup limitations:** The implementation explicitly distinguishes best-effort process termination from a guarantee that every descendant process will be terminated.

The comparison describes the major implementation changes rather than a claim that every possible failure scenario has been eliminated.

### Integrity and Recovery Model

The archive workflow uses several complementary mechanisms:

| Mechanism | Purpose |
|---|---|
| TAR content comparison (`tar --diff`) | Checks the archive's contents against the source directory. Skipped with `--FAST`. |
| BLAKE3 global hash | Provides a cryptographic digest for the complete archive. |
| BLAKE3 part hashes | Allow individual archive parts to be checked against their recorded digests. |
| PAR2 recovery data | Provides recovery capability for damaged or missing data within the limits of the generated redundancy. |
| Managed process-status checks | Help ensure that failed hashing, verification, compression, or recovery-data jobs are not silently reported as successful. |
| Atomic publication (v0.17) | The `current` symlink swap is atomic; consumers never see a partial backup. |
| Layered locking (v0.17) | Prevents concurrent invocations from corrupting each other. |

These mechanisms serve different purposes: content comparison checks the archived data against the source, BLAKE3 detects changes relative to the recorded hashes, and PAR2 provides a means of recovering certain forms of data loss.

**Important:** A manifest is only useful as a trusted reference if it is protected against unauthorized modification. BLAKE3 hashes alone do not authenticate the manifest or prevent an attacker with write access from replacing both the archive and its recorded hashes.

#### Process Cleanup Limitations

`archivepar2` uses explicit process tracking, bounded cleanup attempts, and exit-status checks to detect failures and prevent incomplete backups from being treated as successful. However, process-group termination cannot be guaranteed in every failure scenario. In particular, checking whether a process group exists with `kill -0` does not prove that active worker processes remain, and a theoretical time-of-check-to-time-of-use (TOCTOU) race involving process-group ID reuse may cause a signal to target an unrelated group.

When cleanup cannot be confirmed, the script reports the failure and attempts further cleanup where possible. These mechanisms provide failure detection and best-effort process cleanup, not an absolute guarantee that every descendant process will be terminated.

These limitations do not change the core archive-integrity workflow: the global BLAKE3 hash is calculated during compression, and the script checks the relevant process exit statuses and validates the manifest before proceeding to PAR2 generation.

#### Locking Limitations

The layered locking strategy (see §3 above) provides strong protection on filesystems that support `flock(2)` correctly (ext4, xfs, btrfs, ZFS on Linux, WSL2/ext4). On filesystems where `flock(2)` is not reliable (SSHFS, some FUSE mounts, CIFS/SMB, 9P), only the `mkdir lockdir` layer provides protection, which is best-effort. A warning is logged in these cases.

Note also that the `.archivepar2.lock` file persists intentionally (see "About `.archivepar2.lock`" above). It is a zero-byte hidden file and does not interfere with the backup or restore operations.

---

## 2. Restoration & Recovery: `restorepar2` (v0.5)

This script acts as the guardian of your data, used to verify the health of archives and restore them.

Starting with **v0.5**, `restorepar2` supports the **versioned backup layout** introduced in `archivepar2` v0.17. It resolves the `current` symlink (or the newest `v<timestamp>/` directory) automatically. Legacy flat layouts are still fully supported. An optional `--version=<name>` flag selects a specific version.

### Key Functionalities

* **Automatic Layout Resolution (v0.5):** Detects whether the backup directory uses the versioned layout (`current` symlink or `v<timestamp>/` subdirectories) or the legacy flat layout, and operates on the correct directory.
* **Version Selection (v0.5):** `--version=<name>` allows restoring a specific version from a multi-version backup directory.
* **Automatic Detection:** The script automatically fingerprints the archive to determine if it is dealing with a single-file or split-file archive.
* **PAR2 Self-Healing:** It runs a block integrity check. If the archive is found to be corrupted, it automatically attempts a **`par2 repair`** to recover missing or damaged data using redundancy blocks.
* **Verified Extraction:** When run in `extract` mode, it unpacks the archive into a new directory suffixed with `-restored` and performs real-time BLAKE3 hashing to verify data integrity during extraction.
* **Full Structural Check (`--FULL`):** Allows for deeper levels of structural verification of the archive files.

### Arguments & Flags

* **`EXTRACT`**: Switches the mode from verification to **full restoration**. The script will unpack the archive into a new directory suffixed with `-restored`.
* **`--FULL`, `--FULL=1`, or `--FULL=2`**: Enables **Deep Structural Checks**. These options trigger different levels of structural integrity verification beyond the standard PAR2 and BLAKE3 checks.
* **`--version=<name>`** (v0.5): Selects a specific version from a versioned backup directory. Accepts both `--version=v20260114-120000` and `--version v20260114-120000`. If not specified, the active version (`current`) is used.
* **Input Folder**: The first non-flag argument is treated as the path to the backup directory.

### Detailed Workflow of `restorepar2`

The `restorepar2` utility is the "guardian" of the archive, focusing on resilience and verified extraction.

1. **Layout Resolution (v0.5)**:
* If the input directory contains `current` (symlink or directory), the target is resolved to `realpath current`.
* Else, if the input directory contains `v<timestamp>/` subdirectories, the newest one (lexicographic sort) is used.
* Else, if the input directory contains archive files directly (`.tar.zst` or `.tar.zst.part-*`), the legacy flat layout is used.
* If `--version=<name>` is specified, that specific `v<name>/` subdirectory is used, overriding the automatic resolution.
* The resolved directory is reported as `[LAYOUT] Active directory: ...`.

2. **Archive Fingerprinting**:
* The script automatically detects whether it is working with a **single-file** or **split-file** archive by scanning for `.tar.zst` or `.tar.zst.part-*` patterns.
* It identifies the required `.par2` index file to begin the recovery process.

3. **Phase 1: Proactive Resilience (Verify & Repair)**:
* The script first runs `par2 verify`.
* **Auto-Repair**: If verification fails, it immediately attempts a **`par2 repair`** to fix corrupted blocks using the redundancy data.

4. **Phase 2: Cryptographic Validation**:
* It utilizes the **BLAKE3 manifest** to verify the archive's integrity. The `verify_blake3_match` helper isolates the global hash entry (`.tar.zst`) from the multi-line manifest format.

5. **Phase 3: Verified Extraction**:
* If the `EXTRACT` mode is used, the script creates a new directory suffixed with **`-restored`**.
* For versioned backups, the extract directory is `${backup_root%-bak}-restored` (e.g., `/path/to/mydata-restored/`).
* If a non-active version is explicitly selected via `--version`, the version name is appended to the extract directory (e.g., `/path/to/mydata-restored.v20260114-120000/`), preventing accidental overwrite of a previous extraction.
* Extraction is performed with **real-time BLAKE3 hashing**, ensuring the data being written to disk matches the cryptographic signature of the original archive.

6. **Performance Auditing**:
* Upon completion, the script generates a **Performance Summary**, detailing the time spent on PAR2 checks, BLAKE3 verification, structural checks, and extraction.

### Version Comparison: v0.4 vs. v0.5

| Feature | v0.4 | v0.5 |
|---|---|---|
| Supported layouts | Flat / legacy only | **Flat / legacy + versioned** (`current` symlink or `v<timestamp>/`) |
| Version selection | N/A | **`--version=<name>`** flag, with both `--version=v<ts>` and `--version v<ts>` syntaxes |
| `current` symlink handling | N/A | Resolved via `realpath` to the active version directory |
| Fallback when `current` missing | N/A | Automatically uses the newest `v<timestamp>/` subdirectory |
| Extract directory naming | `${input%-bak}-restored` | Same, plus the version name is appended when a non-active version is restored |
| PAR2 verify/repair | Yes | Yes (unchanged) |
| BLAKE3 verification | Yes | Yes (unchanged) |
| Real-time BLAKE3 during extract | Yes | Yes (unchanged) |

---

## 3. Automation Wrappers

### `backup` (v0.1)

A high-level orchestrator that executes the full pipeline: it calls `archivepar2` to create the backup and then immediately triggers `restorepar2` in verification mode. This ensures a backup is only considered "successful" if its integrity is confirmed right after creation.

* **Dynamic Flag Passing**: It is designed to interpret flags and automatically pass them to the underlying engines. For example, flags related to creation (like `--SINGLE`, `--KEEP`) are passed to `archivepar2`, while restore-level settings are passed to `restorepar2`.

### `folderbkp` (v0.1)

A batch processor that iterates through an entire parent directory, applying the `backup` function to every sub-folder and file.

* **Hidden File Support:** It utilizes `dotglob` to ensure hidden configuration files (like `.git`) are included in the backup.
* **Robustness:** It captures all extra arguments (like custom sizes or speed flags) and passes them safely to each individual backup task.

#### Arguments and flags

* **`[extra_args]`**: Any arguments provided after the parent directory (such as `--FAST`, `--SINGLE`, `--KEEP N`, or a custom part size) are captured and **repassed** to each individual `backup` call.
* **Environment Handling**: It automatically enables `nullglob` and `dotglob` during execution to ensure that empty directories and hidden files (starting with `.`) are included in the process.

---

## 4. Performance Monitoring & Logging

The utility provides extensive feedback for every session, which is both displayed in the terminal (via `pv` progress bars) and saved to a **Session Log** (`.log`).

**The Performance Summary includes:**

* **Compression Metrics:** Duration and status of the zstd compression.
* **Tar Check:** Time taken for the 1:1 bit-comparison against the source.
* **PAR2 Create/Check:** Time spent generating or verifying recovery blocks.
* **BLAKE3/Structure Checks:** Verification status of cryptographic hashes.
* **Total Elapsed Time:** A final timer (MM:SS) for the entire operation.

---

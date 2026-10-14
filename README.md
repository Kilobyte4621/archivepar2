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

## 1. Core Component: `archivepar2` (v0.16)

The `archivepar2` function is the primary archive creation engine. It transforms a target directory into a compressed, integrity-verified, and error-recoverable backup using TAR, Zstandard, BLAKE3, and PAR2. The current implementation emphasizes synchronous integrity verification, controlled process lifecycles, interruption handling, and reliable resource cleanup.

### Key Functionalities

- **Intelligent Path Sanitization:** Sanitizes the source folder name for the backup directory, converting it to lowercase, replacing spaces with underscores, and removing special characters.
- **Flexible Archiving Modes:**
  - **Split Mode (Default):** Splits the compressed archive into parts, defaulting to **2 GB** per part, facilitating storage and transfer.
  - **Single Mode (`--SINGLE`):** Creates a single `.tar.zst` archive without splitting.
- **Configurable Integrity Checks:**
  - **Default Mode:** Performs a post-compression `tar --diff` check against the source directory.
  - **Fast Mode (`--FAST`):** Skips the post-compression TAR content comparison.
- **Cryptographic Integrity Manifests:** Generates a `.blake3` manifest containing the archive's global BLAKE3 hash and the hashes of the archive parts, enabling later integrity verification.
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
- `Size` (e.g., `500M`, `4G`): Sets the maximum size of each archive part in split mode. The default is `2G`.

### Detailed Workflow of `archivepar2`

#### 1. Environment and Argument Handling

- Validates the input and requires a source directory.
- Parses `--SINGLE`, `--FAST`, and an optional custom split size.
- Enables `pipefail` during execution so that failures in commands within pipelines, such as `tar`, `zstd`, or other pipeline components, are not silently ignored.
- Preserves the relevant shell state so temporary changes do not unintentionally affect the calling shell.

#### 2. Path Sanitization and Session Logging

- Sanitizes the source folder name to construct the backup directory name.
- Initializes a session log recording relevant execution details, including the start timestamp, source path, selected arguments, and performance information.
- Uses consistent helper-function naming to distinguish internal implementation details from public functionality.

#### 3. Compression and Archive Splitting

- **Split Mode (Default):** Compresses the source directory and divides the resulting archive into parts according to the configured maximum size. The default part size is `2G`.
- **Single Mode:** Produces one `.tar.zst` file without splitting.
- Removes stale split parts when preparing a new archive, preventing leftover files from a previous run from being mistaken for part of the current backup.
- Uses progress reporting during the relevant archive-processing stages.

#### 4. TAR Content Integrity Verification

- Unless `--FAST` is specified, runs a post-compression `tar --diff` comparison between the source directory and the compressed archive.
- Treats verification as a managed job and checks its completion status before proceeding.
- Stops the operation when the content integrity check fails rather than reporting an unsuccessful archive as successfully verified.

#### 5. BLAKE3 Manifest Generation and Validation

- Generates a BLAKE3 manifest containing the global hash of the complete archive and hashes for its individual archive parts.
- Calculates the global BLAKE3 hash during compression and coordinates its completion with the main workflow.
- Uses a FIFO-based communication mechanism and a status file to coordinate the global hashing job with the main function.
- Checks the hashing process's exit status before treating the manifest as complete.
- Validates the global manifest entry, requiring a correctly formatted 64-character hexadecimal BLAKE3 digest and rejecting missing, malformed, or duplicate global entries.
- Applies managed process and status handling to hashing operations used during the workflow, including resume-related verification where applicable.
- Validates the manifest before proceeding to PAR2 generation.

#### 6. PAR2 Recovery Data Generation

- Generates PAR2 recovery data to provide redundancy that can help repair damaged or missing archive data, subject to the available recovery blocks.
- Manages the PAR2 job's process lifecycle and checks its outcome rather than relying solely on whether the command was launched.
- Routes failures through the function's error-handling and cleanup mechanisms.

#### 7. Background Process Lifecycle Management

- Launches background jobs through a dedicated helper that establishes and tracks process groups.
- Uses a process-group handshake and acknowledgement mechanism to coordinate job startup and registration.
- Tracks job process IDs and process-group IDs so the function can monitor and manage jobs consistently.
- Waits for managed jobs and checks their exit statuses.
- Handles termination requests, including escalation from `SIGTERM` to `SIGKILL` when necessary.
- Registers process groups that remain after forced termination so centralized cleanup can make another termination attempt.
- Treats unresolved process termination as a failure condition instead of assuming that sending a signal guarantees the process has exited.

#### 8. Centralized Cleanup and Shell-State Restoration

- Centralizes cleanup for success, failure, and interruption paths.
- Removes temporary resources created during execution, including temporary files, FIFOs, and job status files.
- Attempts to terminate and reap tracked background jobs and process groups.
- Restores the original working directory and relevant shell settings, including the previous `pipefail` state, signal traps, and `nullglob` state.
- Uses a consistent internal helper prefix to reduce the risk of collisions with unrelated shell functions and variables.

#### 9. Error Handling and Final Status

- Reports missing or invalid input and other detected failures explicitly.
- Propagates errors from managed jobs and verification steps instead of treating successful process launch as proof of successful completion.
- Uses cleanup paths to handle failed operations and interrupted execution.
- Retains performance reporting and final status information in the session log.

### Version Comparison: v0.14 vs. v0.16

Version 0.16 focuses on making archive creation more reliable by strengthening BLAKE3 manifest generation, background process management, failure detection, and cleanup.

| Feature | v0.14 | v0.16 |
|---|---|---|
| Archive modes | Split and single-archive modes | Retains split and single-archive modes |
| Split-size configuration | Configurable part sizes | Retains configurable part sizes and stale-part cleanup |
| TAR content verification | Post-compression `tar --diff`, unless `--FAST` is used | Retains the optional comparison and integrates it with managed job-status checks |
| Global BLAKE3 hash | Manifest generation without the current synchronization safeguards | Global hash calculated during compression, with process-status checks and manifest validation |
| Manifest validation | Less comprehensive validation | Rejects missing, malformed, or duplicate global hash entries |
| Background jobs | Less comprehensive process lifecycle management | Explicit process tracking, process groups, startup coordination, and exit-status checks |
| Interruption handling | Less comprehensive cleanup coordination | Signal handling, termination escalation, and tracked process-group cleanup attempts |
| Temporary resources | Less centralized resource management | Centralized cleanup of temporary files, FIFOs, and status files |
| Shell-state preservation | Less comprehensive restoration | Restores relevant shell state, including `pipefail`, traps, working directory, and `nullglob` |
| Error reporting | Existing error handling | Stronger failure detection across hashing, verification, and managed jobs |
| Process cleanup guarantees | Not covered by the current detailed limitations disclaimer | Explicitly documented as best-effort, with known process-group detection and TOCTOU limitations |

#### Main Improvements in v0.16

1. **More reliable BLAKE3 manifest generation:** The global hash is calculated during compression, and the workflow checks the relevant process exit statuses and validates the manifest before PAR2 generation.
2. **Stronger manifest validation:** The global hash entry must be present, unique, and correctly formatted.
3. **Explicit background process management:** Jobs are tracked using process IDs and process groups, with startup coordination, exit-status checks, and termination escalation.
4. **Centralized cleanup:** Temporary resources and tracked jobs are handled through a common cleanup mechanism for normal completion, failure, and interruption.
5. **Better shell-state preservation:** Relevant shell settings and execution context are restored after the function finishes.
6. **Clearer failure detection:** Failed hashing, integrity checks, and managed jobs are less likely to be mistaken for successful completion.
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

These mechanisms serve different purposes: content comparison checks the archived data against the source, BLAKE3 detects changes relative to the recorded hashes, and PAR2 provides a means of recovering certain forms of data loss.

**Important:** A manifest is only useful as a trusted reference if it is protected against unauthorized modification. BLAKE3 hashes alone do not authenticate the manifest or prevent an attacker with write access from replacing both the archive and its recorded hashes.

#### Process Cleanup Limitations

`archivepar2` uses explicit process tracking, bounded cleanup attempts, and exit-status checks to detect failures and prevent incomplete backups from being treated as successful. However, process-group termination cannot be guaranteed in every failure scenario. In particular, checking whether a process group exists with `kill -0` does not prove that active worker processes remain, and a theoretical time-of-check-to-time-of-use (TOCTOU) race involving process-group ID reuse may cause a signal to target an unrelated group.

When cleanup cannot be confirmed, the script reports the failure and attempts further cleanup where possible. These mechanisms provide failure detection and best-effort process cleanup, not an absolute guarantee that every descendant process will be terminated.

These limitations do not change the core archive-integrity workflow: the global BLAKE3 hash is calculated during compression, and the script checks the relevant process exit statuses and validates the manifest before proceeding to PAR2 generation.


---

## 2. Restoration & Recovery: `restorepar2` (v0.4)

This script acts as the guardian of your data, used to verify the health of archives and restore them.

### Key Functionalities

* **Automatic Detection:** The script automatically fingerprints the backup directory to determine if it is dealing with a single-file or split-file archive.
* **PAR2 Self-Healing:** It runs a block integrity check. If the archive is found to be corrupted, it automatically attempts a **`par2 repair`** to recover missing or damaged data using redundancy blocks.
* **Verified Extraction:** When run in `extract` mode, it unpacks the archive into a new directory suffixed with `-restored` and performs real-time BLAKE3 hashing to verify data integrity during extraction.
* **Full Structural Check (`--FULL`):** Allows for deeper levels of structural verification of the archive files.

### Arguments & Flags

* **`EXTRACT`**: Switches the mode from verification to **full restoration**. The script will unpack the archive into a new directory suffixed with `-restored`.
* **`--FULL`, `--FULL=1`, or `--FULL=2`**: Enables **Deep Structural Checks**. These options trigger different levels of structural integrity verification beyond the standard PAR2 and BLAKE3 checks.
* **Input Folder**: The first non-flag argument is treated as the path to the backup directory.

### Detailed Workflow of `restorepar2`

The `restorepar2` utility is the "guardian" of the archive, focusing on resilience and verified extraction.

1. **Archive Fingerprinting**:
* The script automatically detects whether it is working with a **single-file** or **split-file** archive by scanning for `.tar.zst` or `.tar.zst.part-*` patterns.
* It identifies the required `.par2` index file to begin the recovery process.


2. **Phase 1: Proactive Resilience (Verify & Repair)**:
* The script first runs `par2 verify`.
* **Auto-Repair**: A critical feature of v0.4 is that if verification fails, it does not simply quit; it immediately attempts a **`par2 repair`** to fix corrupted blocks using the redundancy data.


3. **Phase 2: Cryptographic Validation**:
* It utilizes the **BLAKE3 manifest** to verify the archive’s integrity. The `verify_blake3_match` helper is designed to isolate the hash of the archive files from the multi-line manifest format.


4. **Phase 3: Verified Extraction**:
* If the `EXTRACT` mode is used, the script creates a new directory suffixed with **`-restored`** to prevent overwriting existing data.
* Extraction is performed with **real-time BLAKE3 hashing**, ensuring the data being written to disk matches the cryptographic signature of the original archive.


5. **Performance Auditing**:
* Upon completion, the script generates a **Performance Summary**, detailing the time spent on PAR2 checks, BLAKE3 verification, structural checks, and extraction.



---

## 3. Automation Wrappers

### `backup` (v0.1)

A high-level orchestrator that executes the full pipeline: it calls `archivepar2` to create the backup and then immediately triggers `restorepar2` in verification mode. This ensures a backup is only considered "successful" if its integrity is confirmed right after creation.

* **Dynamic Flag Passing**: It is designed to interpret flags and automatically pass them to the underlying engines. For example, flags related to creation (like `--SINGLE`) are passed to `archivepar2`, while restore-level settings are passed to `restorepar2`.

### `folderbkp` (v0.1)

A batch processor that iterates through an entire parent directory, applying the `backup` function to every sub-folder and file.

* **Hidden File Support:** It utilizes `dotglob` to ensure hidden configuration files (like `.git`) are included in the backup.
* **Robustness:** It captures all extra arguments (like custom sizes or speed flags) and passes them safely to each individual backup task.

#### Arguments and flags

* **`[extra_args]`**: Any arguments provided after the parent directory (such as `--FAST`, `--SINGLE`, or a custom part size) are captured and **repassed** to each individual `backup` call.
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



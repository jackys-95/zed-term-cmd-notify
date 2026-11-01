# Repository agent instructions

## Protect local identifiers

Treat machine-specific values in terminal output, logs, and other local evidence as private. Do not copy real values into Git-tracked files or commit messages. This includes usernames, hostnames, absolute paths, terminal or device names, socket names, transient run identifiers, recorded clock times, and credentials.

When preserving evidence in a tracked file, replace local values with neutral placeholders such as `<USER>`, `<HOST>`, `<REPO_ROOT>`, `<RUN_ID>`, or `<TIME>`. Replace recorded clock times in transcripts and logs with `<TIME>` while retaining entry order. If timing is needed to explain the result, report relative elapsed time instead of wall-clock time. Keep unredacted evidence outside the repository or in a location confirmed to be ignored by Git. Do not put private values in this file or other tracked configuration.

Before committing, review staged content for accidental local identifiers, including content added to existing tracked files.

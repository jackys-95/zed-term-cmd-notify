# Repository agent instructions

## Document code for readers new to Rust and Swift

Write code documentation for a developer who understands programming and this project's purpose but is new to Rust or Swift. Explain what a component does, where it fits in the notification flow, and why its important constraints exist. Give documentation a clear purpose, a usable contract, and examples where behavior needs illustration, using the language's documentation conventions.

### Documentation comments

- Use Rust's `///` documentation comments for types and functions, and `//!` for module or crate overviews. Use Swift's `///` documentation comments for types and functions.
- Document public APIs and internal components whose behavior is not obvious. Start with one plain-English sentence stating the operation and its result. Organize the rest around what a caller needs to know: input meaning and units, preconditions, returned values, meaningful failures, side effects, and caller responsibilities.
- Use sections only when they add information. For Rust, use headings such as `# Examples`, `# Errors`, `# Panics`, and `# Safety` where applicable. For Swift, use documentation fields such as `- Parameters:`, `- Returns:`, and `- Throws:` where applicable. Describe constraints and semantics that the signature alone cannot convey.
- Write natural, complete sentences with consistent terminology. Name the component responsible for an action, define unfamiliar terms on first use, and keep each paragraph focused on one reader question.
- Avoid negative parallelism and contrastive negation, such as “not X, but Y” or “This is not X. It is Y.” State the actual behavior or responsibility directly. Keep factual negation when it explains a failure condition or API limitation.
- Use Simple English and relevant ASD-STE100 writing principles where they help the reader: familiar words, concrete verbs, active voice, short sentences, and one main idea per sentence. Preserve exact code identifiers and technical distinctions needed for correct use.
- Avoid stock generated phrasing, compressed noun phrases, mirrored sentence patterns, and repeated caveats. Put shared explanations in the component overview and keep operation-specific details beside each operation.
- Distinguish guarantees from best-effort behavior. Explain observable limits such as a timeout leaving the outcome uncertain, or an acknowledgment confirming processing without guaranteeing a visible notification.
- Explain language-specific choices when they affect correctness, such as Rust ownership and automatic resource cleanup, or Swift actor isolation and concurrency. Put the explanation beside the relevant code rather than assuming the reader knows the language feature.
- Use ordinary comments to explain non-obvious implementation decisions, especially unsafe calls, socket ownership, deadlines, cleanup, and concurrency. For Rust `unsafe` blocks, state the safety conditions that make the operation valid.
- Keep documentation concise and accurate as code changes. Explain intent and constraints rather than restating syntax; avoid comments on every line, boilerplate sections, and a general language tutorial. Link to the authoritative project design for broader rationale.

### Function and method names

- Choose names that describe the domain action or returned value. Prefer concrete verbs such as capture, validate, encode, and deliver over vague names such as process, manage, or handle when a more precise operation is known.
- Follow each language's naming conventions: Rust functions and methods use `snake_case`; Swift functions and methods use `lowerCamelCase`, with argument labels that make calls read clearly.
- Use consistent terms for the same concepts across Rust, Swift, and the protocol. Make predicates read as questions or assertions, such as `is_valid` or `isValid`, and make constructors and conversions communicate what they create or convert.
- Include distinctions such as units, blocking behavior, or side effects in names or argument labels when callers need them to choose or use the operation correctly. Document remaining details without making names describe the entire implementation.

### Examples for algorithms and data structures

- Include a small worked example when code depends on a non-obvious algorithm, ordering rule, state transition, or data-structure invariant. Show the starting input or state, the significant steps, and the expected output or final state.
- Include a relevant boundary or failure case when it explains a correctness rule, such as a frame at the size limit, a queued request whose deadline expires, or cleanup encountering a replaced socket. Use synthetic values and explain why the result follows.
- For a custom data structure, explain what it stores, the invariant its operations preserve, and who owns or removes its entries. Describe time and space costs when they affect the design or a caller's choices.
- Put usage examples in API documentation and implementation walkthroughs beside the algorithm. Use a small table or diagram only when it explains the behavior more clearly than prose. Keep broader worked examples in the authoritative design and link to them.
- Prefer executable examples when practical. Examples that require a running helper or native permissions must state those prerequisites; do not make ordinary documentation checks depend on a live environment. Keep examples minimal and avoid repeating existing tests.

Before finishing a documentation change, check that a new reader can explain the component's purpose, use its API correctly, and identify its important failure conditions without knowing the implementation history.

## Mermaid diagrams

For each changed Mermaid block, extract the contents without the Markdown fences into a temporary `.mmd` file. Render each block and inspect the SVG for clipping or overlapping labels:

```sh
npx --yes --package @mermaid-js/mermaid-cli mmdc \
  -i /tmp/diagram.mmd \
  -o /tmp/diagram.svg
open -a Firefox /tmp/diagram.svg
```

A successful Mermaid CLI run confirms that the diagram parses and produces an SVG. Repeat the command for every changed block. For GitHub-bound Markdown, check the GitHub preview when visual parity matters because the local renderer can use different versions or styling.

For syntax-only validation, Mermaid's JavaScript API provides `mermaid.parse(source)`. The `npx --package` option makes package executables available on `PATH`, but Node does not automatically resolve the package from there. This command locates the temporary package directory through `mmdc` and calls `mermaid.parse()` without rendering:

```sh
npx --yes \
  --package=mermaid \
  --package=@mermaid-js/mermaid-cli \
  --call 'NODE_PATH="$(dirname "$(dirname "$(command -v mmdc)")")" node -e "const fs = require(\"node:fs\"); const mermaid = require(\"mermaid\").default; mermaid.parse(fs.readFileSync(process.argv[1], \"utf8\")).then(() => console.log(\"Mermaid syntax OK\")).catch((error) => { console.error(error); process.exit(1); });" /tmp/diagram.mmd'
```

A successful parse confirms syntax only; it does not check text sizing, clipping, or layout. Repeat for each changed Mermaid block.

## Protect local identifiers

Treat machine-specific values in terminal output, logs, and other local evidence as private. Do not copy real values into Git-tracked files or commit messages. This includes usernames, hostnames, absolute paths, terminal or device names, socket names, transient run identifiers, recorded clock times, and credentials.

When preserving evidence in a tracked file, replace local values with neutral placeholders such as `<USER>`, `<HOST>`, `<REPO_ROOT>`, `<RUN_ID>`, or `<TIME>`. Replace recorded clock times in transcripts and logs with `<TIME>` while retaining entry order. If timing is needed to explain the result, report relative elapsed time instead of wall-clock time. Keep unredacted evidence outside the repository or in a location confirmed to be ignored by Git. Do not put private values in this file or other tracked configuration.

Before committing, review staged content for accidental local identifiers, including content added to existing tracked files.

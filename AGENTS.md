# AGENTS.md

Instructions for AI coding agents (Claude, ChatGPT/Codex, Gemini, Copilot,
...) working on this repository.

**Precedence:** these rules are project-specific and override any global or
user-level instructions on the same topics (e.g. `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`).

## Coding style

- Indent with **4 spaces** in every code file: Lua, shell, JavaScript. No
  tabs.
- Plugins are written in Lua, Bash or Node.js (`check_puppeteer`). Shared
  Lua code lives in `lib*.lua`; addons sit next to their plugin, eg.
  `check_rest_addon.pve_storage.inc.lua`.
- Markdown keeps 2-space list continuation.
- Code comments are written in English, short, and explain why rather than
  what.

## Commit messages

Commits follow the HAProxy "Patch classifying rules"
(<https://github.com/haproxy/haproxy/blob/master/CONTRIBUTING>).

### Subject

```
[TYPE[/SEVERITY]: ][area: ]short description
```

- **TYPE** is the nature of the change:
  - `FEATURE`: a new plugin or addon;
  - `BUG`: fix for a bug; the body must describe the user-visible impact;
  - `CLEANUP`: trivial code cleanup, no functional impact and no risk
    (renames, comments, dead code). Rewriting working code, even to
    simplify it, can break it: it takes a severity instead;
  - `DOC`: documentation (README, PLAN, comments-only changes);
  - `REORG`: code moved as-is, never mixed with functional changes;
  - `BUILD`: build, tooling, packaging, configuration;
  - `OPTIM`: optimization;
  - `RELEASE`, `LICENSE`, `REGTEST`.
  Improvements to an existing plugin or library carry no type, only a
  severity.
- **SEVERITY** is the risk or importance: `MINOR`, `MEDIUM`, `MAJOR`,
  `CRITICAL` (bugs only). It may be omitted for `BUILD`, `DOC` and
  `CLEANUP`.
- Type and severity come before the first colon, separated by `/`. The
  area follows, then a colon: the plugin or library name without
  extension (`check_rest`, `check_puppeteer`, `libcheck`), or
  `<family>/<addon>` for an addon, the family being a short name of the
  plugin (`rest/pve_storage`, `es/dyn_threshold`, `ssh/expect`).
- The short description starts with a capital letter.
- No square brackets around tags.

Examples:

```
FEATURE: check_io_pressure: Plugin to check Linux IO pressure
MINOR: check_disk_smart: Alternative to smartctl --scan to list devices
BUG/MINOR: rest/pve_backup_fresh: Datastore content may not be fetched
MEDIUM: check_claude_usage: Warning before the refresh token expires
CLEANUP: libzcurl: Fix duplicate newline sequence
```

### Body

- A body is mandatory: never commit a subject alone.
- Be concise: at most 5 lines of at most 74 characters, unless amply
  justified.
- No "Why / Impact / Technical Overview" style sections.
- No `Co-Authored-By:` or other generated trailers, even if your tool
  suggests them.

### AI agent footer

A commit written with the help of an AI agent ends with this line, after
an empty line:

```
With the help of AI Agents: <name>
```

`<name>` is the agent name in lowercase, without any model detail: e.g.
`claude`, `chatgpt`, `gemini`, `copilot`.

Complete example:

```
BUG/MINOR: check_puppeteer: Do not lose the result when a screenshot fails

The catch block of the screenshot logged an undefined variable, so a
screenshot failure (eg. missing -o directory) raised a ReferenceError
and the check exited UNKNOWN "Unhandled rejection!" instead of
reporting the scenario result.

With the help of AI Agents: claude
```

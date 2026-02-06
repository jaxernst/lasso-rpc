# Documentation Style Guide

Standards for all Lasso documentation. The librarian enforces these.

## Voice and Tone

- **Technical but approachable** — Write for developers, not marketers. No hype words ("blazing fast", "revolutionary"). State capabilities plainly.
- **Direct** — Lead with what the reader needs. Don't bury the lede.
- **Confident** — Avoid hedging ("might", "should probably", "you may want to consider"). State facts.
- **Concise** — Every sentence earns its place. Cut filler.

## Document Types

### Reference Docs
- Exhaustive coverage of a feature's API, config options, behavior
- Organized for lookup, not reading front-to-back
- Tables for option lists, code blocks for examples
- Every option has a description and default value
- Audience: power users and integrators

### Tutorials / Guides
- Goal-oriented: "How to set up BYOK", "How to configure per-method routing"
- Linear flow: prerequisites → steps → verification
- Working code examples at each step
- Audience: integrators and new users

### Architecture Docs
- Explain the "why" behind design decisions
- Diagrams where they clarify (not just decorate)
- Module-level overview, not line-by-line
- Audience: contributors and advanced users

### Internal Specs
- Located in `docs/internal/`
- Planning docs, decision records, implementation notes
- Audience: the team

## Structure Patterns

### Headers
- Use `#` for the doc title (one per file)
- Use `##` for major sections
- Use `###` for subsections
- Headers should be scannable — a reader skimming headers should understand the doc's scope

### Code Examples
- Use fenced code blocks with language identifiers (```elixir, ```bash, ```json)
- Examples should be runnable or clearly marked as pseudocode
- Show the minimal example that demonstrates the concept
- Include expected output where it aids understanding

### Tables
- Use for structured data: config options, API parameters, comparison matrices
- Keep columns narrow — long prose doesn't belong in tables
- Always include a header row

### Links
- Use relative links for internal references (`../ARCHITECTURE.md`)
- Verify links resolve (the librarian checks this)

## File Placement

| Type | Location | Audience |
|------|----------|----------|
| Public docs (OSS-safe) | `project/` | External developers |
| README | `README.md` (root) | Everyone (first impression) |
| Internal specs | `docs/internal/` | Team only |
| Claude config docs | `.claude/` | Agent/tool consumers |
| CLAUDE.md | Root | Claude Code sessions |

## Project Anti-Patterns

These are banned in all documentation:

- **Evolution comments**: No "Added X", "Changed Y to Z", "Updated to reflect..." — describe current state only
- **Comment bloat**: No obvious comments. If the heading says "Configuration" don't start with "This section covers configuration."
- **Time estimates**: No "takes about 5 minutes", "can be done in an afternoon"
- **"For now" language**: No "for now we do X". Either document the current behavior as intentional or file a backlog item.
- **Hedging in instructions**: No "you might want to" in setup steps. Be prescriptive.
- **Stale TODOs**: TODOs in docs are tracked in the registry backlog, not left inline forever.

## Formatting Conventions

- One blank line between sections
- No trailing whitespace
- Ordered lists for sequential steps
- Unordered lists for non-sequential items
- Bold for emphasis on key terms on first use
- `backticks` for code references inline (module names, function names, file paths, config keys)
- Em dash (—) for parenthetical asides, not double hyphens (--)

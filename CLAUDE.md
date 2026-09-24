# Droplet

Read [AGENTS.md](AGENTS.md) for development instructions and
[docs/architecture.md](docs/architecture.md) for architecture, data formats,
numerical invariants, and command reference. These documents are shared by all
coding agents.

For a user-started GitHub development session, use the project `/github-loop`
skill and [docs/development-loop.md](docs/development-loop.md). Start Claude Code
from this repository's controller checkout so the queue helper and policy come
from the trusted checkout. The shared skill governs approvals and publishing;
the project agents in `.claude/agents/` provide task-specific model choices.

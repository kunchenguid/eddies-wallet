# Eddie's Wallet skill discovery evidence

Validated at target commit `75cdac024f6ddc119e25cc0dae002e2936e386c6`
against baseline `10a6e35ab37f471140ef64e4c72fbd3feb7a5588`.

## Pi project-skill discovery

Command:

```sh
pi --provider openai-codex --model gpt-5.4-mini --thinking minimal \
  --tools read --no-session --approve --print \
  "Use the discovered project skill eddies-wallet-design. Read its SKILL.md and then the exact README file it instructs you to load. Output only three lines: skill=<name>; skill_path=<repository-relative path>; readme_path=<repository-relative path>. Preserve filename case exactly."
```

Output:

```text
skill=eddies-wallet-design
skill_path=.agents/skills/eddies-wallet-design/SKILL.md
readme_path=.agents/skills/eddies-wallet-design/README.md
```

## Claude Code discovery through `.claude/skills`

Command:

```sh
claude --print --no-session-persistence --permission-mode dontAsk \
  --allowedTools Read --model haiku \
  "/eddies-wallet-design Verify the skill loads through this repository's Claude skill discovery path. Read the exact README filename instructed by the skill. Output only: skill=<name> | readme=<repository-relative path> | heading=<first Markdown heading>. Preserve case exactly."
```

Output:

```text
skill=eddies-wallet-design | readme=.claude/skills/eddies-wallet-design/README.md | heading=Eddie's Wallet design system (copied source)
```

## Git-index and move integrity

```text
tracked skill tree: baseline=144 target=144
history-preserving moves: total=144 rename-100%=142 edited=R068:design-system/github.md -> .agents/skills/eddies-wallet-design/github.md,R093:design-system/native-swiftui-mapping.md -> .agents/skills/eddies-wallet-design/native-swiftui-mapping.md
obsolete tracked design-system entries at target: 0
skill basename/frontmatter: eddies-wallet-design | eddies-wallet-design
README case in target index: README.md=present readme.md=absent
Claude discovery link: mode=120000 target=../.agents/skills resolves=yes
preserved CLAUDE.md: mode=120000 blob=47dc3e3d863cfb5727b87d785d09abf9743c0a72 target=AGENTS.md
known unresolved _ds_bundle.js references: baseline=9 target=9
rendered README new skill-path mentions: 3; obsolete design-system/ prose mentions: 0
```

The standalone rendered README is in `readme-rendered.html`. It was rendered
from the current root `README.md` through GitHub's GFM Markdown endpoint. A
browser screenshot could not be captured because this isolated test
environment exposed no in-app or Chrome browser session.

Its standalone references and changed visible text were checked after
rendering:

```text
standalone README artifact: all 18 local links/assets resolve
visible layout references: status, project table, and limitation all use .agents/skills/eddies-wallet-design/
```

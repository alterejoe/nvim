# /home/jmeyer/.config/opencode/prepends/convention-tracker.md FINAL
# Convention Tracker

You automatically track conventions being established or changed in this conversation. When detected, you cross-reference existing skills and surface skill updates for review.

## Convention Signals

A convention is being established or changed when the user:
- States a rule with "always", "never", "always use", "convention", "standard", "from now on", "don't do X, do Y"
- Describes a repeatable pattern (file structure, naming scheme, component pattern, API shape, process/flow with 3+ steps)
- Introduces a new dependency or tool with specific usage rules
- Corrects or refines a pattern previously used in this conversation
- Says "pattern:", "convention:", or "standardize on"
- Establishes a consistent approach across 2+ examples

Not a convention signal: one-off instructions, quick fixes, temporary workarounds, personal preferences without repeatability.

## Workflow

When a convention signal is detected:

1. **Identify affected skill** — Determine which existing skill(s) are relevant. Available skills: `handler-pattern`, `query-pattern`, `sse-pattern`, `gencomponents`, `form-behaviors`, `templ-ui`, `keymap-panels`, `error-handling`, `endpoint-workflow`, `go-migrate`, `consultation-first`, `handoff`, `plan-executor`, `code-delivery`. If none match, this is a new skill.

2. **Load and compare** — Use the `skill()` tool to load the affected skill. Read the full content. Identify what's new, what changed, and what conflicts.

3. **Generate output** — At the end of your response, include a `## Convention Update` section with the skill content ready to save.

## Output Format

If **updating an existing skill**:

````markdown
## Convention Update: `{skill-name}/SKILL.md`

Changes: brief summary of what changed and why.

```markdown
# /home/jmeyer/.config/opencode/skills/{skill-name}/SKILL.md FINAL
---
name: {skill-name}
description: "..."
---

Full updated content...
```
````

If **creating a new skill**:

````markdown
## New Convention: `{new-skill-name}/SKILL.md`

Convention established: brief description.

```markdown
# /home/jmeyer/.config/opencode/skills/{new-skill-name}/SKILL.md FINAL
---
name: {new-skill-name}
description: "..."
---

Full new content...
```
````

## Guardrails

- Only generate when there's enough specificity to write a meaningful skill (at least 3 concrete rules or examples)
- If the new convention conflicts with an existing skill, flag the conflict explicitly — don't silently override
- If the user doesn't explicitly state or imply repeatability, skip generation
- One convention update per response maximum (prioritize the most significant)
- Include the `## Convention Update` section **after** the main response content — don't interrupt the primary answer
```

---

**Full replacement:** `/home/jmeyer/.config/opencode/opencode.json`

```json
# /home/jmeyer/.config/opencode/opencode.json FINAL
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/big-pickle",
  "autoupdate": true,
  "default_agent": "oracle",

  "provider": {
    "opencode": {
      "models": {
        "big-pickle": {
          "options": {
            "reasoningEffort": "low",
            "textVerbosity": "low"
          },
          "variants": {
            "low": {
              "reasoningEffort": "low",
              "textVerbosity": "low",
              "reasoningSummary": "auto"
            },
            "high": {
              "reasoningEffort": "high",
              "textVerbosity": "low",
              "reasoningSummary": "auto"
            }
          }
        }
      }
    }
  },

  "agent": {
    "build": {
      "maxIterations": 2
    },
    "plan": {
      "maxIterations": 1
    },
    "chat": {
      "maxIterations": 1
    }
  },

  "permission": {
    "read": "ask",
    "edit": "deny",
    "write": "deny",
    "bash": "deny",
    "task": "deny",
    "webfetch": "allow",
    "doom_loop": "deny",
    "read": {
      "*": "allow",
      "*.env": "deny",
      "*.env.*": "deny",
      "*.pem": "deny",
      "*.key": "deny",
      "envs/**": "deny",
      "**/envs/**": "deny"
    }
  },
  "plugin": ["opencode-ignore", "opencode-mem", "oh-my-openagent"],

  "instructions": [
    "AGENTS.md",
    "/home/jmeyer/.config/opencode/prepends/output-formatting.md",
    "/home/jmeyer/.config/opencode/prepends/convention-tracker.md"
  ],

  "snapshot": true,
  "share": "manual",

  "server": {
    "port": 4096,
    "hostname": "localhost"
  }
}

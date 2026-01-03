---
name: comfyui-wan-workflow
description: Orchestration workflow for the ComfyUI-Wan project. Use this skill for task routing and delegation.
---

# ComfyUI-Wan Orchestration Workflow

## Step 0: CHECK KANBAN FIRST (Mandatory)

**BEFORE doing anything, check existing tasks:**

```
mcp__vibe_kanban__list_tasks(project_id: "2beb6d5f-25e5-46d1-bf9b-f490aad30c66")
```

- Check if a task already exists for this work
- Avoid creating duplicates
- Update existing task status if resuming work

## Your Team

### Non-Implementation Agents
| Agent | Name | When to Use |
|-------|------|-------------|
| `scout` | Ivy | Find files, explore structure, map architecture |
| `detective` | Vera | Investigate bugs, trace issues, find root causes |
| `architect` | Ada | Design solutions, plan implementations, evaluate trade-offs |
| `scribe` | Penny | Write/update documentation |

### Implementation Agents
| Agent | Name | When to Use |
|-------|------|-------------|
| `worker` | Bree | Single-file fixes, <30 lines, quick changes |
| `infra-supervisor` | Emilia | Dockerfile, CircleCI, docker-compose, model downloads |
| `runpod-supervisor` | Luna | start.sh, workflows, GPU optimization, cold start |

## Task Routing

### By File Type
| File Pattern | Delegate To |
|--------------|-------------|
| `Dockerfile` | `infra-supervisor` (Emilia) |
| `docker-compose.yml` | `infra-supervisor` (Emilia) |
| `docker-bake.hcl` | `infra-supervisor` (Emilia) |
| `.circleci/config.yml` | `infra-supervisor` (Emilia) |
| `src/download.py` | `infra-supervisor` (Emilia) |
| `src/start.sh` | `runpod-supervisor` (Luna) |
| `workflows/*.json` | `runpod-supervisor` (Luna) |
| `*.md` (docs) | `scribe` (Penny) |

### By Task Type
| Task | Flow |
|------|------|
| Bug report | `detective` → supervisor → worker |
| New feature | `architect` → supervisor(s) |
| Quick fix (<30 lines) | `worker` directly |
| Documentation | `scribe` directly |
| Exploration | `scout` → report back |

### By Complexity
| Size | Criteria | Delegate To |
|------|----------|-------------|
| **Small** | Single file, <30 lines, obvious fix | `worker` (Bree) |
| **Medium** | 2-3 files, clear scope | Appropriate supervisor |
| **Large** | 4+ files, architectural decisions | `architect` first → supervisors |

## Background Execution

**Recommended:** Run agents in background for parallel work:

```python
# Launch in background
Task(subagent_type="detective", prompt="Investigate...", run_in_background=true)

# Check status
TaskOutput(task_id="<id>", block=false)  # Non-blocking

# Get final result
TaskOutput(task_id="<id>")  # Blocks until complete
```

## Implementation Summary Template

After completing work, report:

```markdown
## Implementation Summary

**Kanban Task:** [task ID from Vibe Kanban]
**Agent(s) Used:** [list of agents]
**Files Modified:**
- [path]: [change summary]

**Verification:**
- [ ] Code changes compile/run
- [ ] Existing functionality preserved
- [ ] Documentation updated if needed

**Status:** Completed | Needs Review | Blocked
```

## Red Flags - STOP Immediately

| If you're about to... | Instead... |
|-----------------------|------------|
| Edit code directly | Delegate to appropriate agent |
| Skip Kanban check | Run `list_tasks` first |
| Create duplicate task | Check existing tasks |
| Implement without planning | Use `architect` for complex tasks |
| Skip investigation | Use `detective` for bugs |

## Kanban Project ID

```
2beb6d5f-25e5-46d1-bf9b-f490aad30c66
```

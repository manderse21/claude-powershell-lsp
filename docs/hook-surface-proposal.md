# Proposal: should the hook architecture grow beyond diagnostics?

**Status:** survey-only proposal for Mike's read (dispatch powershell-lsp/000009,
Track D). No code. The recommendation below is **decline all new surfaces** -- keep
the plugin diagnostics-only -- with the reasoning laid out per candidate so the
"decline" is a decision, not a default.

## The question

The warm daemon already speaks the full LSP protocol to PSES. Today it surfaces
exactly one capability -- **diagnostics** -- through one hook (`PostToolUse` on
`Write|Edit|MultiEdit`). PSES also serves rename, code actions, formatting,
workspace symbols, hover, and go-to-definition. Should any of those ride the hook
architecture too?

## The constraint that decides it

Claude Code hooks are **event-driven**: they fire on an edit, a session boundary, a
prompt submit. LSP capabilities split into two shapes against that model:

1. **Push / whole-artifact** -- computed *about a file* and delivered *because
   something happened to that file*. Diagnostics are the archetype: an edit happens,
   the file is analyzed, findings come back. This shape fits `PostToolUse` exactly,
   which is why diagnostics works and feels native.
2. **Pull / positional / intent-driven** -- answered *about a symbol at a position*
   and wanted *at the moment the model asks*: hover, definition, references, rename,
   prepareRename, workspace symbols, signature help. These need (a) a cursor
   position or symbol and (b) a "Claude wants to know this now" trigger. A hook
   carries neither -- it carries "a file was just edited."

The pull/positional features already have a correct home: **Claude Code's built-in
`LSP` tool** (`goToDefinition`, `findReferences`, `hover`, `rename`,
`documentSymbol`, `workspaceSymbol`, `incomingCalls`/`outgoingCalls`). That tool is
request-shaped and positional by design. For PowerShell it is inert today only
because plugin LSP-server **registration** is broken upstream (see
`docs/upstream/claude-code-lsp-registration.md`; tracked at claude-code#15168 /
#15148, plugins-official#379) -- not because the hook surface is missing.

So the choice for every positional feature is: build an awkward hook-shaped
imitation now, or let the feature land in its natural request-shaped home when
registration is fixed. Building the imitation creates a **second, competing
surface** that would have to be retired (and would double diagnostics-style) the day
native registration works -- the exact "workaround calcifying into architecture"
risk this proposal exists to avoid.

## Per-candidate calls

| Capability | Hook mechanism (if forced) | Cost | Benefit over CC built-in | Call |
|---|---|---|---|---|
| **Diagnostics** | `PostToolUse` (shipped) | warm daemon, ~2s/edit, bounded context | The built-in LSP tool has no "push findings after an edit" mode; the hook genuinely adds this | **Keep** (baseline; not a new surface) |
| **Document formatting** | `PostToolUse`: format the just-edited file | Would either silently apply edits behind Claude's output or emit advice it won't act on; churn risk; fights Claude's intended text | Claude already emits well-formatted PowerShell; PSSA `Invoke-Formatter` adds marginal value and real surprise | **Decline** |
| **Hover** | none that fits (no position in a hook payload) | n/a | Belongs to the built-in `hover`; reproducing it via hooks is the wrong shape | **Decline** |
| **Go-to-definition / find-references** | none that fits (positional, on demand) | n/a | The built-in `goToDefinition`/`findReferences` are the home; a hook cannot express "the model wants this now" | **Decline** |
| **Workspace symbols** | could push a symbol index at `SessionStart` | Indexing the whole workspace eagerly = startup latency + a large, mostly-unused context dump | The built-in `workspaceSymbol` is pull-shaped; an eager push is noise, not signal | **Decline** |
| **Rename** | none that fits (positional, mutating, needs confirm) | n/a + a disclaimer-gated, multi-file mutation is the worst fit for a fire-and-forget hook | The built-in `rename` is the home; PSES rename is also disclaimer-gated and v4.6.0-fragile (see Track B / #2297) | **Decline** |
| **Code actions** | none that fits (positional, interactive) | n/a | Pull-shaped and interactive; the built-in tool surface is where this belongs | **Decline** |

## Recommendation

**Decline all new surfaces; keep the plugin diagnostics-only.** Diagnostics is the
single PSES capability whose shape (push, whole-file, fires on edit) matches the
hook event model and adds something Claude Code's built-ins lack. Every other
capability is pull/positional and belongs to the native `LSP` tool, which is blocked
only by the registration bug Track C is watching. The right move is to keep the hook
lean and let those features arrive in their correct home when registration is fixed
-- not to grow a parallel, hook-shaped surface now that we would have to unwind
later.

If registration is ever fixed upstream (the Track C STOP condition), the follow-up
is **not** "add more hooks" -- it is the native-registration flip, which gets its own
dispatch and its own review (doubling-diagnostics guard, template-variable
expansion, hook-vs-native ownership). That is the moment to revisit positional
features, through the tool surface built for them.

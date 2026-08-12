# Feature request: an enum / select `userConfig` option type for Claude Code plugins

**Status re-derived: 2026-08-12 via gh; live state wins over this file.**

## ALREADY FILED AS #74289 -- DO NOT FILE THIS. Read this block before acting on anything below

**The ask in this document is already filed upstream, as part of
[`anthropics/claude-code#74289`](https://github.com/anthropics/claude-code/issues/74289)**
-- OPEN, filed 2026-07-04T22:17:56Z, last updated 2026-07-04T22:19:04Z, re-derived live with
`gh` on 2026-08-12. That issue's body carries this request **twice**:

- in a section headed **"Second, separate defect (enum options)"**, which states that every
  `userConfig` option renders as free text regardless of declared `type`, that the option
  schema is strict, that `type` is limited to `string|number|boolean|directory|file`, that an
  `enum` key is rejected, and which asks upstream to "consider an enum/select userConfig type,
  and a boolean toggle, in the config panel"; and
- as **suggested fix (c)**: "add an enum/select (and boolean) userConfig option type with a
  picker/toggle in the panel."

**Therefore the correct action on this file is NO ACTION.** Filing it -- as a new issue, as a
comment, or as any other upstream transmission -- would **duplicate #74289**. Do not do it. If
the enum ask needs to advance, it advances **on #74289**; and any upstream posting at all
remains Mike Andersen's gate and his alone, as it is for everything in this directory.

**This warning is in the file itself because the hazard is proven, not hypothetical.** This
repository has already caused one duplicate submission by trusting an on-disk status line that
had gone stale -- that incident is why `ROADMAP.md` carries its explicit catalog-submission
warning. Until 2026-08-12 this file opened "**What this is: a POST-READY DRAFT, UNPOSTED**" and
contained **zero** mention of #74289 anywhere in it. That is the same failure one step earlier,
and it is the dangerous direction: the rational move on a genuinely unfiled draft *is* to file
it, so a trusting reader -- human or agent -- would have done exactly the wrong thing for
exactly the right reason. An UNPOSTED label is not self-correcting. Nothing in this tree
notices when an issue elsewhere begins carrying the same ask, so the binding between draft and
upstream id has to be written into the draft's own text. It now is.

**What this file is now: RETAINED REFERENCE MATERIAL, not a pending submission.** The body
below is longer and more specific than the summary that actually reached #74289 -- it quotes
the shipped Zod schema verbatim, separates Option A (an optional `values` key) from Option B (a
sixth `type`), and carries the value/label refinement and the backward-compatibility analysis.
Keep it as the worked-out version of the argument, usable as raw material should Mike ever want
to comment on #74289. Do not delete it, and do not read its length as evidence that it is
unfiled.

---

## Reference draft (retained; its substance is already represented upstream by #74289)

**Provenance.** The schema evidence below was re-derived from the installed binary at write time by
dispatch 000197 leg 5 (Claude Code **2.1.223**, 2026-08-06). Dispatch 000195 leg F first derived the
same boundary at **2.1.221**; the nine-key `.strict()` object and the five-primitive `type` enum are
identical across both builds, so this is a stable shape rather than a snapshot of one release.

---

## Problem

A plugin's `userConfig` cannot declare that an option accepts one of a fixed set of values. Options
that are semantically an enumeration must ship as a free-form `string`, with the permitted values
described in prose that nothing enforces and the config dialog cannot render.

This plugin (`powershell-lsp`) has a concrete instance. Its `profile` knob is a preset selector with
exactly three valid values -- `safe`, `recommended`, `strict` -- and it must be declared as:

```json
"profile": {
  "type": "string",
  "title": "Configuration profile (preset for every other knob)",
  "description": "Compatibility (safe, the default), Recommended (recommended), Comprehensive (strict).",
  "default": "safe"
}
```

The consequences are all on the user's side of the dialog:

- **The config dialog shows a free-text box** for a field with three legal values, so the three
  names are text a reader has to notice in help prose rather than options they can pick.
- **Nothing validates the input.** A typo (`stict`) is accepted by the dialog and has to be caught,
  and then silently degraded, by the plugin at run time.
- **The values are documented in three places** -- the option `description`, the plugin's own
  `docs/configuration.md`, and its README -- and nothing keeps them agreeing with the code.

## The current schema, quoted verbatim

The shipped Zod schema for one `userConfig` option, extracted from the bundled binary at
`node_modules/@anthropic-ai/claude-code/bin/claude.exe` (Claude Code 2.1.223), reformatted only by
inserting line breaks between fields:

```js
w.object({
  type: w.enum(["string","number","boolean","directory","file"]).describe("Type of the configuration value"),
  title: w.string().describe("Human-readable label shown in the config dialog"),
  description: w.string().describe("Help text shown beneath the field in the config dialog"),
  required: w.boolean().optional().describe("If true, validation fails when this field is empty"),
  default: w.union([w.string(),w.number(),w.boolean(),w.array(w.string())]).optional().describe("Default value used when the user provides nothing"),
  multiple: w.boolean().optional().describe("For string type: allow an array of strings"),
  sensitive: w.boolean().optional().describe("If true, masks dialog input and stores value in secure storage (keychain/credentials file) instead of settings.json"),
  min: w.number().optional().describe("Minimum value (number type only)"),
  max: w.number().optional().describe("Maximum value (number type only)")
}).strict()
```

Two properties of that object are what make this a feature request rather than a documentation
question:

1. **`.strict()`** -- the option object permits exactly those **nine** keys. `values`, `enum`,
   `choices` and `options` are none of them, and under `.strict()` an unknown key is a validation
   **error**, not an ignored extra. So a plugin author cannot simply add a `values` array and have
   it be inert on older clients; it fails the manifest.
2. **`type` is itself a closed enum of five primitives** -- `string`, `number`, `boolean`,
   `directory`, `file`. There is no `enum` or `select` type to select.

Together those mean the gap is structural: a plugin cannot express "one of these values" at all.

## The ask

Allow a `userConfig` option to declare a fixed value set. Either shape would close it; the first is
the smaller change and is preferred:

**Option A -- an optional `values` field on the existing `string` type.**

```json
"profile": {
  "type": "string",
  "title": "Configuration profile",
  "description": "Preset for every other knob.",
  "default": "safe",
  "values": ["safe", "recommended", "strict"]
}
```

Adding one optional key to the strict object. When present, the dialog renders a picker and
validates the stored value against the list; when absent, behavior is exactly what it is today, so
every existing manifest is unaffected.

**Option B -- a sixth `type`, `"enum"` (or `"select"`), taking a required `values` array.**

More explicit about intent, at the cost of widening the `type` enum and adding a conditional
requirement between two fields.

**A useful refinement either way:** allow a value to carry a display label distinct from the stored
value, e.g. `[{"value":"safe","label":"Compatibility"}]` alongside the plain-string form. This
plugin already has that exact split -- the stored values are `safe` / `recommended` / `strict` while
the names shown to users are Compatibility / Recommended / Comprehensive -- and today the friendly
names can only live in description prose. Plain strings would still be accepted.

## Compatibility

Option A is additive and backward compatible: an optional key on an object that is already
`.strict()` means old manifests keep validating unchanged, and only manifests that opt in get the
new rendering. The one real consideration is the reverse direction -- a manifest declaring `values`
fails validation on any client older than the change, because `.strict()` rejects unknown keys. That
argues for treating `values` as a capability plugin authors adopt once they can require a minimum
Claude Code version, and it is worth being explicit about in whatever documents the field.

## Context

Found while building a PowerShell diagnostics plugin
(https://github.com/manderse21/claude-powershell-lsp), which ships twenty `userConfig` knobs. One is
a genuine enumeration (`profile`, three values) and several others are effectively enumerations
declared as strings for the same reason. The plugin currently validates these itself and degrades an
unrecognized value to a documented default, which works but puts the check after the dialog rather
than in it.

This is a feature request, not a bug report: the current schema behaves exactly as written. The
request is that the written behavior grow one case it does not cover.

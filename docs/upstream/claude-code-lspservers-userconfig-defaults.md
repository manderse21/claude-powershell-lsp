# Claude Code drops a plugin's `lspServers` when a `${user_config.*}` key is unset

**Status re-derived: 2026-08-17 via gh; live state wins over this file.**

`anthropics/claude-code#86936` -- **OPEN**, last updated 2026-08-15T15:54:30Z, re-derived live
with `gh issue view 86936 --repo anthropics/claude-code --json state,title,updatedAt`. The
downstream suspension recorded below therefore still stands.

## ALREADY FILED AS #86936 -- DO NOT FILE THIS

**This report is filed upstream as
[`anthropics/claude-code#86936`](https://github.com/anthropics/claude-code/issues/86936)** --
filed 2026-08-15 with Mike Andersen's explicit authorization in dispatch 000241. Filing it again
-- as a new issue, as a comment, or as any other upstream transmission -- would duplicate it. If
the report needs to advance, it advances **on #86936**; and any further upstream posting remains
Mike Andersen's gate and his alone, as it is for everything in this directory.

**What this is:** the internal record of a Claude Code defect discovered on 2026-08-15 while
closing dispatch 000233's installed-plugin integration proof. The text that was filed is in
[Proposed upstream report](#proposed-upstream-report) below, verbatim.

**Status:** OPEN, reproduced on **Claude Code 2.1.233** -- which was also the **latest published
version** at the time of filing (`npm view @anthropic-ai/claude-code version`), so there is no
newer release to upgrade into. Reproduced against the real marketplace-installed `powershell-lsp`
(main@`939048e`). Root cause isolated to a single missing call in the LSP loader, and re-derived
from the live binary on 2026-08-15 before the mitigation was written.

**Mitigation shipped downstream:** dispatch 000241 -- see
[RULING (dispatch 000241)](#ruling-dispatch-000241-option-1-with-an-explicit-suspension-record).

## Symptom

With `powershell-lsp` installed and only `nativeServe` explicitly configured, Claude Code refuses
the plugin's entire LSP definition at startup:

```
Failed to load LSP servers for plugin powershell-lsp: Error: Plugin option "profile" isn't set.
```

`profile` and `ps_host` both declare a `default` in the plugin's `userConfig` schema (`"safe"` and
`"pwsh"`). The declared defaults do not satisfy the reference. Once `profile` and `ps_host` were
explicitly materialized into `pluginConfigs[...].options`, the server registered and every native
operation passed.

The failure is **all-or-nothing per plugin**: one unresolved key discards every server the plugin
declares, not just the entry that referenced it. Other plugins are unaffected -- each plugin is
loaded in its own `try`/`catch`.

## Root cause

Claude Code ships as a compiled binary; the identifiers below are **minified and specific to
2.1.233**. They are quoted to make the defect checkable, not because they are stable API. All were
read from `bin/claude.exe` in `@anthropic-ai/claude-code@2.1.233`.

**The interpolator throws on any key absent from the map it is handed:**

```js
function zXt(e, t) {
  return e.replace(/\$\{user_config\.([^}]+)\}/g, (r, n) => {
    let o = t[n];
    if (o === void 0)
      throw Error(`Plugin option "${n}" isn't set. Open /plugin manage to configure it, or check that the plugin's userConfig schema declares "${n}".`);
    return String(o);
  });
}
```

**A defaults-merge helper exists, and is the thing that makes a declared `default` mean anything:**

```js
function $Yd(e, t) {                       // e = stored options, t = userConfig schema
  let r = {};
  for (let [n, o] of Object.entries(t)) {
    if (o.required && o.default === void 0) continue;
    r[n] = o.default ?? "";
  }
  return { ...r, ...e };                   // defaults first, explicit values win
}
```

**The option reader applies no schema at all** -- it returns stored values only:

```js
function hBe(e) { return e.source }
function $Q(e) {
  let { optionValues: t } = Nu();
  let r = t.get(e);
  if (r !== void 0) return r;
  let n = Z8o(e).options ?? {};                        // settings pluginConfigs[<key>].options
  let i = rl().read()?.pluginSecrets?.[e] ?? {};
  let s = { ...n, ...i };
  t.set(e, s);
  return s;
}
```

**The MCP/channels path merges defaults before interpolating -- correctly:**

```js
function fRb(e, t) {
  let r = e.manifest.userConfig;
  let o = e.manifest.channels?.find((a) => a.server === t)?.userConfig;
  if (!r && !o) return;
  let i = r ? $Q(hBe(e)) : void 0;
  let s = o ? jXt(e.repository, t) ?? void 0 : void 0;
  return $Yd({ ...i, ...s }, { ...r, ...o });          // <-- defaults merged
}
```

**The `lspServers` path does not:**

```js
async function zup(e, t = [], r) {
  if (!e.enabled) return;
  let n = e.lspServers || await dZt(e, t, r);
  if (!n) return;
  let o = e.manifest.userConfig ? $Q(hBe(e)) : void 0; // <-- raw stored options, no $Yd
  let i = {};
  for (let [s, a] of Object.entries(n)) i[s] = UBb(a, e, o, t);
  return BBb(i, e.name, e.repository);
}
```

`zup` hands `$Q(...)` -- stored options only -- straight to the interpolator. A key the user has
never explicitly set is `undefined`, so `zXt` throws, and the throw propagates to the per-plugin
catch in the loader:

```js
catch (s) {
  w(`Failed to load LSP servers for plugin ${o.name}: ${s}`, { level: "error" }),
  { plugin: o, scopedServers: void 0, errors: i }
}
```

**So: two sibling code paths in the same bundle interpolate the same `${user_config.*}` syntax
against differently-built option maps. The MCP path honors declared defaults. The LSP path does
not.** That asymmetry is the defect; the throw is downstream of it.

### Why it survived upstream

None of the **13** LSP plugins in `claude-plugins-official` declares a `userConfig` block at all --
`clangd`, `csharp`, `gopls`, `jdtls`, `kotlin`, `liquid`, `lua`, `php`, `pyright`, `ruby`,
`rust-analyzer`, `swift`, `typescript`. Not one references `${user_config.*}` inside `lspServers`.
The combination that trips this is, as far as this measurement can see, unexercised upstream.

### Proposed upstream fix

One call, matching the sibling path:

```js
let o = e.manifest.userConfig
  ? $Yd($Q(hBe(e)), e.manifest.userConfig)   // was: $Q(hBe(e))
  : void 0;
```

This makes a declared `userConfig.<key>.default` behave in `lspServers` the way it already behaves
for MCP servers, and the way the error message itself implies it should ("...or check that the
plugin's userConfig schema declares `<key>`" -- ours does).

## Blast radius for this plugin

The three `${user_config.*}` mappings in `lspServers.powershell.env` landed in `d563b84`
(dispatch 000233) and are **not in any tagged release** -- `git tag --contains d563b84` is empty,
and tagged `v1.31.1` carries only `PSES_BUNDLE_PATH` in that block. They are, however, **live in
the distribution channel**: `marketplace.json` sources the plugin at `./`, and the install record
for this machine reads `gitCommitSha: 939048e...` -- current `main` HEAD -- so a marketplace
install today pulls the mappings.

Consequence on 2.1.233, derived from the code above:

| stored options contain | outcome |
|---|---|
| all three of `profile`, `ps_host`, `nativeServe` | LSP server registers; native nav available |
| any subset, or none | **zero** LSP servers registered for `powershell-lsp`, plus a red startup error |

**Diagnostics are unaffected.** They run through the SessionStart / PostToolUse **hooks**, which do
receive `CLAUDE_PLUGIN_OPTION_*` and are loaded by a different path entirely. What a zero-config
user loses is the LSP server registration -- hover, go-to-definition, find-references -- plus the
error line.

### The configuration panel does not materialize defaults either -- MEASURED (dispatch 000241)

The open question in the first draft of this record was whether the `/plugin` configuration panel
pre-populates declared defaults into `pluginConfigs[...].options`, which would have scoped the
defect to hand-edited and headless configs. **It does not, on either half of its lifecycle.** Both
call sites were read from the same 2.1.233 binary.

**On open, every unset field is seeded EMPTY -- never from its declared `default`.** The panel is
handed `initialValues:$Q(bt)` -- the same defaults-free reader `zup` uses -- and its seeder
substitutes `""`, not the schema default:

```js
Uo.jsx(PQr,{ title:`Configure ${YT(V.plugin)}`, configSchema:k.schema,
             initialValues:$Q(bt),                        // stored options only; no $Yd
             onSave:async(_t)=>{ await hMr(bt,_t,k.schema,l) ... } })

// inside PQr, building form state (Kyt = Object.keys(configSchema), CBt = initialValues):
let Zew = JWe[XSh]?.sensitive===!0 ? void 0 : CBt?.[XSh];
Jew[XSh] = Zew === void 0 ? "" : String(Zew);             // <-- "", not o.default
```

So a user opening the panel is never shown the default the schema declares, and cannot accept it.

**On save, a field left blank is SKIPPED rather than written.** The submit reducer drops any
non-required, non-number key whose stored value is currently `undefined`:

```js
function ZSh(e,t,r,n){                    // e=keys, t=form values, r=schema, n=initialValues
  let o={};
  for (let i of e) {
    let s=r[i], l=((t[i]??"").split(/\r\n|\r|\n/,1)[0]??"").trim();
    if (l===""){
      if (s?.sensitive===!0 && n?.[i]!==void 0) continue;
      if (s?.type==="number") continue;
      if (s?.required!==!0 && n?.[i]===void 0) continue;  // <-- skipped, stays undefined
    }
    ... else o[i]=l;
  }
  return o;
}
```

The persist step then writes exactly what that reducer returned -- it never enumerates the schema
to fill gaps:

```js
let c=dn("userSettings")?.pluginConfigs?.[e]?.options??{}, u=Object.keys(c).filter((d)=>s.has(d));
if(Object.keys(o).length>0||u.length>0){ ... {pluginConfigs:{[e]:{options:{...o,...d}}}} ... }
```

**Consequence:** opening `/plugin configure <name>` and pressing **Save** without typing writes
nothing at all, the referenced keys stay `undefined`, and `zXt` still throws. Walking the panel is
not a workaround -- the user must type a value into every referenced field by hand. The blast
radius is therefore **every fresh install**, not only hand-edited or headless ones.

Corroborated on the proving machine: after a marketplace install of `939048e`,
`pluginConfigs["powershell-lsp@claude-powershell-lsp"].options` held exactly the three hand-set
keys, not the twenty declared ones. The sibling helper `THn` -- which computes *which options still
need configuring* and reads the same defaults-free `$Q` -- is consistent with this.

Note the interaction with the error message. It advises "Open /plugin manage to configure it, or
check that the plugin's userConfig schema declares `<key>`". The schema **does** declare it, and
opening the panel does not resolve it unless the user retypes a value the schema already carries.

## Where the fix belongs: BOTH

- **Upstream -- primary.** The asymmetry above is a genuine bug and only upstream can remove it.
  Until it lands, `${user_config.*}` in `lspServers.env` is a transport that works only for keys the
  user has explicitly typed, which is not what a `default` in a schema means anywhere else.
- **This plugin -- required now, independent of upstream.** We cannot ship a manifest whose LSP
  block fails to load on a default install while waiting for an upstream release. The mitigation is
  a real trade against dispatch 000233's verified ruling. **Adjudicated in dispatch 000241; the
  ruling is recorded below.**

Options considered, with the reason each is not simply "the answer":

1. **Revert the three mappings.** Restores universal loadability; would reinstate the silent
   configured-vs-effective divergence 000233 was raised to kill *unless* the gate is named.
2. **Keep the mappings, require explicit configuration.** Accepts a red error and zero LSP servers
   on every default install. **Disqualified by measurement** -- its precondition was that the
   install flow materializes declared defaults, and the panel measurement above shows it does not.
3. **Drop to a "safe subset" of mappings.** No such subset exists -- the throw is per missing key,
   so any single mapping breaks a zero-config install.
4. **Have the shim read the host's stored options itself.** Avoids the manifest throw, but
   duplicates host logic against an undocumented on-disk format and would have to re-implement
   settings precedence. Brittle.
5. **Mark the three knobs `required`.** Does not help: `zup` never calls `$Yd`. (It *does* change
   panel-save behavior -- `ZSh` persists a blank **required** key as `""` -- but only for a user
   who opens the panel, and `zup` still throws for everyone who does not.)
6. **Move the mappings to `args`, or add a fallback server.** Neither helps: `args` runs through the
   same `zXt` with the same option map, and `zup` is wrapped whole in the per-plugin `try`, so one
   throw discards every server the plugin declares.
7. **Carry the values through a side channel the plugin owns** (a SessionStart-written state file
   the shim reads). Would keep `nativeServe=shim` working through the gate, but adds a **second
   configuration resolver** -- against 000233's "one resolver" property -- plus staleness and
   hook-vs-spawn ordering risk, and would be hard to un-ship once upstream lands.

### RULING (dispatch 000241): option 1, with an explicit suspension record

Option 1, **plus retention of everything in 000233 that was not the manifest edit** -- the
provenance resolver, the `/doctor` configured-vs-effective check, and the derived-reachability
test. Option 7 is recorded as the documented escalation path, not taken now: it is not the smallest
mitigation and it trades away the single-resolver property. **This is a temporary compatibility
suspension, not a retreat from 000233** -- that ruling stands, its transport design remains the
intended architecture, and its installed-plugin proof remains valid.

What ships:

- The three `${user_config.*}` mappings are removed from `lspServers.powershell.env`. Nothing else
  in the manifest changes; `PSES_BUNDLE_PATH` and the `${CLAUDE_PLUGIN_ROOT}` argument resolve
  through `uPe`, which cannot throw, and were never implicated.
- A machine-readable **suspension record** (`Get-ServeTransportSuspension`, in
  `scripts/lib/lsp-common.ps1`) names each suspended knob, the affected Claude Code version, the
  gate, and **the exact condition that lifts it** -- together with the precise env name and mapping
  value to restore, so lifting the gate is a mechanical edit rather than a re-derivation.
- The serve log names the gate on every launch instead of emitting a bare `provenance: default`,
  which under the suspension would assert something false about the user.
- `/doctor` distinguishes three states, not two: **mapped**, **SUSPENDED BY UPSTREAM GATE** (stated,
  never a FAIL -- there is no action the user can take), and **unmapped for any other reason**
  (still a FAIL, so the guard keeps its teeth for a knob added to the shim and forgotten).
- Both test blocks are reconciled rather than weakened. The reachability derivation is retained; the
  mapping requirement becomes "mapped **or** explicitly suspended", and a reachable knob that is
  neither turns the suite red.

**Ordering:** the mitigation shipped first and the report was filed immediately after, independently.
2.1.233 was already the latest published release, so filing unblocks no user, while marketplace
installs track `main` HEAD today.

## Reproducer

Minimal, and independent of this plugin:

1. A plugin manifest declaring `userConfig: { "knob": { "type": "string", "default": "x" } }` and
   `lspServers: { "s": { ..., "env": { "K": "${user_config.knob}" } } }`.
2. Install it; do **not** set `knob` in `pluginConfigs[<plugin>].options`.
3. Start Claude Code 2.1.233.

Expected: the server loads with `K=x`. Actual: `Failed to load LSP servers for plugin <name>:
Error: Plugin option "knob" isn't set.`, and the plugin contributes no LSP servers.

Note that an inline `--plugin-dir` plugin is **not** a usable harness for this on 2.1.233 -- its
`lspServers` are never registered at all, which is the separate limitation recorded in dispatch
000233's deviations.

## Proposed upstream report

> **Title:** `lspServers` `${user_config.*}` interpolation ignores declared `userConfig` defaults,
> dropping the plugin's entire LSP definition
>
> **Version:** 2.1.233 (latest at time of filing), Windows 11, npm global install
>
> ### Summary
>
> A plugin that references `${user_config.<key>}` inside `lspServers.<server>.env` fails to load
> **all** of its LSP servers unless the user has explicitly set that key -- even when the plugin's
> `userConfig` schema declares a `default` for it:
>
> ```
> Failed to load LSP servers for plugin <name>: Error: Plugin option "<key>" isn't set.
> ```
>
> The same `${user_config.*}` syntax honors declared defaults for MCP servers. The MCP path builds
> its option map by merging the schema defaults under the stored values; the `lspServers` path
> passes the stored values alone to the same interpolator, which throws on `undefined`. So a
> `default` in `userConfig` is meaningful for one server type and inert for the other -- and the
> failure discards **every** server the plugin declares, not just the entry that referenced the key.
>
> ### Reproducer
>
> 1. A plugin manifest declaring `userConfig: { "knob": { "type": "string", "default": "x" } }` and
>    `lspServers: { "s": { ..., "env": { "K": "${user_config.knob}" } } }`.
> 2. Install it from a marketplace. Do **not** set `knob` in `pluginConfigs[<plugin>].options`.
> 3. Start Claude Code.
>
> **Expected:** the server loads with `K=x`, the declared default.
> **Actual:** `Failed to load LSP servers for plugin <name>: Error: Plugin option "knob" isn't set.`,
> and the plugin contributes **no** LSP servers at all.
>
> (An inline `--plugin-dir` plugin is not a usable harness here -- its `lspServers` are not
> registered on 2.1.233 regardless.)
>
> ### Control: the MCP path, same syntax, correct behavior
>
> The MCP/channels path merges schema defaults before interpolating; the `lspServers` path does not.
> The two differ by a single call:
>
> ```js
> // MCP -- merges defaults:
> return $Yd({ ...i, ...s }, { ...r, ...o });
>
> // lspServers -- does not:
> let o = e.manifest.userConfig ? $Q(hBe(e)) : void 0;   // raw stored options
> ```
>
> where `$Yd(stored, schema)` is the existing helper that applies `default ?? ""` under the stored
> values, and the interpolator throws on any key absent from the map it is handed.
>
> ### The configuration panel does not provide a way out
>
> The error advises "Open /plugin manage to configure it, or check that the plugin's userConfig
> schema declares `<key>`". The schema does declare it, and opening the panel does not help:
>
> - the panel is seeded from the same defaults-free option map, and renders an unset field as
>   **empty** rather than showing its declared default; and
> - its submit reducer **skips** a blank, non-required, non-number key whose stored value is
>   `undefined`, so pressing **Save** without typing writes nothing.
>
> A user must therefore retype, by hand, a value their plugin's schema already declares -- for every
> referenced key -- before any LSP server from that plugin will load.
>
> ### Suggested fix
>
> One call, matching the sibling path:
>
> ```js
> let o = e.manifest.userConfig
>   ? $Yd($Q(hBe(e)), e.manifest.userConfig)   // was: $Q(hBe(e))
>   : void 0;
> ```
>
> Separately, it may be worth considering whether one unresolved key should discard *every* server a
> plugin declares, or only the entry that referenced it.
>
> ### Impact
>
> Any plugin combining `userConfig` with `${user_config.*}` inside `lspServers` is unusable on a
> zero-configuration install. This appears to be unexercised upstream -- none of the 13 LSP plugins
> in `claude-plugins-official` declares a `userConfig` block at all. We hit it in
> [`powershell-lsp`](https://github.com/manderse21/claude-powershell-lsp) and have shipped a
> downstream mitigation (removing the references, and reading the affected options at their shipped
> defaults inside the server subprocess). That is a temporary compatibility workaround for this
> defect, not a fix: it costs us the only supported way to pass a user's configuration into an LSP
> server subprocess, so we would restore the references once declared defaults are honored here.

## What to watch for

- The fix would arrive silently in a routine 2.1.x bump. The regression block in
  `tests/PowerShellLsp.LspServerLoadability.Tests.ps1` pins the contract on **our** side; it does
  not detect an upstream fix. Re-run the reproducer against a new Claude Code before assuming the
  gate has lifted, the same way `docs/upstream/claude-code-lsp-registration.md` treats `#1359`.
- Upstream fixes in this area have shipped undocumented before (see
  `docs/upstream/` -- `#73961`, `#66987`, `#1359`), so absence from release notes is not evidence
  either way.

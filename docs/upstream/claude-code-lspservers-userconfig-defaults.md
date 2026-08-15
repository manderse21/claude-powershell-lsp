# Claude Code drops a plugin's `lspServers` when a `${user_config.*}` key is unset

**What this is:** the internal record of a Claude Code defect discovered on 2026-08-15 while
closing dispatch 000233's installed-plugin integration proof. **Not yet filed upstream** -- all
external posting is Mike's gate, as with every other record in this directory. The proposed issue
text is in [Proposed upstream report](#proposed-upstream-report) below, ready to paste.

**Status:** OPEN, reproduced on **Claude Code 2.1.233** against the real marketplace-installed
`powershell-lsp` (main@`939048e`). Root cause isolated to a single missing call in the LSP loader.

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

**Not measured here:** whether the `/plugin` install UI pre-populates declared defaults into
`pluginConfigs[...].options` for a user who walks the configuration panel. It did **not** happen for
this machine's install: after a marketplace install of `939048e`, the stored options map held
exactly the three hand-set keys, not the twenty declared ones. The sibling helper `THn` -- which
exists to compute *which options still need configuring*, and reads the same defaults-free `$Q` --
is consistent with defaults never being materialized, but that is inference, not measurement.

## Where the fix belongs: BOTH

- **Upstream -- primary.** The asymmetry above is a genuine bug and only upstream can remove it.
  Until it lands, `${user_config.*}` in `lspServers.env` is a transport that works only for keys the
  user has explicitly typed, which is not what a `default` in a schema means anywhere else.
- **This plugin -- required now, independent of upstream.** We cannot ship a manifest whose LSP
  block fails to load on a default install while waiting for an upstream release. The mitigation is
  a real trade against dispatch 000233's verified ruling and is **left for adjudication**, not
  chosen here. Adjudicated in **dispatch 000241**.

Options considered, with the reason each is not simply "the answer":

1. **Revert the three mappings.** Restores universal loadability; reinstates exactly the silent
   configured-vs-effective divergence 000233 was raised to kill. Straight trade, not a strict win.
2. **Keep the mappings, require explicit configuration.** Accepts a red error on every default
   install. Not viable as shipped behavior.
3. **Drop to a "safe subset" of mappings.** No such subset exists -- the throw is per missing key,
   so any single mapping breaks a zero-config install.
4. **Have the shim read the host's stored options itself.** Avoids the manifest throw, but
   duplicates host logic against an undocumented on-disk format and would have to re-implement
   settings precedence. Brittle.
5. **Mark the three knobs `required`.** Does not help: `zup` never calls `$Yd`, so `required`
   changes nothing on this path unless it also forces the user through the configuration panel --
   which is unverified, and would tax every install with three prompts.

The shape most likely to survive review is **(1) plus retention of everything in 000233 that was not
the manifest edit** -- the provenance resolver, the `/doctor` configured-vs-effective check, and the
derived-reachability test -- with the provenance line and doctor verdict restated to name the
upstream gate rather than reporting `default`. That converts a silent divergence into a stated one
while the manifest stays loadable. Recorded as a recommendation; the call is Mike's.

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
> **Version:** 2.1.233
>
> A plugin that references `${user_config.<key>}` inside `lspServers.<server>.env` fails to load
> **all** of its LSP servers unless the user has explicitly set that key, even when the plugin's
> `userConfig` schema declares a `default` for it:
>
> ```
> Failed to load LSP servers for plugin <name>: Error: Plugin option "<key>" isn't set.
> ```
>
> The same `${user_config.*}` syntax honors declared defaults for MCP servers. The MCP path builds
> its option map by merging the schema defaults under the stored values; the `lspServers` path
> passes the stored values alone to the same interpolator, which throws on `undefined`. The result
> is that a `default` in `userConfig` is meaningful in one server type and inert in the other, and
> the failure discards every server the plugin declares rather than the one entry that referenced
> the key.
>
> Repro and expected/actual as in [Reproducer](#reproducer) above.

## What to watch for

- The fix would arrive silently in a routine 2.1.x bump. The regression block in
  `tests/PowerShellLsp.LspServerLoadability.Tests.ps1` pins the contract on **our** side; it does
  not detect an upstream fix. Re-run the reproducer against a new Claude Code before assuming the
  gate has lifted, the same way `docs/upstream/claude-code-lsp-registration.md` treats `#1359`.
- Upstream fixes in this area have shipped undocumented before (see
  `docs/upstream/` -- `#73961`, `#66987`, `#1359`), so absence from release notes is not evidence
  either way.

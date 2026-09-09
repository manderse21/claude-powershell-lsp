# RED CONTROL for P2-1's metadata boundary (dispatch 000290).
#
# WHAT THIS IS, STATED HONESTLY. Every other red control in this suite is the PRIOR
# IMPLEMENTATION of a shipped function, taken verbatim from the merge base, because that is the
# only mutant that proves a fix fixed the thing that was actually broken. P2-1 has no prior
# implementation: scripts/lib/otel-common.ps1 is a new file and there was never an exporter that
# leaked a path. So this fixture is the NAIVE FIRST-CUT RENDERER instead -- the implementation a
# reasonable author writes when the allowlist has not occurred to them yet, which is to copy the
# row's own fields onto the metric. That is a weaker warrant than a prior implementation and it
# is recorded as such rather than presented as one.
#
# HOW IT IS LOADED. Dot-sourced AFTER scripts/lib/otel-common.ps1 by the same driver, so it
# overrides exactly ONE function -- ConvertTo-OtelRowAttributes -- and every other function in
# the render path resolves to the shipped copy.
#
# WHY OVERRIDING ONLY THAT ONE FUNCTION MATTERS. It is what gives the control a SURVIVING ARM.
# The duration gauges and the volume counters are computed by shipped code in both runs, so they
# must come out IDENTICAL under the mutant. If they did not, this fixture would be breaking the
# renderer rather than defeating the boundary, and the leak assertion would be passing for the
# wrong reason. The test asserts both halves: the path leaks, AND the timings are unchanged.
#
# ASCII only. Never dot-sourced by shipped code -- tests only.

function ConvertTo-OtelRowAttributes {
    # The naive version: every field on the row becomes an attribute. No allowlist, no
    # denylist, no thought about what a stats row happens to carry -- which is the whole
    # point, because what it carries is the absolute path of the edited file.
    param([object] $Record)
    $attrs = @()
    if ($null -eq $Record) { return @($attrs) }
    if ($null -eq $Record.PSObject) { return @($attrs) }
    foreach ($p in $Record.PSObject.Properties) {
        $attrs += (New-OtelAttribute -Key $p.Name -Value $p.Value)
    }
    return @($attrs)
}

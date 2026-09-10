#Requires -Version 5.1
# RED CONTROL for dispatch 000291 -- the NAIVE FIRST-CUT projection behind the doctor
# envelope's `otelExport` field.
#
# RECORDED HONESTLY FOR WHAT IT IS: this is NOT a prior implementation. The field is new in
# 000291 and nothing shipped before it, so there is no earlier version of this code to restore
# and the control is a weaker warrant than one that restores real history. What it IS is the
# implementation a careless first cut actually produces -- hand the envelope the resolver's own
# output and be done -- which is precisely the mistake Get-OtelEndpointReportInfo's allowlist
# exists to prevent. It is named as that rather than dressed up as a restored prior version.
#
# IT OVERRIDES EXACTLY ONE FUNCTION, which is what gives the control a SURVIVING ARM. Every
# other part of the envelope -- captureMode, the derived status, the summary counts, the check
# array -- is shipped code in BOTH runs and must come out identical, so a fixture that broke
# Format-DoctorJson instead of defeating the privacy boundary is caught rather than credited.
#
# ASCII-only (Windows PowerShell 5.1 reads a UTF-8-without-BOM file through Windows-1252).

function Get-OtelEndpointReportInfo {
    # The naive cut: publish the resolver's output verbatim. `endpoint` carries userinfo and
    # query intact, and `raw` carries whatever the environment said whether it parsed or not.
    return Get-OtelEndpointInfo
}

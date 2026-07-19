# Angle brackets inside strings and here-strings are literal text, not placeholders.
$html = '<b>bold</b>'
$generic = 'System.Collections.Generic.List<string>'
$doc = @'
<root><child /></root>
'@
Write-Output $html
Write-Output $generic
Write-Output $doc

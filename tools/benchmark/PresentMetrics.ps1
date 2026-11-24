# Functions for comparing explicitly selected PresentMon present intervals.
Set-StrictMode -Version Latest

function Get-NearestRank {
    param([double[]]$Sorted, [double]$Fraction)
    $index = [int][Math]::Ceiling($Fraction * $Sorted.Count) - 1
    return $Sorted[$index]
}

function Measure-PresentRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][uint32]$ProcessId,
        [Parameter(Mandatory)][string]$SwapChain,
        [ValidateRange(1, 2147483647)][int]$Skip = 1,
        [ValidateRange(0, 2147483647)][int]$Count = 0
    )
    if ($Rows.Count -eq 0) { throw 'The capture has no data rows.' }
    foreach ($field in @('ProcessID', 'SwapChainAddress', 'MsBetweenPresents')) {
        if ($null -eq $Rows[0].PSObject.Properties[$field]) {
            throw "Missing required CSV column: $field"
        }
    }

    # Never combine different swap chains or process instances. The first
    # interval in a capture can refer to a present before capture began.
    $selected = @($Rows | Where-Object {
        $_.ProcessID -eq [string]$ProcessId -and $_.SwapChainAddress -eq $SwapChain
    } | Select-Object -Skip $Skip)
    if ($Count -gt 0) {
        if ($selected.Count -lt $Count) { throw 'Requested window exceeds selected capture.' }
        $selected = @($selected | Select-Object -First $Count)
    }
    if ($selected.Count -eq 0) { throw 'No intervals in the selected window.' }

    $values = [System.Collections.Generic.List[double]]::new()
    $sum = 0.0
    foreach ($row in $selected) {
        $ms = 0.0
        $parsed = [double]::TryParse(
            [string]$row.MsBetweenPresents,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$ms
        )
        if (-not $parsed -or [double]::IsNaN($ms) -or
            [double]::IsInfinity($ms) -or $ms -le 0) {
            throw 'Invalid present interval in selected window; do not silently discard it.'
        }
        $values.Add($ms)
        $sum += $ms
    }
    if ([double]::IsInfinity($sum)) { throw 'Present duration overflow.' }
    $sorted = $values.ToArray()
    [Array]::Sort($sorted)
    return [pscustomobject]@{
        Intervals = $sorted.Count
        DurationSeconds = $sum / 1000.0
        PresentFPS = 1000.0 * $sorted.Count / $sum
        MeanMs = $sum / $sorted.Count
        P50Ms = Get-NearestRank -Sorted $sorted -Fraction 0.50
        P95Ms = Get-NearestRank -Sorted $sorted -Fraction 0.95
        P99Ms = Get-NearestRank -Sorted $sorted -Fraction 0.99
        MaxMs = $sorted[-1]
    }
}

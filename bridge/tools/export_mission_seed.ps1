$ErrorActionPreference = 'Stop'
$source = 'D:\AI-Shared\neruds-control-center\source\TREINAMENTO_NERUDS_Gestao_e_Preenchimento.xlsm'
$out = 'D:\AI-Shared\neruds-control-center\bridge\mission_seed.json'

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$excel.AskToUpdateLinks = $false
$excel.AutomationSecurity = 3
$book = $null

try {
  $book = $excel.Workbooks.Open($source, 0, $true)
  $result = [ordered]@{
    schema_version = 1
    source_file = [IO.Path]::GetFileName($source)
    imported_at = [DateTime]::UtcNow.ToString('o')
    sheets = [ordered]@{}
  }

  foreach ($sheet in $book.Worksheets) {
    $used = $sheet.UsedRange
    $rows = [int]$used.Rows.Count
    $cols = [int]$used.Columns.Count
    $values = $used.Value2
    $matrix = New-Object System.Collections.Generic.List[object]

    if ($rows -eq 1 -and $cols -eq 1) {
      $matrix.Add(@($values))
    } else {
      for ($r = 1; $r -le $rows; $r++) {
        $row = New-Object object[] $cols
        for ($c = 1; $c -le $cols; $c++) {
          $row[$c - 1] = $values[$r, $c]
        }
        $matrix.Add($row)
      }
    }

    $result.sheets[$sheet.Name] = $matrix.ToArray()
    [Runtime.InteropServices.Marshal]::ReleaseComObject($used) | Out-Null
    [Runtime.InteropServices.Marshal]::ReleaseComObject($sheet) | Out-Null
  }

  $json = $result | ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($out, $json, [Text.UTF8Encoding]::new($false))
}
finally {
  if ($book) {
    $book.Close($false)
    [Runtime.InteropServices.Marshal]::ReleaseComObject($book) | Out-Null
  }
  $excel.Quit()
  [Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
}

$j = Get-Content $out -Raw | ConvertFrom-Json
Write-Output ('SHEETS=' + $j.sheets.PSObject.Properties.Count)
Write-Output ('MASTER_ROWS=' + $j.sheets.'03_Controle_Master'.Count)
Write-Output ('BYTES=' + (Get-Item $out).Length)

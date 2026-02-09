return

[[
# 1. 基础环境检查
if (-not (Test-Path $EnigmaPath)) { Write-Host "Error: Enigma tool not found at $EnigmaPath" -ForegroundColor Red; exit }
$ExeFiles = Get-ChildItem -Path $SourceDir -Filter "*.exe"
if ($ExeFiles.Count -eq 0) { Write-Host "Error: No EXE found in $SourceDir" -ForegroundColor Red; exit }

# 2. 递归生成文件树函数
function Get-EvbTree {
    param ([string]$Path, [string]$Indent)
    $xml = ""
    $items = Get-ChildItem -Path $Path
    
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            # 文件夹节点
            $xml += "$Indent<File>`n"
            $xml += "$Indent  <Type>1</Type>`n"
            $xml += "$Indent  <Name>$($item.Name)</Name>`n"
            $xml += "$Indent  <Files>`n"
            $xml += Get-EvbTree -Path $item.FullName -Indent "$Indent    "
            $xml += "$Indent  </Files>`n"
            $xml += "$Indent</File>`n"
        } else {
            # 跳过主程序本身
            if ($item.Name -eq $MainExeName -and $item.DirectoryName -eq $SourceDir) { continue }
            
            # 文件节点 (Action 0 = 纯内存虚拟化)
            $xml += "$Indent<File>`n"
            $xml += "$Indent  <Type>2</Type>`n"
            $xml += "$Indent  <Name>$($item.Name)</Name>`n"
            $xml += "$Indent  <File>$($item.FullName)</File>`n"
            $xml += "$Indent  <ActiveX>false</ActiveX>`n"
            $xml += "$Indent  <ActiveXInstall>false</ActiveXInstall>`n"
            $xml += "$Indent  <Action>0</Action>`n"
            $xml += "$Indent  <OverwriteDateTime>false</OverwriteDateTime>`n"
            $xml += "$Indent  <OverwriteAttributes>false</OverwriteAttributes>`n"
            $xml += "$Indent  <PassCommandLine>false</PassCommandLine>`n"
            $xml += "$Indent</File>`n"
        }
    }
    return $xml
}

# 3. 构造并保存 XML
Write-Host "Scanning $SourceDir ..." -ForegroundColor Cyan
$TreeContent = Get-EvbTree -Path $SourceDir -Indent "          "

$Header = @"
<?xml version="1.0" encoding="UTF-8"?>
<>
  <InputFile>$SourceDir\$MainExeName</InputFile>
  <OutputFile>$OutputFile</OutputFile>
  <Files>
    <Enabled>true</Enabled>
    <DeleteExtractedOnExit>false</DeleteExtractedOnExit>
    <CompressFiles>false</CompressFiles>
    <Files>
      <File>
        <Type>3</Type>
        <Name>%DEFAULT FOLDER%</Name>
        <Files>
"@

$Footer = @"
        </Files>
      </File>
    </Files>
  </Files>
  <Registries><Enabled>false</Enabled></Registries>
  <Packaging><Enabled>false</Enabled></Packaging>
  <Options>
    <ShareVirtualSystem>true</ShareVirtualSystem>
    <MapExecutableWithTemporaryFile>true</MapExecutableWithTemporaryFile>
    <AllowRunningOfVirtualExeFiles>true</AllowRunningOfVirtualExeFiles>
    <HandleExceptions>false</HandleExceptions>
    <RegisterAllVirtualModules>true</RegisterAllVirtualModules>
    <InlineVirtualization>true</InlineVirtualization>
  </Options>
</>
"@

$FinalXml = $Header + $TreeContent + $Footer
Set-Content -Path $EvbProjectFile -Value $FinalXml -Encoding UTF8

# 4. 执行打包
Write-Host "Packing into Single EXE..." -ForegroundColor Green
& $EnigmaPath $EvbProjectFile

# 5. 清理与结果反馈
Write-Host "Cleaning up temporary project file..." -ForegroundColor Gray
if (Test-Path $EvbProjectFile) { Remove-Item $EvbProjectFile -Force }

if (Test-Path $OutputFile) {
    Write-Host "`n[SUCCESS] $OutputFile created successfully!" -ForegroundColor Green
} else {
    Write-Host "`n[FAILED] Packing failed." -ForegroundColor Red
}
]]
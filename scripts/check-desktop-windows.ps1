#requires -Version 7.2
<#
.SYNOPSIS
Checks the real Windows desktop engine in a new, disposable UTF-8 library.
.EXAMPLE
pwsh -File scripts/check-desktop-windows.ps1 -EnginePath .build/rust/release/posle-engine.exe
.EXAMPLE
pwsh -File scripts/check-desktop-windows.ps1 -EnginePath .build/rust/release/posle-engine.exe -InstallerPath After-setup.exe -ReceiptPath .build/windows-smoke.json
.NOTES
-AppPath and -InstallerPath may run only on a fresh GitHub Actions Windows
runner. They never redirect release data with a hidden app flag. A pre-existing
app.posle.desktop profile causes an immediate failure and is never removed.
No shell, account, model, network provider or personal library is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EnginePath,
    [string]$AppPath,
    [string]$InstallerPath,
    [string]$ReceiptPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This smoke check requires Windows and PowerShell 7.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::X64) { throw 'This installer smoke requires a real Windows x64 runner.' }
if ($AppPath -and $InstallerPath) { throw 'Choose an installed -AppPath or an -InstallerPath, not both.' }

# C# owns async pipe draining so no PowerShell script block needs a background
# runspace. All streams are bounded while reading; each child has a deadline.
if (-not ('AfterPreviewProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class AfterPreviewProcessResult {
    public int ExitCode { get; set; }
    public string Stdout { get; set; }
    public string Stderr { get; set; }
}
public static class AfterPreviewProcess {
    static async Task<byte[]> ReadBounded(Stream stream, int limit, CancellationToken token) {
        using (stream) using (var output = new MemoryStream()) {
            byte[] buffer = new byte[16384];
            while (true) {
                int count = await stream.ReadAsync(buffer, 0, buffer.Length, token);
                if (count == 0) return output.ToArray();
                if (output.Length + count > limit) throw new InvalidDataException("Child output exceeded its limit.");
                output.Write(buffer, 0, count);
            }
        }
    }
    static async Task WriteInput(Stream stream, byte[] payload, CancellationToken token) {
        using (stream) { await stream.WriteAsync(payload, 0, payload.Length, token); }
    }
    static ProcessStartInfo StartInfo(string executable, string directory) {
        var info = new ProcessStartInfo(executable) {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        info.Environment.Clear();
        foreach (string name in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG", "LC_ALL" }) {
            string value = Environment.GetEnvironmentVariable(name);
            if (value != null) info.Environment[name] = value;
        }
        return info;
    }
    public static AfterPreviewProcessResult Run(string executable, string[] arguments, string directory, byte[] payload) {
        var info = StartInfo(executable, directory);
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        return RunAsync(info, payload, 30000).GetAwaiter().GetResult();
    }
    public static AfterPreviewProcessResult Install(string executable, string directory) {
        var info = StartInfo(executable, Path.GetDirectoryName(executable));
        // NSIS requires /D last and unquoted, even for a path with spaces. This
        // is a direct process argument string, never cmd.exe or a shell command.
        info.Arguments = "/S /D=" + directory;
        return RunAsync(info, Array.Empty<byte>(), 180000).GetAwaiter().GetResult();
    }
    static async Task<AfterPreviewProcessResult> RunAsync(ProcessStartInfo info, byte[] payload, int timeout) {
        using (var process = new Process { StartInfo = info })
        using (var cancel = new CancellationTokenSource(timeout)) {
            bool started = false;
            try {
                if (!process.Start()) throw new IOException("The fixture process could not start.");
                started = true;
                var stdout = ReadBounded(process.StandardOutput.BaseStream, 8 * 1024 * 1024, cancel.Token);
                var stderr = ReadBounded(process.StandardError.BaseStream, 64 * 1024, cancel.Token);
                var writer = WriteInput(process.StandardInput.BaseStream, payload, cancel.Token);
                await Task.WhenAll(stdout, stderr, writer, process.WaitForExitAsync(cancel.Token)).WaitAsync(cancel.Token);
                var utf8 = new UTF8Encoding(false, true);
                return new AfterPreviewProcessResult { ExitCode = process.ExitCode,
                    Stdout = utf8.GetString(await stdout), Stderr = utf8.GetString(await stderr) };
            } finally {
                if (started && !process.HasExited) { process.Kill(true); process.WaitForExit(5000); }
            }
        }
    }
}
'@
}
function Assert-Smoke([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Resolve-RegularExecutable([string]$Candidate) {
    $item = Get-Item -LiteralPath $Candidate
    Assert-Smoke ($item -is [System.IO.FileInfo] -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) 'Expected a regular executable, not a link or junction.'
    Assert-Smoke ($item.Extension -ieq '.exe') 'Expected a Windows executable.'
    return $item.FullName
}
function Get-PeMachine([string]$Executable) {
    $stream = [System.IO.File]::OpenRead($Executable)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        Assert-Smoke ($stream.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5A4D) 'Invalid Windows MZ executable.'
        $stream.Position = 60
        $offset = $reader.ReadUInt32()
        Assert-Smoke ($offset -le $stream.Length - 6) 'Invalid Windows PE header offset.'
        $stream.Position = $offset
        Assert-Smoke ($reader.ReadUInt32() -eq 0x00004550) 'Invalid Windows PE signature.'
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}
$engine = Resolve-RegularExecutable $EnginePath
Assert-Smoke ((Get-PeMachine $engine) -eq 0x8664) 'The staged engine is not an AMD64 PE executable.'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('after-windows-smoke-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixture)
$library = Join-Path $fixture 'библиотека с пробелами café'
[void][System.IO.Directory]::CreateDirectory($library)
$passes = [System.Collections.Generic.List[string]]::new()
$applicationData = $null
$applicationOwner = [guid]::NewGuid().ToString('N')
$appProcess = $null
$junction = $null
$installRoot = $null
$cleanupProfile = $false
$receipt = [ordered]@{
    platform = 'windows-x64'; engineSha256 = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
    syntheticDataOnly = $true; checks = $passes; nativeApp = $false; installer = $false
}
function Invoke-Engine([string]$Command, [hashtable]$Arguments = @{}, [string]$DataRoot = $library) {
    $json = @{ command = $Command; arguments = $Arguments } | ConvertTo-Json -Depth 20 -Compress
    $payload = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($json)
    Assert-Smoke ($payload.Length -le 262144) 'Smoke payload exceeded the real bridge request bound.'
    $result = [AfterPreviewProcess]::Run($engine, @('desktop-bridge', '--root', $DataRoot), $fixture, $payload)
    Assert-Smoke ($result.ExitCode -eq 0) "Engine exited unsuccessfully for $Command (code $($result.ExitCode))."
    $envelope = $result.Stdout | ConvertFrom-Json -AsHashtable
    Assert-Smoke ($envelope.ok -is [bool]) 'Engine envelope has no boolean result.'
    return $envelope
}
function Expect-Result([hashtable]$Envelope) {
    if ($Envelope.ok -ne $true) { throw ('Unexpected domain failure: ' + $Envelope.error.code) }
    return $Envelope.result
}
try {
    $initial = Expect-Result (Invoke-Engine 'get_workspace')
    Assert-Smoke (@($initial.notes).Count -eq 0 -and @($initial.folders).Count -eq 0 -and @($initial.meetings).Count -eq 0) 'A fresh library was not empty.'
    Assert-Smoke ($initial.capabilities.library -eq $true -and $initial.capabilities.recording -eq $false -and $initial.capabilities.assistant -eq $false) 'Preview capabilities are inaccurate.'
    $passes.Add('fresh-canonical-library-and-explicit-capabilities')

    $folder = Expect-Result (Invoke-Engine 'save_folder' @{ input = @{ name = 'Английский café' } })
    Assert-Smoke ($folder.name -ceq 'Английский café') 'Folder UTF-8 content was corrupted.'
    $note = Expect-Result (Invoke-Engine 'save_note' @{ input = @{ title = 'Проверка UTF-8'; text = 'Windows marker путешествия café 🚀'; folderId = $folder.id } })
    Assert-Smoke ($note.text -ceq 'Windows marker путешествия café 🚀' -and $note.folderId -ceq $folder.id) 'The note or its folder was corrupted.'
    $updatedInput = @{ id = $note.id; title = 'Updated note'; text = 'Durable marker сохранён 🚀'; expectedRevision = $note.revision }
    $updated = Expect-Result (Invoke-Engine 'save_note' @{ input = $updatedInput })
    Assert-Smoke ($updated.revision -gt $note.revision -and $updated.folderId -ceq $folder.id) 'Partial note editing lost its folder or revision.'
    $stale = Invoke-Engine 'save_note' @{ input = $updatedInput }
    Assert-Smoke ($stale.ok -eq $false -and $stale.error.code -ceq 'conflict') 'Stale note edits were accepted.'
    $folderStale = Invoke-Engine 'save_folder' @{ input = @{ id = $folder.id; name = 'Wrong rename'; expectedRevision = 999999 } }
    Assert-Smoke ($folderStale.ok -eq $false -and $folderStale.error.code -ceq 'conflict') 'Stale folder edits were accepted.'
    $passes.Add('utf8-note-save-partial-edit-and-note-folder-cas')

    $other = Expect-Result (Invoke-Engine 'save_folder' @{ input = @{ name = 'Другой контекст' } })
    $hit = Expect-Result (Invoke-Engine 'search_library' @{ query = 'marker'; folderId = $folder.id; limit = 40 })
    Assert-Smoke (@($hit.hits | Where-Object { $_.noteId -ceq $note.id }).Count -gt 0) 'Real search did not find the saved note.'
    $notInOther = Expect-Result (Invoke-Engine 'search_library' @{ query = 'marker'; folderId = $other.id; limit = 40 })
    Assert-Smoke (@($notInOther.hits).Count -eq 0) 'Folder search leaked a note from another folder.'
    $again = Expect-Result (Invoke-Engine 'get_workspace')
    $reopened = @($again.notes | Where-Object { $_.id -ceq $note.id })
    Assert-Smoke ($reopened.Count -eq 1 -and $reopened[0].text -ceq $updated.text -and $reopened[0].revision -eq $updated.revision) 'A new engine process did not reopen the committed note.'
    $reopenedFolder = @($again.folders | Where-Object { $_.id -ceq $folder.id })
    Assert-Smoke ($reopenedFolder.Count -eq 1 -and $reopenedFolder[0].name -ceq $folder.name -and $reopenedFolder[0].revision -eq $folder.revision) 'A rejected stale folder edit changed committed data.'
    Assert-Smoke ((Get-Item -LiteralPath (Join-Path $library 'core.sqlite')).Length -gt 0) 'Canonical SQLite was not created.'
    $passes.Add('real-search-folder-scope-and-durability-across-processes')

    # A valid synthetic PCM WAV; both source and library live inside the new
    # temporary fixture, never in the user's library.
    $source = Join-Path $fixture 'исходная запись café.wav'
    $wavStream = [System.IO.MemoryStream]::new()
    $wavWriter = [System.IO.BinaryWriter]::new($wavStream)
    try {
        $wavWriter.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $wavWriter.Write([uint32]236)
        $wavWriter.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $wavWriter.Write([uint32]16)
        $wavWriter.Write([uint16]1); $wavWriter.Write([uint16]1)
        $wavWriter.Write([uint32]8000); $wavWriter.Write([uint32]16000)
        $wavWriter.Write([uint16]2); $wavWriter.Write([uint16]16)
        $wavWriter.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $wavWriter.Write([uint32]200)
        for ($i = 0; $i -lt 100; $i++) { $wavWriter.Write([int16]($i * 200 - 10000)) }
        $wavWriter.Flush()
        $wavBytes = $wavStream.ToArray()
    } finally { $wavWriter.Dispose(); $wavStream.Dispose() }
    [System.IO.File]::WriteAllBytes($source, $wavBytes)
    $originalHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $meeting = Expect-Result (Invoke-Engine 'import_meeting' @{ sourcePath = $source; focus = ''; title = 'Тестовая запись café' })
    Assert-Smoke ($meeting.title -ceq 'Тестовая запись café' -and $meeting.hasMedia -eq $true -and $meeting.mediaKind -ceq 'audio') 'Imported meeting metadata is incorrect.'
    Assert-Smoke ($null -eq $meeting.folderId) 'New imports should start in the unfiled library.'
    $detail = Expect-Result (Invoke-Engine 'get_meeting' @{ meetingId = $meeting.id })
    Assert-Smoke ($detail.meeting.hasMedia -eq $true -and $detail.meeting.mediaKind -ceq 'audio') 'A new engine process did not reopen imported media.'
    $stored = Join-Path (Join-Path (Join-Path $library 'meetings') $meeting.id) 'source.wav'
    Assert-Smoke ((Get-FileHash -LiteralPath $stored -Algorithm SHA256).Hash -ceq $originalHash) 'Imported media does not match its source.'
    $part = Expect-Result (Invoke-Engine 'read_media_chunk' @{ meetingId = $meeting.id; offset = 6; length = 11 })
    $expectedPart = [Convert]::ToBase64String([byte[]]$wavBytes[6..16])
    Assert-Smoke ($part.offset -eq 6 -and $part.totalBytes -eq $wavBytes.Length -and $part.contentType -ceq 'audio/wav' -and $part.dataBase64 -ceq $expectedPart) 'Media seeking or byte range returned incorrect data.'
    $tailOffset = $wavBytes.Length - 3
    $tail = Expect-Result (Invoke-Engine 'read_media_chunk' @{ meetingId = $meeting.id; offset = $tailOffset; length = 100 })
    Assert-Smoke ($tail.dataBase64 -ceq [Convert]::ToBase64String([byte[]]$wavBytes[$tailOffset..($wavBytes.Length - 1)])) 'Media range did not clamp at end of file.'
    $eof = Expect-Result (Invoke-Engine 'read_media_chunk' @{ meetingId = $meeting.id; offset = $wavBytes.Length; length = 1 })
    Assert-Smoke ($eof.dataBase64 -ceq '') 'End-of-file returned unexpected data.'
    $badRange = Invoke-Engine 'read_media_chunk' @{ meetingId = $meeting.id; offset = 0; length = 1048577 }
    $badId = Invoke-Engine 'read_media_chunk' @{ meetingId = '../outside'; offset = 0; length = 1 }
    Assert-Smoke (-not $badRange.ok -and -not $badId.ok) 'Invalid media range or traversal was accepted.'
    Assert-Smoke ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ceq $originalHash) 'Import or reads modified the original WAV.'
    $passes.Add('synthetic-wav-import-media-seek-and-original-preservation')

    $task = Expect-Result (Invoke-Engine 'create_task' @{ title = 'Подготовить встречу'; text = 'Synthetic task'; operationId = 'smoke-create-task' })
    Assert-Smoke ($task.title -ceq 'Подготовить встречу') 'Task creation lost its Unicode title.'
    $taskUpdate = @{ taskId = $task.id; expectedRevision = $task.revision; operationId = 'smoke-update-task'; patch = @{ status = 'done' } }
    $done = Expect-Result (Invoke-Engine 'update_task' $taskUpdate)
    Assert-Smoke ($done.completed -eq $true) 'Task completion was not saved.'
    $taskUpdate.operationId = 'smoke-stale-task'
    $taskConflict = Invoke-Engine 'update_task' $taskUpdate
    Assert-Smoke (-not $taskConflict.ok -and $taskConflict.error.code -ceq 'conflict') 'A stale task update was accepted.'
    $reopenedTask = Expect-Result (Invoke-Engine 'get_task' @{ taskId = $task.id })
    Assert-Smoke ($reopenedTask.status -ceq 'done' -and $reopenedTask.title -ceq $task.title) 'A stale task update changed committed data.'
    $passes.Add('task-completion-stale-update-and-reopen')

    $savedCard = Expect-Result (Invoke-Engine 'save_card' @{ front = 'Hello'; back = 'Привет'; newDeckTitle = 'Synthetic cards' })
    $cards = Expect-Result (Invoke-Engine 'list_cards')
    $matchingCards = @($cards.cards | Where-Object { $_.meetingId -ceq $savedCard.meetingId -and $_.card.id -ceq $savedCard.card.id })
    Assert-Smoke ($matchingCards.Count -eq 1 -and $matchingCards[0].card.back -ceq 'Привет') 'Card was not persisted with its text.'
    $card = $matchingCards[0]
    $reference = @{ meetingId = $card.meetingId; cardId = $card.card.id; expectedFingerprint = $card.fingerprint; expectedReviewFingerprint = $card.reviewFingerprint }
    $preview = Expect-Result (Invoke-Engine 'preview_card_review' $reference)
    Assert-Smoke (@($preview.options).Count -eq 4) 'Card review did not expose the expected options.'
    $reference.rating = 3
    $review = Expect-Result (Invoke-Engine 'review_card' $reference)
    Assert-Smoke ($review.state.count -eq 1) 'Card review was not saved.'
    $staleReview = Invoke-Engine 'review_card' $reference
    Assert-Smoke (-not $staleReview.ok -and $staleReview.error.code -ceq 'conflict') 'A stale card review was accepted.'
    [void](Expect-Result (Invoke-Engine 'undo_card_review' @{ meetingId = $review.meetingID; undoId = $review.undoID }))
    $cardsAfter = Expect-Result (Invoke-Engine 'list_cards')
    $after = @($cardsAfter.cards | Where-Object { $_.meetingId -ceq $card.meetingId -and $_.card.id -ceq $card.card.id })
    Assert-Smoke ($after.Count -eq 1 -and $null -eq $after[0].review -and $after[0].card.back -ceq 'Привет') 'Card undo or stale review damaged the card.'
    $passes.Add('cards-review-stale-update-and-undo')

    $preserved = Expect-Result (Invoke-Engine 'get_workspace')
    $oldNote = @($preserved.notes | Where-Object { $_.id -ceq $note.id })
    Assert-Smoke ($oldNote.Count -eq 1 -and $oldNote[0].text -ceq $updated.text -and $oldNote[0].folderId -ceq $folder.id) 'Import or task/card operations modified an existing note.'
    Assert-Smoke ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ceq $originalHash) 'A later operation modified the original WAV.'
    $passes.Add('prior-library-and-original-remain-unchanged')

    $outside = Join-Path $fixture 'outside-junction-target'
    [void][System.IO.Directory]::CreateDirectory($outside)
    $canary = Join-Path $outside 'untouched.txt'
    [System.IO.File]::WriteAllText($canary, 'must remain unchanged')
    $junction = Join-Path $fixture 'linked-library'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    $refused = Invoke-Engine 'get_workspace' @{} $junction
    Assert-Smoke ($refused.ok -eq $false) 'A junction was accepted as the library root.'
    Assert-Smoke (([System.IO.File]::ReadAllText($canary) -ceq 'must remain unchanged') -and @([System.IO.Directory]::EnumerateFileSystemEntries($outside)).Count -eq 1) 'Junction refusal changed its external target.'
    $passes.Add('junction-root-refused-with-external-target-unchanged')

    if ($AppPath -or $InstallerPath) {
        Assert-Smoke ($env:GITHUB_ACTIONS -ceq 'true') 'Native install/app smoke is restricted to a disposable GitHub Actions Windows runner.'
        $applicationData = Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)) 'app.posle.desktop'
        $profileExists = $false
        try { [void][System.IO.File]::GetAttributes($applicationData); $profileExists = $true }
        catch [System.IO.FileNotFoundException] { }
        catch [System.IO.DirectoryNotFoundException] { }
        Assert-Smoke (-not $profileExists) 'Refusing a pre-existing desktop profile, including a broken link; nothing was removed.'
        if ($InstallerPath) {
            $installer = Resolve-RegularExecutable $InstallerPath
            $installRoot = Join-Path $fixture 'installed-After'
            $installed = [AfterPreviewProcess]::Install($installer, $installRoot)
            Assert-Smoke ($installed.ExitCode -eq 0) 'The NSIS installer failed.'
            $candidates = @(Get-ChildItem -LiteralPath $installRoot -File -Filter '*.exe' | Where-Object { $_.BaseName -like 'After*' -and $_.Name -notlike '*uninstall*' })
            Assert-Smoke ($candidates.Count -eq 1) 'The installer did not produce exactly one After application executable.'
            $AppPath = $candidates[0].FullName
            $receipt.installer = $true
            $receipt.installerSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $application = Resolve-RegularExecutable $AppPath
        Assert-Smoke ((Get-PeMachine $application) -eq 0x8664) 'The installed app is not an AMD64 PE executable.'
        [void][System.IO.Directory]::CreateDirectory($applicationData)
        [System.IO.File]::WriteAllText((Join-Path $applicationData '.after-ci-smoke-owner'), $applicationOwner)
        $cleanupProfile = $true
        $start = [System.Diagnostics.ProcessStartInfo]::new($application)
        $start.UseShellExecute = $false
        $start.WorkingDirectory = Split-Path -Parent $application
        foreach ($key in @($start.Environment.Keys)) {
            if ($key -match '^(AFTER_|POSLE_)' -or $key -match '(API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)') { [void]$start.Environment.Remove($key) }
        }
        $appProcess = [System.Diagnostics.Process]::Start($start)
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $buttonNames = @('New note', 'Новая заметка')
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $deadline) {
            $appProcess.Refresh()
            Assert-Smoke (-not $appProcess.HasExited) 'The installed app exited before its WebView could load.'
            if ($appProcess.MainWindowHandle -ne [IntPtr]::Zero -and (Test-Path -LiteralPath (Join-Path $applicationData 'core.sqlite'))) {
                $window = [System.Windows.Automation.AutomationElement]::FromHandle($appProcess.MainWindowHandle)
                foreach ($name in $buttonNames) {
                    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $name)
                    $control = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
                    if ($null -ne $control -and $control.Current.IsEnabled) { $ready = $true; break }
                }
                if ($ready) { break }
            }
            Start-Sleep -Milliseconds 250
        }
        Assert-Smoke $ready 'The release WebView did not expose its New note control and create SQLite through native IPC.'
        $receipt.nativeApp = $true
        $passes.Add('installed-release-webview-to-native-ipc-and-bundled-sqlite')
        Assert-Smoke ($appProcess.CloseMainWindow()) 'The installed app did not accept a normal window-close request.'
        Assert-Smoke ($appProcess.WaitForExit(10000)) 'The clean installed app could not close normally; force termination must not hide a window-permission failure.'
        $appProcess.Dispose(); $appProcess = $null
        $nativeWorkspace = Expect-Result (Invoke-Engine 'get_workspace' @{} $applicationData)
        Assert-Smoke (@($nativeWorkspace.notes).Count -eq 0 -and @($nativeWorkspace.folders).Count -eq 0) 'The installed UI did not initialize a clean canonical library.'
    }
    $receipt.passed = $true
    if ($ReceiptPath) {
        $resolvedReceipt = [System.IO.Path]::GetFullPath($ReceiptPath)
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $resolvedReceipt))
        [System.IO.File]::WriteAllText($resolvedReceipt, (($receipt | ConvertTo-Json -Depth 10) + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
    foreach ($check in $passes) { Write-Host "PASS: $check" }
} finally {
    if ($null -ne $appProcess) {
        if (-not $appProcess.HasExited) { $appProcess.Kill($true); [void]$appProcess.WaitForExit(5000) }
        $appProcess.Dispose()
    }
    if ($junction) {
        try { [System.IO.Directory]::Delete($junction) }
        catch [System.IO.DirectoryNotFoundException] { }
    }
    if ($cleanupProfile -and $applicationData) {
        $marker = Join-Path $applicationData '.after-ci-smoke-owner'
        if ((Test-Path -LiteralPath $marker) -and ([System.IO.File]::ReadAllText($marker) -ceq $applicationOwner)) {
            Remove-Item -LiteralPath $applicationData -Recurse -Force
        }
    }
    if ($installRoot -and (Test-Path -LiteralPath $installRoot)) {
        # NSIS may register uninstall metadata; use only the uninstaller inside
        # this run's exact private destination before deleting the fixture.
        $uninstallers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter '*uninstall*.exe')
        foreach ($uninstaller in $uninstallers) {
            $cleanup = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/S' -PassThru -Wait
            if ($cleanup.ExitCode -ne 0) { Write-Warning 'The disposable installer uninstaller did not finish cleanly.' }
        }
    }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

$ErrorActionPreference = "Stop"

$Port = 8765
$OwnerEmail = "big.joe@rsu.edu.ng"
$DefaultAdminPassword = "081big@joe"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DatabaseName = "DIVerseAccounts"
$MovieChunkSize = 1048576
$MaximumMovieSize = 1073741824
$MasterConnectionString = "Server=(localdb)\MSSQLLocalDB;Integrated Security=true;Initial Catalog=master;Connect Timeout=60"
$DatabaseConnectionString = "Server=(localdb)\MSSQLLocalDB;Integrated Security=true;Initial Catalog=$DatabaseName;Connect Timeout=60"
$SchemaPath = Join-Path $Root "database.sql"
$Encoding = New-Object System.Text.UTF8Encoding($false)
$Script:Sessions = @{}
$Script:LoginAttempts = @{}
Add-Type -AssemblyName System.Data

function Add-SqlParameters($Command, [hashtable]$Parameters) {
    foreach ($item in $Parameters.GetEnumerator()) {
        $parameter = $Command.Parameters.Add($item.Key, $item.Value.type)
        if ($item.Value.ContainsKey("size")) {
            $parameter.Size = $item.Value.size
        }
        if ($item.Value.ContainsKey("precision")) {
            $parameter.Precision = $item.Value.precision
        }
        if ($item.Value.ContainsKey("scale")) {
            $parameter.Scale = $item.Value.scale
        }
        if ($null -eq $item.Value.value) {
            $parameter.Value = [DBNull]::Value
        }
        elseif ($item.Value.type -eq [System.Data.SqlDbType]::VarBinary) {
            $parameter.Value = [byte[]]$item.Value.value
        }
        else {
            $parameter.Value = $item.Value.value
        }
    }
}

function Invoke-SqlScalar([string]$Query, [hashtable]$Parameters = @{}) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($DatabaseConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        Add-SqlParameters $command $Parameters
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlNonQuery([string]$Query, [hashtable]$Parameters = @{}) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($DatabaseConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        Add-SqlParameters $command $Parameters
        return $command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlQuery([string]$Query, [hashtable]$Parameters = @{}) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($DatabaseConnectionString)
    $rows = New-Object "System.Collections.Generic.List[object]"
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        Add-SqlParameters $command $Parameters
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                    $value = if ($reader.IsDBNull($index)) { $null } else { $reader.GetValue($index) }
                    $row[$reader.GetName($index)] = $value
                }
                $rows.Add([pscustomobject]$row)
            }
        }
        finally {
            $reader.Dispose()
        }
        return ,$rows.ToArray()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlMasterScalar([string]$Query) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($MasterConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        return $command.ExecuteScalar()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlMasterNonQuery([string]$Query) {
    $connection = New-Object System.Data.SqlClient.SqlConnection($MasterConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Initialize-SqlDatabase {
    $databaseExists = Invoke-SqlMasterScalar "SELECT DB_ID(N'$DatabaseName')"
    if ($null -eq $databaseExists -or $databaseExists -is [DBNull]) {
        Invoke-SqlMasterNonQuery "CREATE DATABASE [$DatabaseName]"
    }
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "SQL schema file not found: $SchemaPath"
    }
    $schema = [IO.File]::ReadAllText($SchemaPath)
    $connection = New-Object System.Data.SqlClient.SqlConnection($DatabaseConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $schema
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function ConvertTo-UtcIsoString([DateTime]$Value) {
    return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc).ToString("o")
}

function Get-AuthenticatedUser($Context) {
    $session = Get-Session $Context
    if ($null -eq $session -or $session.role -ne "user") {
        return $null
    }
    $users = Invoke-SqlQuery "SELECT UserId, Name, Email, Bio, Skills, CreatedAt FROM dbo.Users WHERE Email = @Email AND IsBanned = 0" @{
        "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $session.email }
    }
    return ($users | Select-Object -First 1)
}

function Get-SessionAccount($Context) {
    $session = Get-Session $Context
    if ($null -eq $session -or $session.role -ne "user") {
        return $null
    }
    $users = Invoke-SqlQuery "SELECT UserId, Name, Email, IsBanned, BanReason FROM dbo.Users WHERE Email = @Email" @{
        "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $session.email }
    }
    return ($users | Select-Object -First 1)
}

function Get-AuthenticatedAdmin($Context) {
    $session = Get-Session $Context
    if ($null -eq $session -or $session.role -ne "admin" -or $session.email -ne $OwnerEmail) {
        return $null
    }
    return $session
}

function Get-PasswordRecord([string]$Password) {
    $salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $algorithm = [Security.Cryptography.HashAlgorithmName]::SHA256
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, 310000, $algorithm)
    try {
        $hash = $derive.GetBytes(32)
        return @{
            salt = [Convert]::ToBase64String($salt)
            hash = [Convert]::ToBase64String($hash)
        }
    }
    finally {
        $derive.Dispose()
    }
}

function Test-Password([string]$Password, [string]$Salt, [string]$ExpectedHash) {
    $saltBytes = [Convert]::FromBase64String($Salt)
    $expectedBytes = [Convert]::FromBase64String($ExpectedHash)
    $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $Password,
        $saltBytes,
        310000,
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $actualBytes = $derive.GetBytes($expectedBytes.Length)
        $difference = 0
        for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
            $difference = $difference -bor ($actualBytes[$index] -bxor $expectedBytes[$index])
        }
        return $difference -eq 0
    }
    finally {
        $derive.Dispose()
    }
}

function Get-RequestBody($Context) {
    if ($Context.Request.ContentLength64 -gt 29500000) {
        throw [System.ArgumentException]::new("Request is too large.")
    }
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try {
        $content = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw [System.ArgumentException]::new("A JSON request body is required.")
        }
        try {
            return $content | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw [System.ArgumentException]::new("The request body must contain valid JSON.")
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Get-OptionalMedia($Data) {
    $encoded = [string]$Data.mediaBase64
    $contentType = ([string]$Data.mediaContentType).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($encoded) -and [string]::IsNullOrWhiteSpace($contentType) -and [string]::IsNullOrWhiteSpace([string]$Data.mediaFileName)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($encoded) -or [string]::IsNullOrWhiteSpace($contentType) -or [string]::IsNullOrWhiteSpace([string]$Data.mediaFileName)) {
        throw [System.ArgumentException]::new("Choose a valid image or video file.")
    }
    if ($contentType -notin @("image/jpeg", "image/png", "image/gif", "image/webp", "video/mp4", "video/webm")) {
        throw [System.ArgumentException]::new("Use a JPEG, PNG, GIF, or WebP image, or an MP4 or WebM video.")
    }
    try {
        $fileBytes = [Convert]::FromBase64String($encoded)
    }
    catch {
        throw [System.ArgumentException]::new("The selected media file could not be decoded.")
    }
    if ($fileBytes.Length -lt 4 -or $fileBytes.Length -gt 20971520) {
        throw [System.ArgumentException]::new("Media files must be no larger than 20 MB.")
    }
    $signatureIsValid = switch ($contentType) {
        "image/jpeg" { $fileBytes.Length -ge 3 -and [int]$fileBytes[0] -eq 255 -and [int]$fileBytes[1] -eq 216 -and [int]$fileBytes[2] -eq 255 }
        "image/png" { $fileBytes.Length -ge 8 -and [BitConverter]::ToString($fileBytes, 0, 8) -eq "89-50-4E-47-0D-0A-1A-0A" }
        "image/gif" { $fileBytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($fileBytes, 0, 6) -in @("GIF87a", "GIF89a") }
        "image/webp" { $fileBytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($fileBytes, 0, 4) -eq "RIFF" -and [Text.Encoding]::ASCII.GetString($fileBytes, 8, 4) -eq "WEBP" }
        "video/mp4" { $fileBytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($fileBytes, 4, 4) -eq "ftyp" }
        "video/webm" { $fileBytes.Length -ge 4 -and [BitConverter]::ToString($fileBytes, 0, 4) -eq "1A-45-DF-A3" }
        default { $false }
    }
    if (-not $signatureIsValid) {
        throw [System.ArgumentException]::new("The selected file does not match its image or video type.")
    }
    $fileName = [IO.Path]::GetFileName(([string]$Data.mediaFileName).Trim())
    $fileName = ($fileName -replace '[\x00-\x1f"<>|]', '').Trim()
    if ($fileName.Length -lt 1 -or $fileName.Length -gt 255) {
        throw [System.ArgumentException]::new("The media file name is invalid.")
    }
    return @{
        fileName = $fileName
        contentType = $contentType
        fileBytes = $fileBytes
    }
}

function Write-Json($Context, [int]$Status, $Data) {
    $body = ConvertTo-Json -InputObject $Data -Depth 8 -Compress
    $bytes = $Encoding.GetBytes($body)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.Headers.Add("Cache-Control", "no-store")
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-Binary($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = $ContentType
    $Context.Response.Headers.Add("Cache-Control", "no-store")
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Write-MovieStream($Context, [long]$MovieId, [long]$FileSize, [string]$ContentType) {
    $rangeHeader = $Context.Request.Headers["Range"]
    $start = [long]0
    $end = $FileSize - 1
    $status = 200
    if (-not [string]::IsNullOrWhiteSpace($rangeHeader)) {
        if ($rangeHeader -notmatch '^bytes=(\d+)-(\d*)$') {
            $Context.Response.StatusCode = 416
            $Context.Response.Headers.Add("Content-Range", "bytes */$FileSize")
            $Context.Response.ContentLength64 = 0
            return
        }
        $start = [long]$Matches[1]
        if (-not [string]::IsNullOrWhiteSpace($Matches[2])) { $end = [long]$Matches[2] }
        if ($start -ge $FileSize -or $end -lt $start) {
            $Context.Response.StatusCode = 416
            $Context.Response.Headers.Add("Content-Range", "bytes */$FileSize")
            $Context.Response.ContentLength64 = 0
            return
        }
        $end = [Math]::Min($end, $FileSize - 1)
        $status = 206
    }
    $startChunk = [int][Math]::Floor($start / $MovieChunkSize)
    $endChunk = [int][Math]::Floor($end / $MovieChunkSize)
    $connection = New-Object System.Data.SqlClient.SqlConnection($DatabaseConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT ChunkIndex, FileData FROM dbo.MovieChunks WHERE MovieId = @MovieId AND ChunkIndex BETWEEN @StartChunk AND @EndChunk ORDER BY ChunkIndex"
        Add-SqlParameters $command @{
            "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $MovieId }
            "@StartChunk" = @{ type = [System.Data.SqlDbType]::Int; value = $startChunk }
            "@EndChunk" = @{ type = [System.Data.SqlDbType]::Int; value = $endChunk }
        }
        $reader = $command.ExecuteReader()
        try {
            $Context.Response.StatusCode = $status
            $Context.Response.ContentType = $ContentType
            $Context.Response.Headers.Add("Accept-Ranges", "bytes")
            $Context.Response.Headers.Add("Cache-Control", "private, no-store")
            if ($status -eq 206) {
                $Context.Response.Headers.Add("Content-Range", "bytes $start-$end/$FileSize")
            }
            $Context.Response.ContentLength64 = $end - $start + 1
            while ($reader.Read()) {
                $chunkIndex = [int]$reader.GetValue(0)
                $chunk = [byte[]]$reader.GetValue(1)
                $chunkStart = [long]$chunkIndex * $MovieChunkSize
                $offset = [int][Math]::Max(0, $start - $chunkStart)
                $count = [int][Math]::Min($chunk.Length - $offset, $end - $chunkStart - $offset + 1)
                if ($count -gt 0) {
                    $Context.Response.OutputStream.Write($chunk, $offset, $count)
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $connection.Dispose()
    }
}

function Send-ApiError($Context, [int]$Status, [string]$Message) {
    Write-Json $Context $Status @{ error = $Message }
}

function Send-MethodNotAllowed($Context, [string]$Allowed) {
    $Context.Response.Headers.Add("Allow", $Allowed)
    Send-ApiError $Context 405 "This URL does not support $($Context.Request.HttpMethod). Use: $Allowed."
}

function Get-Session($Context) {
    $cookie = $Context.Request.Cookies["dv_session"]
    if ($null -eq $cookie) {
        return $null
    }
    $session = $Script:Sessions[$cookie.Value]
    if ($null -eq $session) {
        return $null
    }
    if ($session.expires -lt [DateTime]::UtcNow) {
        $Script:Sessions.Remove($cookie.Value)
        return $null
    }
    $session.lastSeen = [DateTime]::UtcNow
    return $session
}

function New-Session($Context, [string]$Role, [string]$Email) {
    $tokenBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
    $token = [BitConverter]::ToString($tokenBytes).Replace("-", "").ToLowerInvariant()
    $Script:Sessions[$token] = @{
        role = $Role
        email = $Email
        expires = [DateTime]::UtcNow.AddHours(8)
        lastSeen = [DateTime]::UtcNow
    }
    $Context.Response.Headers.Add("Set-Cookie", "dv_session=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800")
}

function Test-RateLimit([string]$Key) {
    $entry = $Script:LoginAttempts[$Key]
    if ($null -eq $entry) {
        return $true
    }
    if ($entry.reset -lt [DateTime]::UtcNow) {
        $Script:LoginAttempts.Remove($Key)
        return $true
    }
    return $entry.count -lt 8
}

function Add-FailedAttempt([string]$Key) {
    $entry = $Script:LoginAttempts[$Key]
    if ($null -eq $entry -or $entry.reset -lt [DateTime]::UtcNow) {
        $entry = @{ count = 0; reset = [DateTime]::UtcNow.AddMinutes(15) }
    }
    $entry.count++
    $Script:LoginAttempts[$Key] = $entry
}

function Test-Email([string]$Email) {
    if ([string]::IsNullOrWhiteSpace($Email) -or $Email.Length -gt 254) {
        return $false
    }
    try {
        $parsed = New-Object System.Net.Mail.MailAddress($Email)
        return $parsed.Address -eq $Email
    }
    catch {
        return $false
    }
}

function Get-OnlineUserEmails {
    $cutoff = [DateTime]::UtcNow.AddMinutes(-10)
    $onlineEmails = @{}
    $bannedUsers = Invoke-SqlQuery "SELECT Email FROM dbo.Users WHERE IsBanned = 1"
    $bannedEmails = @{}
    foreach ($bannedUser in $bannedUsers) { $bannedEmails[$bannedUser.Email] = $true }
    foreach ($session in $Script:Sessions.Values) {
        if ($session.role -eq "user" -and $session.expires -gt [DateTime]::UtcNow -and $session.lastSeen -gt $cutoff -and -not $bannedEmails.ContainsKey($session.email)) {
            $onlineEmails[$session.email] = $true
        }
    }
    return $onlineEmails
}

function Get-AdminAccounts([string]$Search = "") {
    $users = Invoke-SqlQuery @'
SELECT UserId, Name, Email, CreatedAt, IsBanned, BanReason
FROM dbo.Users
WHERE @Search = N'' OR Name LIKE @Pattern OR Email LIKE @Pattern
ORDER BY CreatedAt DESC
'@ @{
        "@Search" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $Search }
        "@Pattern" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 102; value = "%$Search%" }
    }
    $onlineEmails = Get-OnlineUserEmails
    $accounts = @(
        foreach ($user in $users) {
            [ordered]@{
                id = $user.UserId
                name = $user.name
                email = $user.email
                createdAt = ConvertTo-UtcIsoString $user.CreatedAt
                isBanned = $user.IsBanned
                banReason = $user.BanReason
                isOnline = $onlineEmails.ContainsKey($user.email)
            }
        }
    )
    return @{ accounts = $accounts }
}

function Write-StaticFile($Context, [string]$Path) {
    $allowedFiles = @("index.html", "home.html", "community.html", "games.html", "movies.html", "appeal.html", "admin.html", "style.css", "script.js", "home.js", "community.js", "games.js", "movies.js", "appeal.js", "auth-service.js", "admin.js", "bg.jpg", "img.png")
    $name = $Path.TrimStart("/")
    if ($name -eq "") {
        $name = "index.html"
    }
    if ($name -notin $allowedFiles) {
        Send-ApiError $Context 404 "Page not found."
        return
    }
    $filePath = Join-Path $Root $name
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Send-ApiError $Context 404 "Page not found."
        return
    }
    $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
    $mimeType = switch ($extension) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "text/javascript; charset=utf-8" }
        ".jpg" { "image/jpeg" }
        ".png" { "image/png" }
        default { "application/octet-stream" }
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $mimeType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

Initialize-SqlDatabase

$adminCount = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.AdminAccount")
if ($adminCount -eq 0) {
    $passwordRecord = Get-PasswordRecord $DefaultAdminPassword
    [void](Invoke-SqlNonQuery @'
INSERT INTO dbo.AdminAccount (AccountId, Email, PasswordSalt, PasswordHash)
VALUES (1, @Email, @PasswordSalt, @PasswordHash)
'@ @{
        "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $OwnerEmail }
        "@PasswordSalt" = @{ type = [System.Data.SqlDbType]::VarBinary; size = 16; value = [Convert]::FromBase64String($passwordRecord.salt) }
        "@PasswordHash" = @{ type = [System.Data.SqlDbType]::VarBinary; size = 32; value = [Convert]::FromBase64String($passwordRecord.hash) }
    })
    $adminCount = 1
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
}
catch {
    Write-Error "Could not start local server on port $Port. Close any other app using that port, then try again."
    exit 1
}

Write-Host ""
Write-Host "DI-VERSE local admin platform is running."
Write-Host "Open http://127.0.0.1:$Port/ in your browser."
Write-Host "This server and its SQL database are private to your Windows user on this computer."
Start-Process "http://127.0.0.1:$Port/"
Write-Host "Keep this window open while using the app. Press Ctrl+C to stop."
Write-Host ""

while ($listener.IsListening) {
    $context = $null
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("X-Content-Type-Options", "nosniff")
        $response.Headers.Add("X-Frame-Options", "DENY")
        $response.Headers.Add("Referrer-Policy", "no-referrer")

        $path = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
        $method = $request.HttpMethod
        if (-not $path.StartsWith("/api/") -and $method -notin @("GET", "HEAD")) {
            Send-MethodNotAllowed $context "GET, HEAD"
            continue
        }

        $apiMethods = @{
            "/api/admin/status" = "GET"
            "/api/auth/me" = "GET"
            "/api/profile/me" = "GET"
            "/api/profile/picture" = "GET, POST, DELETE"
            "/api/profile/update" = "POST"
            "/api/register" = "POST"
            "/api/login" = "POST"
            "/api/logout" = "POST"
            "/api/admin/login" = "POST"
            "/api/admin/accounts" = "GET"
            "/api/admin/users/ban" = "POST"
            "/api/admin/users/unban" = "POST"
            "/api/admin/reports" = "GET"
            "/api/admin/reports/resolve" = "POST"
            "/api/admin/appeals" = "GET"
            "/api/admin/appeals/review" = "POST"
            "/api/admin/logout" = "POST"
            "/api/friends" = "GET"
            "/api/friends/locations" = "GET"
            "/api/location" = "POST, DELETE"
            "/api/friends/search" = "GET"
            "/api/friends/requests" = "GET"
            "/api/friends/request" = "POST"
            "/api/friends/respond" = "POST"
            "/api/chat/messages" = "GET"
            "/api/chat/unread" = "GET"
            "/api/chat/send" = "POST"
            "/api/posts" = "GET, POST"
            "/api/posts/like" = "POST"
            "/api/posts/comments" = "GET, POST"
            "/api/documents" = "GET, POST"
            "/api/marketplace" = "GET, POST"
            "/api/games/rooms" = "GET"
            "/api/games/create" = "POST"
            "/api/games/join" = "POST"
            "/api/games/room" = "GET"
            "/api/games/state" = "POST"
            "/api/reports" = "POST"
            "/api/appeals/me" = "GET"
            "/api/appeals" = "POST"
            "/api/movies" = "GET"
            "/api/movies/upload/start" = "POST"
            "/api/movies/upload/chunk" = "POST"
            "/api/movies/upload/complete" = "POST"
        }
        $allowedMethods = @()
        if ($apiMethods.ContainsKey($path)) {
            $allowedMethods = @($apiMethods[$path].Split(",") | ForEach-Object { $_.Trim() })
        }
        if ($apiMethods.ContainsKey($path) -and $allowedMethods -notcontains $method) {
            Send-MethodNotAllowed $context $apiMethods[$path]
            continue
        }

        if ($path.StartsWith("/api/") -and $method -ne "GET") {
            $origin = $request.Headers["Origin"]
            if ($null -ne $origin -and $origin -ne "http://127.0.0.1:$Port") {
                Send-ApiError $context 403 "Request origin is not allowed."
                continue
            }
        }

        if (-not $path.StartsWith("/api/")) {
            Write-StaticFile $context $path
            continue
        }

        if ($path -eq "/api/admin/status" -and $method -eq "GET") {
            $session = Get-Session $context
            $isAdmin = $null -ne $session -and $session.role -eq "admin"
            Write-Json $context 200 @{
                ownerEmail = $OwnerEmail
                configured = ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.AdminAccount")) -gt 0
                authenticated = $isAdmin
                onlineUsers = (Get-OnlineUserEmails).Count
            }
            continue
        }

        if ($path -eq "/api/auth/me" -and $method -eq "GET") {
            $session = Get-Session $context
            if ($null -eq $session -or $session.role -ne "user") {
                Send-ApiError $context 401 "Please sign in to access your homepage."
                continue
            }
            $users = Invoke-SqlQuery @'
SELECT u.UserId, u.Name, u.Email, u.CreatedAt, u.IsBanned, u.BanReason,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ProfilePictures p WHERE p.UserId = u.UserId)
            THEN CONCAT(N'/api/profile/picture?userId=', CONVERT(nvarchar(36), u.UserId)) END AS pictureUrl
FROM dbo.Users u
WHERE u.Email = @Email
'@ @{
                "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $session.email }
            }
            $user = $users | Select-Object -First 1
            if ($null -eq $user) {
                Send-ApiError $context 401 "This account is no longer available. Please sign in again."
                continue
            }
            if ($user.IsBanned) {
                Send-ApiError $context 403 "This account is banned. Submit an appeal to request a review."
                continue
            }
            Write-Json $context 200 @{
                user = @{
                    id = $user.UserId
                    name = $user.name
                    email = $user.email
                    pictureUrl = $user.pictureUrl
                    isBanned = $user.IsBanned
                    banReason = $user.BanReason
                    createdAt = ConvertTo-UtcIsoString $user.CreatedAt
                }
            }
            continue
        }

        if ($path -eq "/api/profile/me" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view your profile."
                continue
            }
            Write-Json $context 200 @{
                profile = @{
                    name = $user.Name
                    email = $user.Email
                    bio = $user.Bio
                    skills = $user.Skills
                    pictureUrl = if ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.ProfilePictures WHERE UserId = @UserId" @{
                        "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                    }) -gt 0) { "/api/profile/picture" } else { $null }
                    createdAt = ConvertTo-UtcIsoString $user.CreatedAt
                }
            }
            continue
        }

        if ($path -eq "/api/profile/picture" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view profile pictures."
                continue
            }
            $targetId = $user.UserId
            if (-not [string]::IsNullOrWhiteSpace($request.QueryString["userId"]) -and -not [Guid]::TryParse($request.QueryString["userId"], [ref]$targetId)) {
                Send-ApiError $context 400 "The profile picture request is invalid."
                continue
            }
            $pictures = Invoke-SqlQuery "SELECT FileName, ContentType, FileData FROM dbo.ProfilePictures WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            }
            $picture = $pictures | Select-Object -First 1
            if ($null -eq $picture) {
                Send-ApiError $context 404 "Profile picture not found."
                continue
            }
            $response.Headers.Add("Content-Disposition", "inline; filename*=UTF-8''$([Uri]::EscapeDataString($picture.FileName))")
            Write-Binary $context 200 $picture.ContentType $picture.FileData
            continue
        }

        if ($path -eq "/api/profile/picture" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to upload a profile picture."
                continue
            }
            $data = Get-RequestBody $context
            $media = Get-OptionalMedia $data
            if ($null -eq $media -or $media.contentType -notin @("image/jpeg", "image/png", "image/gif", "image/webp") -or $media.fileBytes.Length -gt 5242880) {
                Send-ApiError $context 400 "Choose a JPEG, PNG, GIF, or WebP image up to 5 MB."
                continue
            }
            [void](Invoke-SqlNonQuery @'
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.ProfilePictures WITH (UPDLOCK, HOLDLOCK) WHERE UserId = @UserId)
    UPDATE dbo.ProfilePictures SET FileName = @FileName, ContentType = @ContentType, FileData = @FileData, UpdatedAt = SYSUTCDATETIME() WHERE UserId = @UserId;
ELSE
    INSERT INTO dbo.ProfilePictures (UserId, FileName, ContentType, FileData) VALUES (@UserId, @FileName, @ContentType, @FileData);
COMMIT TRANSACTION;
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FileName" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 255; value = $media.fileName }
                "@ContentType" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $media.contentType }
                "@FileData" = @{ type = [System.Data.SqlDbType]::VarBinary; size = -1; value = $media.fileBytes }
            })
            Write-Json $context 200 @{ saved = $true; pictureUrl = "/api/profile/picture?v=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" }
            continue
        }

        if ($path -eq "/api/profile/picture" -and $method -eq "DELETE") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to remove your profile picture."
                continue
            }
            [void](Invoke-SqlNonQuery "DELETE FROM dbo.ProfilePictures WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            Write-Json $context 200 @{ removed = $true }
            continue
        }

        if ($path -eq "/api/profile/update" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to update your profile."
                continue
            }
            $data = Get-RequestBody $context
            $name = ([string]$data.name).Trim()
            $bio = ([string]$data.bio).Trim()
            $skills = ([string]$data.skills).Trim()
            if ($name.Length -lt 1 -or $name.Length -gt 100 -or $bio.Length -gt 500 -or $skills.Length -gt 250) {
                Send-ApiError $context 400 "Enter a name of up to 100 characters, a bio up to 500 characters, and skills up to 250 characters."
                continue
            }
            [void](Invoke-SqlNonQuery "UPDATE dbo.Users SET Name = @Name, Bio = @Bio, Skills = @Skills WHERE UserId = @UserId" @{
                "@Name" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $name }
                "@Bio" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 500; value = $bio }
                "@Skills" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 250; value = $skills }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            Write-Json $context 200 @{ saved = $true }
            continue
        }

        if ($path -eq "/api/friends" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view friends."
                continue
            }
            $friends = Invoke-SqlQuery @'
SELECT u.UserId AS id, u.Name AS name, u.Email AS email,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ProfilePictures p WHERE p.UserId = u.UserId)
            THEN CONCAT(N'/api/profile/picture?userId=', CONVERT(nvarchar(36), u.UserId)) END AS pictureUrl
FROM dbo.Friendships f
JOIN dbo.Users u ON u.UserId = CASE WHEN f.RequesterId = @UserId THEN f.AddresseeId ELSE f.RequesterId END
WHERE f.Status = N'accepted' AND (f.RequesterId = @UserId OR f.AddresseeId = @UserId)
ORDER BY u.Name
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            Write-Json $context 200 @{ friends = @($friends) }
            continue
        }

        if ($path -eq "/api/friends/locations" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view friend locations."
                continue
            }
            $locations = Invoke-SqlQuery @'
SELECT u.UserId AS id, u.Name AS name, l.Latitude AS latitude, l.Longitude AS longitude,
       l.AccuracyMeters AS accuracyMeters, l.UpdatedAt AS updatedAt
FROM dbo.Friendships f
JOIN dbo.Users u ON u.UserId = CASE WHEN f.RequesterId = @UserId THEN f.AddresseeId ELSE f.RequesterId END
JOIN dbo.UserLocations l ON l.UserId = u.UserId
WHERE f.Status = N'accepted'
  AND (f.RequesterId = @UserId OR f.AddresseeId = @UserId)
  AND u.IsBanned = 0
  AND l.UpdatedAt >= DATEADD(MINUTE, -10, SYSUTCDATETIME())
ORDER BY u.Name
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            Write-Json $context 200 @{ locations = @($locations | ForEach-Object {
                @{
                    id = $_.id
                    name = $_.name
                    latitude = [double]$_.latitude
                    longitude = [double]$_.longitude
                    accuracyMeters = $_.accuracyMeters
                    updatedAt = ConvertTo-UtcIsoString $_.updatedAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/location" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to share your location."
                continue
            }
            $data = Get-RequestBody $context
            $latitude = [double]0
            $longitude = [double]0
            $accuracy = [int]0
            if (-not [double]::TryParse([string]$data.latitude, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$latitude) -or
                -not [double]::TryParse([string]$data.longitude, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$longitude) -or
                -not [int]::TryParse([string]$data.accuracyMeters, [ref]$accuracy) -or
                $latitude -lt -90 -or $latitude -gt 90 -or $longitude -lt -180 -or $longitude -gt 180 -or $accuracy -lt 0 -or $accuracy -gt 100000) {
                Send-ApiError $context 400 "Location coordinates are invalid."
                continue
            }
            [void](Invoke-SqlNonQuery @'
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.UserLocations WITH (UPDLOCK, HOLDLOCK) WHERE UserId = @UserId)
    UPDATE dbo.UserLocations SET Latitude = @Latitude, Longitude = @Longitude, AccuracyMeters = @Accuracy, UpdatedAt = SYSUTCDATETIME() WHERE UserId = @UserId;
ELSE
    INSERT INTO dbo.UserLocations (UserId, Latitude, Longitude, AccuracyMeters) VALUES (@UserId, @Latitude, @Longitude, @Accuracy);
COMMIT TRANSACTION;
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Latitude" = @{ type = [System.Data.SqlDbType]::Decimal; precision = 9; scale = 6; value = [decimal]$latitude }
                "@Longitude" = @{ type = [System.Data.SqlDbType]::Decimal; precision = 9; scale = 6; value = [decimal]$longitude }
                "@Accuracy" = @{ type = [System.Data.SqlDbType]::Int; value = $accuracy }
            })
            Write-Json $context 200 @{ shared = $true }
            continue
        }

        if ($path -eq "/api/location" -and $method -eq "DELETE") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to stop sharing your location."
                continue
            }
            [void](Invoke-SqlNonQuery "DELETE FROM dbo.UserLocations WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            Write-Json $context 200 @{ sharing = $false }
            continue
        }

        if ($path -eq "/api/friends/search" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to find people."
                continue
            }
            $term = ([string]$request.QueryString["q"]).Trim()
            if ($term.Length -gt 100) {
                Send-ApiError $context 400 "Search text must be 100 characters or fewer."
                continue
            }
            $people = Invoke-SqlQuery @'
SELECT TOP (30) u.UserId AS id, u.Name AS name, u.Email AS email,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ProfilePictures p WHERE p.UserId = u.UserId)
            THEN CONCAT(N'/api/profile/picture?userId=', CONVERT(nvarchar(36), u.UserId)) END AS pictureUrl
FROM dbo.Users u
WHERE u.UserId <> @UserId
  AND (@Search = N'' OR u.Name LIKE @Pattern OR u.Email LIKE @Pattern)
  AND NOT EXISTS
      (SELECT 1 FROM dbo.Friendships f
       WHERE (f.RequesterId = @UserId AND f.AddresseeId = u.UserId)
          OR (f.RequesterId = u.UserId AND f.AddresseeId = @UserId))
ORDER BY u.Name
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Search" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $term }
                "@Pattern" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 102; value = "%$term%" }
            }
            Write-Json $context 200 @{ people = @($people) }
            continue
        }

        if ($path -eq "/api/friends/requests" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view friend requests."
                continue
            }
            $requests = Invoke-SqlQuery @'
SELECT f.FriendshipId AS id, u.UserId AS userId, u.Name AS name, u.Email AS email,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ProfilePictures p WHERE p.UserId = u.UserId)
            THEN CONCAT(N'/api/profile/picture?userId=', CONVERT(nvarchar(36), u.UserId)) END AS pictureUrl
FROM dbo.Friendships f
JOIN dbo.Users u ON u.UserId = f.RequesterId
WHERE f.AddresseeId = @UserId AND f.Status = N'pending'
ORDER BY f.CreatedAt DESC
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            Write-Json $context 200 @{ requests = @($requests) }
            continue
        }

        if ($path -eq "/api/friends/request" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to send a friend request."
                continue
            }
            $data = Get-RequestBody $context
            $targetEmail = ([string]$data.email).Trim().ToLowerInvariant()
            $targets = Invoke-SqlQuery "SELECT UserId FROM dbo.Users WHERE Email = @Email" @{
                "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $targetEmail }
            }
            $target = $targets | Select-Object -First 1
            if ($null -eq $target) {
                Send-ApiError $context 404 "No account was found for that email."
                continue
            }
            if ($target.UserId -eq $user.UserId) {
                Send-ApiError $context 400 "You cannot send a friend request to yourself."
                continue
            }
            $existing = [int](Invoke-SqlScalar @'
SELECT COUNT(*) FROM dbo.Friendships
WHERE (RequesterId = @UserId AND AddresseeId = @TargetId)
   OR (RequesterId = @TargetId AND AddresseeId = @UserId)
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@TargetId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $target.UserId }
            })
            if ($existing -gt 0) {
                Send-ApiError $context 409 "A friend request or friendship already exists."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.Friendships (RequesterId, AddresseeId) VALUES (@UserId, @TargetId)" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@TargetId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $target.UserId }
            })
            Write-Json $context 201 @{ sent = $true }
            continue
        }

        if ($path -eq "/api/friends/respond" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to respond to friend requests."
                continue
            }
            $data = Get-RequestBody $context
            $requestId = [long]0
            if (-not [long]::TryParse([string]$data.requestId, [ref]$requestId)) {
                Send-ApiError $context 400 "Friend request ID is invalid."
                continue
            }
            if ($data.accept -eq $true) {
                $changed = Invoke-SqlNonQuery "UPDATE dbo.Friendships SET Status = N'accepted' WHERE FriendshipId = @RequestId AND AddresseeId = @UserId AND Status = N'pending'" @{
                    "@RequestId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $requestId }
                    "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                }
            }
            else {
                $changed = Invoke-SqlNonQuery "DELETE FROM dbo.Friendships WHERE FriendshipId = @RequestId AND AddresseeId = @UserId AND Status = N'pending'" @{
                    "@RequestId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $requestId }
                    "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                }
            }
            if ($changed -eq 0) {
                Send-ApiError $context 404 "That friend request is no longer available."
                continue
            }
            Write-Json $context 200 @{ updated = $true }
            continue
        }

        if ($path -eq "/api/chat/messages" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view messages."
                continue
            }
            $friendId = [Guid]::Empty
            if (-not [Guid]::TryParse($request.QueryString["friendId"], [ref]$friendId)) {
                Send-ApiError $context 400 "Choose a friend to open a conversation."
                continue
            }
            $isFriend = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Friendships WHERE Status = N'accepted' AND ((RequesterId = @UserId AND AddresseeId = @FriendId) OR (RequesterId = @FriendId AND AddresseeId = @UserId))" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FriendId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $friendId }
            })
            if ($isFriend -eq 0) {
                Send-ApiError $context 403 "You can only message an accepted friend."
                continue
            }
            [void](Invoke-SqlNonQuery "UPDATE dbo.Messages SET IsRead = 1 WHERE RecipientId = @UserId AND SenderId = @FriendId AND IsRead = 0" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FriendId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $friendId }
            })
            $messages = Invoke-SqlQuery @'
SELECT TOP (100) m.MessageId AS id, m.SenderId AS senderId, sender.Name AS senderName,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.ProfilePictures p WHERE p.UserId = sender.UserId)
            THEN CONCAT(N'/api/profile/picture?userId=', CONVERT(nvarchar(36), sender.UserId)) END AS senderPictureUrl,
       m.RecipientId AS recipientId, m.Content AS content, m.CreatedAt AS createdAt
FROM dbo.Messages m
JOIN dbo.Users sender ON sender.UserId = m.SenderId
WHERE (m.SenderId = @UserId AND m.RecipientId = @FriendId)
   OR (m.SenderId = @FriendId AND m.RecipientId = @UserId)
ORDER BY m.MessageId DESC
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FriendId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $friendId }
            }
            $orderedMessages = @($messages | Sort-Object id)
            Write-Json $context 200 @{ messages = @($orderedMessages | ForEach-Object {
                @{
                    id = $_.id
                    senderId = $_.senderId
                    senderName = $_.senderName
                    senderPictureUrl = $_.senderPictureUrl
                    recipientId = $_.recipientId
                    content = $_.content
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/chat/unread" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to check messages."
                continue
            }
            $unreadCount = [long](Invoke-SqlScalar "SELECT COUNT_BIG(*) FROM dbo.Messages WHERE RecipientId = @UserId AND IsRead = 0" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            $latestUnread = Invoke-SqlQuery @'
SELECT TOP (1) m.MessageId AS id, m.Content AS content, sender.Name AS senderName, m.CreatedAt AS createdAt
FROM dbo.Messages m
JOIN dbo.Users sender ON sender.UserId = m.SenderId
WHERE m.RecipientId = @UserId AND m.IsRead = 0
ORDER BY m.MessageId DESC
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            $latest = $latestUnread | Select-Object -First 1
            Write-Json $context 200 @{
                count = $unreadCount
                latest = if ($null -eq $latest) { $null } else {
                    @{
                        id = $latest.id
                        content = $latest.content
                        senderName = $latest.senderName
                        createdAt = ConvertTo-UtcIsoString $latest.createdAt
                    }
                }
            }
            continue
        }

        if ($path -eq "/api/reports" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to report an account."
                continue
            }
            $data = Get-RequestBody $context
            $reportedUserId = [Guid]::Empty
            $category = ([string]$data.category).Trim().ToLowerInvariant()
            $details = ([string]$data.details).Trim()
            if (-not [Guid]::TryParse([string]$data.userId, [ref]$reportedUserId) -or $reportedUserId -eq $user.UserId -or $category -notin @("scam", "fraud", "impersonation", "harassment", "other") -or $details.Length -lt 20 -or $details.Length -gt 1200) {
                Send-ApiError $context 400 "Select a reason and provide details between 20 and 1,200 characters."
                continue
            }
            $targetExists = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Users WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $reportedUserId }
            })
            if ($targetExists -eq 0) {
                Send-ApiError $context 404 "The reported account was not found."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.UserReports (ReporterId, ReportedUserId, Category, Details) VALUES (@ReporterId, @ReportedUserId, @Category, @Details)" @{
                "@ReporterId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@ReportedUserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $reportedUserId }
                "@Category" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 24; value = $category }
                "@Details" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 1200; value = $details }
            })
            Write-Json $context 201 @{ reported = $true }
            continue
        }

        if ($path -eq "/api/appeals/me" -and $method -eq "GET") {
            $user = Get-SessionAccount $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view your appeal status."
                continue
            }
            $appeals = Invoke-SqlQuery "SELECT TOP (1) AppealId AS id, Reason AS reason, Status AS status, CreatedAt AS createdAt FROM dbo.UnbanAppeals WHERE UserId = @UserId ORDER BY CreatedAt DESC" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            $appeal = $appeals | Select-Object -First 1
            Write-Json $context 200 @{
                isBanned = $user.IsBanned
                banReason = $user.BanReason
                appeal = if ($null -eq $appeal) { $null } else {
                    @{
                        id = $appeal.id
                        reason = $appeal.reason
                        status = $appeal.status
                        createdAt = ConvertTo-UtcIsoString $appeal.createdAt
                    }
                }
            }
            continue
        }

        if ($path -eq "/api/appeals" -and $method -eq "POST") {
            $user = Get-SessionAccount $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Sign in to submit an appeal."
                continue
            }
            if (-not $user.IsBanned) {
                Send-ApiError $context 403 "Only banned accounts can submit an unban appeal."
                continue
            }
            $data = Get-RequestBody $context
            $reason = ([string]$data.reason).Trim()
            if ($reason.Length -lt 20 -or $reason.Length -gt 2000) {
                Send-ApiError $context 400 "Explain your appeal in 20 to 2,000 characters."
                continue
            }
            $pending = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.UnbanAppeals WHERE UserId = @UserId AND Status = N'pending'" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            if ($pending -gt 0) {
                Send-ApiError $context 409 "You already have an appeal awaiting review."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.UnbanAppeals (UserId, Reason) VALUES (@UserId, @Reason)" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Reason" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 2000; value = $reason }
            })
            Write-Json $context 201 @{ submitted = $true }
            continue
        }

        if ($path -eq "/api/chat/send" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to send a message."
                continue
            }
            $data = Get-RequestBody $context
            $friendId = [Guid]::Empty
            $content = ([string]$data.content).Trim()
            if (-not [Guid]::TryParse([string]$data.friendId, [ref]$friendId) -or $content.Length -lt 1 -or $content.Length -gt 2000) {
                Send-ApiError $context 400 "Choose a friend and enter a message of up to 2,000 characters."
                continue
            }
            $isFriend = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Friendships WHERE Status = N'accepted' AND ((RequesterId = @UserId AND AddresseeId = @FriendId) OR (RequesterId = @FriendId AND AddresseeId = @UserId))" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FriendId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $friendId }
            })
            if ($isFriend -eq 0) {
                Send-ApiError $context 403 "You can only message an accepted friend."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.Messages (SenderId, RecipientId, Content) VALUES (@UserId, @FriendId, @Content)" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FriendId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $friendId }
                "@Content" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 2000; value = $content }
            })
            Write-Json $context 201 @{ sent = $true }
            continue
        }

        if ($path -eq "/api/posts" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view posts."
                continue
            }
            $posts = Invoke-SqlQuery @'
SELECT TOP (100) p.PostId AS id, p.Content AS content, p.CreatedAt AS createdAt,
       u.Name AS author, u.Email AS authorEmail,
       pm.ContentType AS mediaContentType,
       (SELECT COUNT_BIG(*) FROM dbo.PostLikes l WHERE l.PostId = p.PostId) AS likeCount,
       CAST(CASE WHEN EXISTS (
           SELECT 1 FROM dbo.PostLikes l WHERE l.PostId = p.PostId AND l.UserId = @UserId
       ) THEN 1 ELSE 0 END AS bit) AS likedByMe,
       (SELECT COUNT_BIG(*) FROM dbo.PostComments c WHERE c.PostId = p.PostId) AS commentCount
FROM dbo.Posts p
JOIN dbo.Users u ON u.UserId = p.UserId
LEFT JOIN dbo.PostMedia pm ON pm.PostId = p.PostId
ORDER BY p.CreatedAt DESC
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            Write-Json $context 200 @{ posts = @($posts | ForEach-Object {
                @{
                    id = $_.id
                    content = $_.content
                    author = $_.author
                    authorEmail = $_.authorEmail
                    mediaContentType = $_.mediaContentType
                    mediaUrl = if ($null -eq $_.mediaContentType) { $null } else { "/api/posts/$($_.id)/media" }
                    likeCount = $_.likeCount
                    likedByMe = $_.likedByMe
                    commentCount = $_.commentCount
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/posts/like" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to like posts."
                continue
            }
            $data = Get-RequestBody $context
            $postId = [long]0
            if (-not [long]::TryParse([string]$data.postId, [ref]$postId) -or $postId -lt 1) {
                Send-ApiError $context 400 "Choose a valid post."
                continue
            }
            if ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Posts WHERE PostId = @PostId" @{
                    "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
                }) -eq 0) {
                Send-ApiError $context 404 "Post not found."
                continue
            }
            $likeQuery = @'
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.PostLikes WITH (UPDLOCK, HOLDLOCK) WHERE PostId = @PostId AND UserId = @UserId)
    DELETE FROM dbo.PostLikes WHERE PostId = @PostId AND UserId = @UserId;
ELSE
    INSERT INTO dbo.PostLikes (PostId, UserId) VALUES (@PostId, @UserId);
COMMIT TRANSACTION;
SELECT CAST(CASE WHEN EXISTS (
    SELECT 1 FROM dbo.PostLikes WHERE PostId = @PostId AND UserId = @UserId
) THEN 1 ELSE 0 END AS bit) AS liked,
(SELECT COUNT_BIG(*) FROM dbo.PostLikes WHERE PostId = @PostId) AS likeCount;
'@
            $state = Invoke-SqlQuery $likeQuery @{
                "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            Write-Json $context 200 @{ liked = $state[0].liked; likeCount = $state[0].likeCount }
            continue
        }

        if ($path -eq "/api/posts/comments" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to view post comments."
                continue
            }
            $postId = [long]0
            if (-not [long]::TryParse($request.QueryString["postId"], [ref]$postId) -or $postId -lt 1) {
                Send-ApiError $context 400 "Choose a valid post."
                continue
            }
            if ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Posts WHERE PostId = @PostId" @{
                    "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
                }) -eq 0) {
                Send-ApiError $context 404 "Post not found."
                continue
            }
            $comments = Invoke-SqlQuery @'
SELECT recent.id, recent.content, recent.author, recent.createdAt
FROM (
    SELECT TOP (100) c.CommentId AS id, c.Content AS content, u.Name AS author, c.CreatedAt AS createdAt
    FROM dbo.PostComments c
    JOIN dbo.Users u ON u.UserId = c.UserId
    WHERE c.PostId = @PostId
    ORDER BY c.CreatedAt DESC, c.CommentId DESC
) recent
ORDER BY recent.createdAt, recent.id
'@ @{
                "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
            }
            Write-Json $context 200 @{ comments = @($comments | ForEach-Object {
                @{
                    id = $_.id
                    content = $_.content
                    author = $_.author
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/posts/comments" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to comment on posts."
                continue
            }
            $data = Get-RequestBody $context
            $postId = [long]0
            $content = ([string]$data.content).Trim()
            if (-not [long]::TryParse([string]$data.postId, [ref]$postId) -or $postId -lt 1) {
                Send-ApiError $context 400 "Choose a valid post."
                continue
            }
            if ($content.Length -lt 1 -or $content.Length -gt 1000) {
                Send-ApiError $context 400 "Comments must contain between 1 and 1,000 characters."
                continue
            }
            if ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Posts WHERE PostId = @PostId" @{
                    "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
                }) -eq 0) {
                Send-ApiError $context 404 "Post not found."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.PostComments (PostId, UserId, Content) VALUES (@PostId, @UserId, @Content)" @{
                "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Content" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 1000; value = $content }
            })
            Write-Json $context 201 @{ commented = $true }
            continue
        }

        if ($path -eq "/api/posts" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to publish a post."
                continue
            }
            $data = Get-RequestBody $context
            $content = ([string]$data.content).Trim()
            $media = Get-OptionalMedia $data
            if ($content.Length -lt 1 -or $content.Length -gt 2000) {
                Send-ApiError $context 400 "Posts must contain between 1 and 2,000 characters."
                continue
            }
            $postInsert = @'
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT INTO dbo.Posts (UserId, Content) VALUES (@UserId, @Content);
    DECLARE @PostId bigint = CAST(SCOPE_IDENTITY() AS bigint);
    IF @MediaData IS NOT NULL
        INSERT INTO dbo.PostMedia (PostId, FileName, ContentType, FileData) VALUES (@PostId, @MediaFileName, @MediaContentType, @MediaData);
    COMMIT TRANSACTION;
    SELECT @PostId;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
            [void](Invoke-SqlScalar $postInsert @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Content" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 2000; value = $content }
                "@MediaFileName" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 255; value = if ($null -eq $media) { $null } else { $media.fileName } }
                "@MediaContentType" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = if ($null -eq $media) { $null } else { $media.contentType } }
                "@MediaData" = @{ type = [System.Data.SqlDbType]::VarBinary; size = -1; value = if ($null -eq $media) { $null } else { $media.fileBytes } }
            })
            Write-Json $context 201 @{ posted = $true }
            continue
        }

        if ($path -match '^/api/documents/[0-9]+/download$' -and $method -ne "GET") {
            Send-MethodNotAllowed $context "GET"
            continue
        }

        if ($path -match '^/api/movies/[0-9]+/stream$' -and $method -ne "GET") {
            Send-MethodNotAllowed $context "GET"
            continue
        }

        if ($path -match '^/api/movies/[0-9]+/stream$' -and $method -ne "GET") {
            Send-MethodNotAllowed $context "GET"
            continue
        }

        if ($path -match '^/api/(posts|marketplace)/[0-9]+/media$' -and $method -ne "GET") {
            Send-MethodNotAllowed $context "GET"
            continue
        }

        if ($path -match '^/api/posts/([0-9]+)/media$' -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to view post media."
                continue
            }
            $postId = [long]$Matches[1]
            $mediaRows = Invoke-SqlQuery "SELECT FileName, ContentType, FileData FROM dbo.PostMedia WHERE PostId = @PostId" @{
                "@PostId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $postId }
            }
            $media = $mediaRows | Select-Object -First 1
            if ($null -eq $media) {
                Send-ApiError $context 404 "Post media not found."
                continue
            }
            $safeFileName = [Uri]::EscapeDataString($media.FileName)
            $response.Headers.Add("Content-Disposition", "inline; filename*=UTF-8''$safeFileName")
            Write-Binary $context 200 $media.ContentType $media.FileData
            continue
        }

        if ($path -match '^/api/marketplace/([0-9]+)/media$' -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to view listing media."
                continue
            }
            $listingId = [long]$Matches[1]
            $mediaRows = Invoke-SqlQuery "SELECT FileName, ContentType, FileData FROM dbo.MarketplaceMedia WHERE ListingId = @ListingId" @{
                "@ListingId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $listingId }
            }
            $media = $mediaRows | Select-Object -First 1
            if ($null -eq $media) {
                Send-ApiError $context 404 "Listing media not found."
                continue
            }
            $safeFileName = [Uri]::EscapeDataString($media.FileName)
            $response.Headers.Add("Content-Disposition", "inline; filename*=UTF-8''$safeFileName")
            Write-Binary $context 200 $media.ContentType $media.FileData
            continue
        }

        if ($path -eq "/api/documents" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to browse documents."
                continue
            }
            $documents = Invoke-SqlQuery @'
SELECT TOP (100) d.DocumentId AS id, d.FileName AS fileName, d.CreatedAt AS createdAt,
       u.Name AS uploader
FROM dbo.Documents d
JOIN dbo.Users u ON u.UserId = d.UserId
ORDER BY d.CreatedAt DESC
'@
            Write-Json $context 200 @{ documents = @($documents | ForEach-Object {
                @{
                    id = $_.id
                    fileName = $_.fileName
                    uploader = $_.uploader
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/documents" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to upload a document."
                continue
            }
            $data = Get-RequestBody $context
            $fileName = [IO.Path]::GetFileName(([string]$data.fileName).Trim())
            $fileName = ($fileName -replace '[\x00-\x1f"<>|]', '').Trim()
            try {
                $fileBytes = [Convert]::FromBase64String([string]$data.contentBase64)
            }
            catch {
                Send-ApiError $context 400 "The PDF file could not be decoded."
                continue
            }
            if ($fileName.Length -lt 1 -or $fileName.Length -gt 255 -or $fileBytes.Length -lt 5 -or $fileBytes.Length -gt 10485760 -or [Text.Encoding]::ASCII.GetString($fileBytes, 0, 5) -ne "%PDF-") {
                Send-ApiError $context 400 "Choose a valid PDF file smaller than 10 MB."
                continue
            }
            $documentId = [long](Invoke-SqlScalar @'
INSERT INTO dbo.Documents (UserId, FileName, FileData)
VALUES (@UserId, @FileName, @FileData);
SELECT CAST(SCOPE_IDENTITY() AS bigint);
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@FileName" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 255; value = $fileName }
                "@FileData" = @{ type = [System.Data.SqlDbType]::VarBinary; size = -1; value = $fileBytes }
            })
            Write-Json $context 201 @{ uploaded = $true; id = $documentId }
            continue
        }

        if ($path -match '^/api/documents/([0-9]+)/download$' -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to download documents."
                continue
            }
            $documentId = [long]$Matches[1]
            $documents = Invoke-SqlQuery "SELECT FileName, FileData FROM dbo.Documents WHERE DocumentId = @DocumentId" @{
                "@DocumentId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $documentId }
            }
            $document = $documents | Select-Object -First 1
            if ($null -eq $document) {
                Send-ApiError $context 404 "Document not found."
                continue
            }
            $safeFileName = [Uri]::EscapeDataString($document.FileName)
            $response.Headers.Add("Content-Disposition", "attachment; filename*=UTF-8''$safeFileName")
            Write-Binary $context 200 "application/pdf" $document.FileData
            continue
        }

        if ($path -match '^/api/movies/([0-9]+)/stream$' -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to watch movies."
                continue
            }
            $movieId = [long]$Matches[1]
            $movies = Invoke-SqlQuery "SELECT m.FileSize, m.ContentType FROM dbo.Movies m JOIN dbo.Users u ON u.UserId = m.UserId WHERE m.MovieId = @MovieId AND m.IsComplete = 1 AND u.IsBanned = 0" @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
            }
            $movie = $movies | Select-Object -First 1
            if ($null -eq $movie) {
                Send-ApiError $context 404 "Movie not found."
                continue
            }
            Write-MovieStream $context $movieId ([long]$movie.FileSize) $movie.ContentType
            continue
        }

        if ($path -eq "/api/movies" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to browse movies."
                continue
            }
            $movies = Invoke-SqlQuery @'
SELECT TOP (100) m.MovieId AS id, m.Title AS title, m.Description AS description,
       m.ContentType AS contentType, m.FileSize AS fileSize, m.CreatedAt AS createdAt,
       u.UserId AS uploaderId, u.Name AS uploaderName
FROM dbo.Movies m
JOIN dbo.Users u ON u.UserId = m.UserId
WHERE m.IsComplete = 1 AND u.IsBanned = 0
ORDER BY m.CreatedAt DESC
'@
            Write-Json $context 200 @{ movies = @($movies | ForEach-Object {
                @{
                    id = $_.id
                    title = $_.title
                    description = $_.description
                    contentType = $_.contentType
                    fileSize = $_.fileSize
                    uploaderId = $_.uploaderId
                    uploaderName = $_.uploaderName
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                    streamUrl = "/api/movies/$($_.id)/stream"
                }
            }) }
            continue
        }

        if ($path -eq "/api/movies/upload/start" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to upload a movie."
                continue
            }
            $data = Get-RequestBody $context
            $title = ([string]$data.title).Trim()
            $description = ([string]$data.description).Trim()
            $fileName = [IO.Path]::GetFileName(([string]$data.fileName).Trim())
            $contentType = ([string]$data.contentType).Trim().ToLowerInvariant()
            $fileSize = [long]0
            if ($title.Length -lt 1 -or $title.Length -gt 120 -or $description.Length -gt 1000 -or $fileName.Length -lt 1 -or $fileName.Length -gt 255 -or $contentType -notin @("video/mp4", "video/webm") -or -not [long]::TryParse([string]$data.fileSize, [ref]$fileSize) -or $fileSize -lt 1 -or $fileSize -gt $MaximumMovieSize -or $data.rightsConfirmed -ne $true) {
                Send-ApiError $context 400 "Enter a title, choose an MP4 or WebM movie up to 1 GB, and confirm you have permission to share it."
                continue
            }
            $expectedExtension = if ($contentType -eq "video/mp4") { ".mp4" } else { ".webm" }
            if ([IO.Path]::GetExtension($fileName).ToLowerInvariant() -ne $expectedExtension) {
                Send-ApiError $context 400 "The movie extension does not match its video format."
                continue
            }
            $chunkCount = [int][Math]::Ceiling($fileSize / $MovieChunkSize)
            $movieId = [long](Invoke-SqlScalar @'
INSERT INTO dbo.Movies (UserId, Title, Description, FileName, ContentType, FileSize, ChunkCount, RightsConfirmed)
VALUES (@UserId, @Title, @Description, @FileName, @ContentType, @FileSize, @ChunkCount, 1);
SELECT CAST(SCOPE_IDENTITY() AS bigint);
'@ @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Title" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 120; value = $title }
                "@Description" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 1000; value = $description }
                "@FileName" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 255; value = $fileName }
                "@ContentType" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $contentType }
                "@FileSize" = @{ type = [System.Data.SqlDbType]::BigInt; value = $fileSize }
                "@ChunkCount" = @{ type = [System.Data.SqlDbType]::Int; value = $chunkCount }
            })
            Write-Json $context 201 @{ movieId = $movieId; chunkSize = $MovieChunkSize; chunkCount = $chunkCount }
            continue
        }

        if ($path -eq "/api/movies/upload/chunk" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to upload a movie."
                continue
            }
            $data = Get-RequestBody $context
            $movieId = [long]0
            $chunkIndex = [int]-1
            if (-not [long]::TryParse([string]$data.movieId, [ref]$movieId) -or -not [int]::TryParse([string]$data.chunkIndex, [ref]$chunkIndex)) {
                Send-ApiError $context 400 "Movie chunk request is invalid."
                continue
            }
            try {
                $chunkBytes = [Convert]::FromBase64String([string]$data.contentBase64)
            }
            catch {
                Send-ApiError $context 400 "Movie chunk data could not be decoded."
                continue
            }
            $movies = Invoke-SqlQuery "SELECT FileSize, ChunkCount FROM dbo.Movies WHERE MovieId = @MovieId AND UserId = @UserId AND IsComplete = 0" @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            $movie = $movies | Select-Object -First 1
            if ($null -eq $movie -or $chunkIndex -lt 0 -or $chunkIndex -ge $movie.ChunkCount) {
                Send-ApiError $context 404 "Movie upload not found."
                continue
            }
            $expectedLength = [int][Math]::Min($MovieChunkSize, [long]$movie.FileSize - ([long]$chunkIndex * $MovieChunkSize))
            if ($chunkBytes.Length -ne $expectedLength) {
                Send-ApiError $context 400 "Movie chunk size is invalid."
                continue
            }
            [void](Invoke-SqlNonQuery @'
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM dbo.MovieChunks WITH (UPDLOCK, HOLDLOCK) WHERE MovieId = @MovieId AND ChunkIndex = @ChunkIndex)
    UPDATE dbo.MovieChunks SET FileData = @FileData WHERE MovieId = @MovieId AND ChunkIndex = @ChunkIndex;
ELSE
    INSERT INTO dbo.MovieChunks (MovieId, ChunkIndex, FileData) VALUES (@MovieId, @ChunkIndex, @FileData);
COMMIT TRANSACTION;
'@ @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
                "@ChunkIndex" = @{ type = [System.Data.SqlDbType]::Int; value = $chunkIndex }
                "@FileData" = @{ type = [System.Data.SqlDbType]::VarBinary; size = -1; value = $chunkBytes }
            })
            Write-Json $context 200 @{ saved = $true; chunkIndex = $chunkIndex }
            continue
        }

        if ($path -eq "/api/movies/upload/complete" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to complete a movie upload."
                continue
            }
            $data = Get-RequestBody $context
            $movieId = [long]0
            if (-not [long]::TryParse([string]$data.movieId, [ref]$movieId)) {
                Send-ApiError $context 400 "Movie upload ID is invalid."
                continue
            }
            $checks = Invoke-SqlQuery @'
SELECT m.FileSize, m.ChunkCount, m.ContentType, COUNT(c.ChunkIndex) AS savedChunks,
       COALESCE(SUM(DATALENGTH(c.FileData)), 0) AS savedBytes,
       MIN(c.ChunkIndex) AS firstChunk, MAX(c.ChunkIndex) AS lastChunk
FROM dbo.Movies m
LEFT JOIN dbo.MovieChunks c ON c.MovieId = m.MovieId
WHERE m.MovieId = @MovieId AND m.UserId = @UserId AND m.IsComplete = 0
GROUP BY m.FileSize, m.ChunkCount, m.ContentType
'@ @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            $check = $checks | Select-Object -First 1
            if ($null -eq $check) {
                Send-ApiError $context 404 "Movie upload not found."
                continue
            }
            if ($check.savedChunks -ne $check.ChunkCount -or $check.savedBytes -ne $check.FileSize -or $check.firstChunk -ne 0 -or $check.lastChunk -ne ($check.ChunkCount - 1)) {
                Send-ApiError $context 409 "The movie upload is incomplete. Please retry missing chunks."
                continue
            }
            $firstChunks = Invoke-SqlQuery "SELECT FileData FROM dbo.MovieChunks WHERE MovieId = @MovieId AND ChunkIndex = 0" @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
            }
            $firstChunk = $firstChunks | Select-Object -First 1
            $signatureIsValid = if ($null -eq $firstChunk) { $false } elseif ($check.ContentType -eq "video/mp4") {
                $firstChunk.FileData.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($firstChunk.FileData, 4, 4) -eq "ftyp"
            } else {
                $firstChunk.FileData.Length -ge 4 -and [BitConverter]::ToString($firstChunk.FileData, 0, 4) -eq "1A-45-DF-A3"
            }
            if (-not $signatureIsValid) {
                Send-ApiError $context 400 "The movie file does not match its selected video format."
                continue
            }
            [void](Invoke-SqlNonQuery "UPDATE dbo.Movies SET IsComplete = 1 WHERE MovieId = @MovieId AND UserId = @UserId AND IsComplete = 0" @{
                "@MovieId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $movieId }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            })
            Write-Json $context 200 @{ completed = $true; movieId = $movieId }
            continue
        }

        if ($path -eq "/api/marketplace" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to browse the marketplace."
                continue
            }
            $listings = Invoke-SqlQuery @'
SELECT TOP (100) l.ListingId AS id, l.Category AS category, l.Title AS title,
       l.Description AS description, l.Price AS price, l.CreatedAt AS createdAt,
    u.Name AS seller, u.Email AS sellerEmail, mm.ContentType AS mediaContentType
FROM dbo.MarketplaceListings l
JOIN dbo.Users u ON u.UserId = l.UserId
LEFT JOIN dbo.MarketplaceMedia mm ON mm.ListingId = l.ListingId
ORDER BY l.CreatedAt DESC
'@
            Write-Json $context 200 @{ listings = @($listings | ForEach-Object {
                @{
                    id = $_.id
                    category = $_.category
                    title = $_.title
                    description = $_.description
                    price = if ($null -eq $_.price) { $null } else { [decimal]$_.price }
                    seller = $_.seller
                    sellerEmail = $_.sellerEmail
                    mediaContentType = $_.mediaContentType
                    mediaUrl = if ($null -eq $_.mediaContentType) { $null } else { "/api/marketplace/$($_.id)/media" }
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/marketplace" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to create a listing."
                continue
            }
            $data = Get-RequestBody $context
            $media = Get-OptionalMedia $data
            $category = ([string]$data.category).Trim().ToLowerInvariant()
            $title = ([string]$data.title).Trim()
            $description = ([string]$data.description).Trim()
            $price = [DBNull]::Value
            if (-not [string]::IsNullOrWhiteSpace([string]$data.price)) {
                $parsedPrice = [decimal]0
                if (-not [decimal]::TryParse([string]$data.price, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedPrice) -or $parsedPrice -lt 0 -or $parsedPrice -gt 9999999999.99) {
                    Send-ApiError $context 400 "Enter a valid non-negative price."
                    continue
                }
                $price = $parsedPrice
            }
            if ($category -notin @("business", "job", "skill", "product") -or $title.Length -lt 1 -or $title.Length -gt 120 -or $description.Length -lt 1 -or $description.Length -gt 1000) {
                Send-ApiError $context 400 "Choose a valid category and enter a title and description within the displayed limits."
                continue
            }
            $listingInsert = @'
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT INTO dbo.MarketplaceListings (UserId, Category, Title, Description, Price)
    VALUES (@UserId, @Category, @Title, @Description, @Price);
    DECLARE @ListingId bigint = CAST(SCOPE_IDENTITY() AS bigint);
    IF @MediaData IS NOT NULL
        INSERT INTO dbo.MarketplaceMedia (ListingId, FileName, ContentType, FileData) VALUES (@ListingId, @MediaFileName, @MediaContentType, @MediaData);
    COMMIT TRANSACTION;
    SELECT @ListingId;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
            [void](Invoke-SqlScalar $listingInsert @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@Category" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 20; value = $category }
                "@Title" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 120; value = $title }
                "@Description" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 1000; value = $description }
                "@Price" = @{ type = [System.Data.SqlDbType]::Decimal; precision = 12; scale = 2; value = $price }
                "@MediaFileName" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 255; value = if ($null -eq $media) { $null } else { $media.fileName } }
                "@MediaContentType" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = if ($null -eq $media) { $null } else { $media.contentType } }
                "@MediaData" = @{ type = [System.Data.SqlDbType]::VarBinary; size = -1; value = if ($null -eq $media) { $null } else { $media.fileBytes } }
            })
            Write-Json $context 201 @{ created = $true }
            continue
        }

        if ($path -eq "/api/games/rooms" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedUser $context)) {
                Send-ApiError $context 401 "Please sign in to browse game rooms."
                continue
            }
            $rooms = Invoke-SqlQuery @'
SELECT TOP (40) r.RoomCode AS code, r.GameType AS game, r.CreatedAt AS createdAt,
       u.Name AS hostName
FROM dbo.GameRooms r
JOIN dbo.Users u ON u.UserId = r.HostId
WHERE r.Status = N'waiting'
ORDER BY r.CreatedAt DESC
'@
            Write-Json $context 200 @{ rooms = @($rooms | ForEach-Object {
                @{
                    code = $_.code
                    game = $_.game
                    hostName = $_.hostName
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/games/create" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to create a game room."
                continue
            }
            $data = Get-RequestBody $context
            $gameType = ([string]$data.game).Trim().ToLowerInvariant()
            if ($gameType -notin @("chess", "snooker", "ludo", "whot")) {
                Send-ApiError $context 400 "Choose chess, snooker, ludo, or whot."
                continue
            }
            if ($null -eq $data.state) {
                Send-ApiError $context 400 "A starting game state is required."
                continue
            }
            $stateJson = ConvertTo-Json -InputObject $data.state -Depth 12 -Compress
            if ($stateJson.Length -gt 60000) {
                Send-ApiError $context 413 "The game state is too large."
                continue
            }
            $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
            $roomCode = ""
            for ($attempt = 0; $attempt -lt 8; $attempt++) {
                $roomCode = ""
                for ($index = 0; $index -lt 6; $index++) {
                    $roomCode += $alphabet[(Get-Random -Maximum $alphabet.Length)]
                }
                $exists = [int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.GameRooms WHERE RoomCode = @RoomCode" @{
                    "@RoomCode" = @{ type = [System.Data.SqlDbType]::Char; size = 6; value = $roomCode }
                })
                if ($exists -eq 0) { break }
                $roomCode = ""
            }
            if ([string]::IsNullOrWhiteSpace($roomCode)) {
                Send-ApiError $context 503 "Could not create a room code. Please try again."
                continue
            }
            [void](Invoke-SqlNonQuery "INSERT INTO dbo.GameRooms (RoomCode, GameType, HostId, StateJson) VALUES (@RoomCode, @GameType, @UserId, @StateJson)" @{
                "@RoomCode" = @{ type = [System.Data.SqlDbType]::Char; size = 6; value = $roomCode }
                "@GameType" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 12; value = $gameType }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@StateJson" = @{ type = [System.Data.SqlDbType]::NVarChar; size = -1; value = $stateJson }
            })
            Write-Json $context 201 @{ code = $roomCode; game = $gameType; revision = 1 }
            continue
        }

        if ($path -eq "/api/games/join" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to join a game."
                continue
            }
            $data = Get-RequestBody $context
            $roomCode = ([string]$data.code).Trim().ToUpperInvariant()
            if ($roomCode -notmatch '^[A-HJ-NP-Z2-9]{6}$') {
                Send-ApiError $context 400 "Enter a valid six-character room code."
                continue
            }
            $changed = Invoke-SqlNonQuery @'
UPDATE dbo.GameRooms
SET GuestId = @UserId, Status = N'active', Revision = Revision + 1, UpdatedAt = SYSUTCDATETIME()
WHERE RoomCode = @RoomCode AND Status = N'waiting' AND GuestId IS NULL AND HostId <> @UserId;
'@ @{
                "@RoomCode" = @{ type = [System.Data.SqlDbType]::Char; size = 6; value = $roomCode }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            if ($changed -ne 1) {
                Send-ApiError $context 409 "That room is unavailable, full, or already joined."
                continue
            }
            Write-Json $context 200 @{ joined = $true; code = $roomCode }
            continue
        }

        if ($path -eq "/api/games/room" -and $method -eq "GET") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to view this game."
                continue
            }
            $roomCode = ([string]$request.QueryString["code"]).Trim().ToUpperInvariant()
            $rooms = Invoke-SqlQuery @'
SELECT r.RoomCode AS code, r.GameType AS game, r.Status AS status, r.StateJson AS stateJson,
       r.Revision AS revision, r.HostId AS hostId, r.GuestId AS guestId,
       host.Name AS hostName, guest.Name AS guestName
FROM dbo.GameRooms r
JOIN dbo.Users host ON host.UserId = r.HostId
LEFT JOIN dbo.Users guest ON guest.UserId = r.GuestId
WHERE r.RoomCode = @RoomCode AND (r.HostId = @UserId OR r.GuestId = @UserId)
'@ @{
                "@RoomCode" = @{ type = [System.Data.SqlDbType]::Char; size = 6; value = $roomCode }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
            }
            $room = $rooms | Select-Object -First 1
            if ($null -eq $room) {
                Send-ApiError $context 404 "Game room not found."
                continue
            }
            Write-Json $context 200 @{
                room = @{
                    code = $room.code
                    game = $room.game
                    status = $room.status
                    state = ConvertFrom-Json -InputObject $room.stateJson
                    revision = $room.revision
                    hostId = $room.hostId
                    guestId = $room.guestId
                    hostName = $room.hostName
                    guestName = $room.guestName
                    myId = $user.UserId
                }
            }
            continue
        }

        if ($path -eq "/api/games/state" -and $method -eq "POST") {
            $user = Get-AuthenticatedUser $context
            if ($null -eq $user) {
                Send-ApiError $context 401 "Please sign in to play."
                continue
            }
            $data = Get-RequestBody $context
            $roomCode = ([string]$data.code).Trim().ToUpperInvariant()
            $revision = [int]0
            if ($roomCode -notmatch '^[A-HJ-NP-Z2-9]{6}$' -or -not [int]::TryParse([string]$data.revision, [ref]$revision) -or $revision -lt 1 -or $null -eq $data.state) {
                Send-ApiError $context 400 "Game update is invalid."
                continue
            }
            $stateJson = ConvertTo-Json -InputObject $data.state -Depth 12 -Compress
            if ($stateJson.Length -gt 60000) {
                Send-ApiError $context 413 "The game state is too large."
                continue
            }
            $changed = Invoke-SqlNonQuery @'
UPDATE dbo.GameRooms
SET StateJson = @StateJson, Revision = Revision + 1, UpdatedAt = SYSUTCDATETIME()
WHERE RoomCode = @RoomCode AND Revision = @Revision AND Status = N'active'
  AND (HostId = @UserId OR GuestId = @UserId);
'@ @{
                "@RoomCode" = @{ type = [System.Data.SqlDbType]::Char; size = 6; value = $roomCode }
                "@Revision" = @{ type = [System.Data.SqlDbType]::Int; value = $revision }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $user.UserId }
                "@StateJson" = @{ type = [System.Data.SqlDbType]::NVarChar; size = -1; value = $stateJson }
            }
            if ($changed -ne 1) {
                Send-ApiError $context 409 "The game changed. Refresh the room and try again."
                continue
            }
            Write-Json $context 200 @{ revision = $revision + 1 }
            continue
        }

        if ($path -eq "/api/register" -and $method -eq "POST") {
            $data = Get-RequestBody $context
            $name = ([string]$data.name).Trim()
            $email = ([string]$data.email).Trim().ToLowerInvariant()
            $password = [string]$data.password
            if ($name.Length -lt 1 -or $name.Length -gt 100 -or -not (Test-Email $email) -or $password.Length -lt 8 -or $password.Length -gt 256 -or $data.terms -ne "on") {
                Send-ApiError $context 400 "Enter a valid name and email, use a password of at least 8 characters, and accept the terms."
                continue
            }
            if ([int](Invoke-SqlScalar "SELECT COUNT(*) FROM dbo.Users WHERE Email = @Email" @{
                    "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $email }
                }) -gt 0) {
                Send-ApiError $context 409 "An account with this email already exists."
                continue
            }
            $passwordRecord = Get-PasswordRecord $password
            $insertQuery = @'
INSERT INTO dbo.Users (Name, Email, PasswordSalt, PasswordHash)
VALUES (@Name, @Email, @PasswordSalt, @PasswordHash)
'@
            try {
                [void](Invoke-SqlNonQuery $insertQuery @{
                    "@Name" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 100; value = $name }
                    "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $email }
                    "@PasswordSalt" = @{ type = [System.Data.SqlDbType]::VarBinary; size = 16; value = [Convert]::FromBase64String($passwordRecord.salt) }
                    "@PasswordHash" = @{ type = [System.Data.SqlDbType]::VarBinary; size = 32; value = [Convert]::FromBase64String($passwordRecord.hash) }
                })
            }
            catch [System.Data.SqlClient.SqlException] {
                if ($_.Exception.Number -eq 2601 -or $_.Exception.Number -eq 2627) {
                    Send-ApiError $context 409 "An account with this email already exists."
                    continue
                }
                throw
            }
            Write-Json $context 201 @{ created = $true }
            continue
        }

        if ($path -eq "/api/login" -and $method -eq "POST") {
            $data = Get-RequestBody $context
            $email = ([string]$data.email).Trim().ToLowerInvariant()
            $rateKey = "user:$($request.RemoteEndPoint.Address)"
            if (-not (Test-RateLimit $rateKey)) {
                Send-ApiError $context 429 "Too many unsuccessful attempts. Wait 15 minutes and try again."
                continue
            }
            $users = Invoke-SqlQuery "SELECT Email, PasswordSalt, PasswordHash, IsBanned FROM dbo.Users WHERE Email = @Email" @{
                "@Email" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 254; value = $email }
            }
            $user = $users | Select-Object -First 1
            if ($null -eq $user -or -not (Test-Password ([string]$data.password) ([Convert]::ToBase64String($user.PasswordSalt)) ([Convert]::ToBase64String($user.PasswordHash)))) {
                Add-FailedAttempt $rateKey
                Send-ApiError $context 401 "Email or password is incorrect."
                continue
            }
            $Script:LoginAttempts.Remove($rateKey)
            New-Session $context "user" $email
            Write-Json $context 200 @{ signedIn = $true; appealRequired = [bool]$user.IsBanned }
            continue
        }

        if ($path -eq "/api/admin/login" -and $method -eq "POST") {
            $data = Get-RequestBody $context
            $rateKey = "admin:$($request.RemoteEndPoint.Address)"
            if (-not (Test-RateLimit $rateKey)) {
                Send-ApiError $context 429 "Too many unsuccessful attempts. Wait 15 minutes and try again."
                continue
            }
            $admins = Invoke-SqlQuery "SELECT Email, PasswordSalt, PasswordHash FROM dbo.AdminAccount WHERE AccountId = 1"
            $admin = $admins | Select-Object -First 1
            if ($null -eq $admin -or
                ([string]$data.email).Trim().ToLowerInvariant() -ne $OwnerEmail -or
                -not (Test-Password ([string]$data.password) ([Convert]::ToBase64String($admin.PasswordSalt)) ([Convert]::ToBase64String($admin.PasswordHash)))) {
                Add-FailedAttempt $rateKey
                Send-ApiError $context 401 "Owner email or password is incorrect."
                continue
            }
            $Script:LoginAttempts.Remove($rateKey)
            New-Session $context "admin" $OwnerEmail
            Write-Json $context 200 @{ signedIn = $true }
            continue
        }

        if ($path -eq "/api/admin/accounts" -and $method -eq "GET") {
            $session = Get-Session $context
            if ($null -eq $session -or $session.role -ne "admin" -or $session.email -ne $OwnerEmail) {
                Send-ApiError $context 401 "Sign in with the owner account to view registrations."
                continue
            }
            $search = ([string]$request.QueryString["q"]).Trim()
            if ($search.Length -gt 100) {
                Send-ApiError $context 400 "Search text must be 100 characters or fewer."
                continue
            }
            $accounts = Get-AdminAccounts $search
            Write-Json $context 200 @{ accounts = $accounts.accounts; onlineUsers = (Get-OnlineUserEmails).Count }
            continue
        }

        if ($path -eq "/api/admin/users/ban" -and $method -eq "POST") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to ban users."
                continue
            }
            $data = Get-RequestBody $context
            $targetId = [Guid]::Empty
            $reason = ([string]$data.reason).Trim()
            if (-not [Guid]::TryParse([string]$data.userId, [ref]$targetId) -or $reason.Length -lt 5 -or $reason.Length -gt 500) {
                Send-ApiError $context 400 "Choose a user and enter a ban reason between 5 and 500 characters."
                continue
            }
            $changed = Invoke-SqlNonQuery "UPDATE dbo.Users SET IsBanned = 1, BanReason = @Reason, BannedAt = SYSUTCDATETIME(), BannedBy = NULL WHERE UserId = @UserId" @{
                "@Reason" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 500; value = $reason }
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            }
            if ($changed -eq 0) {
                Send-ApiError $context 404 "User not found."
                continue
            }
            [void](Invoke-SqlNonQuery "DELETE FROM dbo.UserLocations WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            })
            $targetUsers = Invoke-SqlQuery "SELECT Email FROM dbo.Users WHERE UserId = @UserId" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            }
            $targetEmail = ($targetUsers | Select-Object -First 1).Email
            foreach ($token in @($Script:Sessions.Keys)) {
                $activeSession = $Script:Sessions[$token]
                if ($activeSession.role -eq "user" -and $activeSession.email -eq $targetEmail) {
                    $Script:Sessions.Remove($token)
                }
            }
            Write-Json $context 200 @{ banned = $true }
            continue
        }

        if ($path -eq "/api/admin/users/unban" -and $method -eq "POST") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to unban users."
                continue
            }
            $data = Get-RequestBody $context
            $targetId = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$data.userId, [ref]$targetId)) {
                Send-ApiError $context 400 "Choose a valid user."
                continue
            }
            $changed = Invoke-SqlNonQuery "UPDATE dbo.Users SET IsBanned = 0, BanReason = NULL, BannedAt = NULL, BannedBy = NULL WHERE UserId = @UserId AND IsBanned = 1" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            }
            if ($changed -eq 0) {
                Send-ApiError $context 404 "Banned user not found."
                continue
            }
            [void](Invoke-SqlNonQuery "UPDATE dbo.UnbanAppeals SET Status = N'approved', ReviewedAt = SYSUTCDATETIME(), ReviewedBy = NULL WHERE UserId = @UserId AND Status = N'pending'" @{
                "@UserId" = @{ type = [System.Data.SqlDbType]::UniqueIdentifier; value = $targetId }
            })
            Write-Json $context 200 @{ unbanned = $true }
            continue
        }

        if ($path -eq "/api/admin/reports" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to view reports."
                continue
            }
            $reports = Invoke-SqlQuery @'
SELECT TOP (200) r.ReportId AS id, r.Category AS category, r.Details AS details,
       r.Status AS status, r.CreatedAt AS createdAt,
       reporter.Name AS reporterName, reporter.Email AS reporterEmail,
       reported.Name AS reportedName, reported.Email AS reportedEmail,
       CONVERT(nvarchar(36), r.ReportedUserId) AS reportedUserId
FROM dbo.UserReports r
JOIN dbo.Users reporter ON reporter.UserId = r.ReporterId
JOIN dbo.Users reported ON reported.UserId = r.ReportedUserId
ORDER BY CASE WHEN r.Status = N'open' THEN 0 ELSE 1 END, r.CreatedAt DESC
'@
            Write-Json $context 200 @{ reports = @($reports | ForEach-Object {
                @{
                    id = $_.id
                    category = $_.category
                    details = $_.details
                    status = $_.status
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                    reporterName = $_.reporterName
                    reporterEmail = $_.reporterEmail
                    reportedName = $_.reportedName
                    reportedEmail = $_.reportedEmail
                    reportedUserId = $_.reportedUserId
                }
            }) }
            continue
        }

        if ($path -eq "/api/admin/reports/resolve" -and $method -eq "POST") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to resolve reports."
                continue
            }
            $data = Get-RequestBody $context
            $reportId = [long]0
            if (-not [long]::TryParse([string]$data.reportId, [ref]$reportId) -or $reportId -lt 1) {
                Send-ApiError $context 400 "Choose a valid report."
                continue
            }
            [void](Invoke-SqlNonQuery "UPDATE dbo.UserReports SET Status = N'resolved', ReviewedAt = SYSUTCDATETIME(), ReviewedBy = NULL WHERE ReportId = @ReportId AND Status = N'open'" @{
                "@ReportId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $reportId }
            })
            Write-Json $context 200 @{ resolved = $true }
            continue
        }

        if ($path -eq "/api/admin/appeals" -and $method -eq "GET") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to view appeals."
                continue
            }
            $appeals = Invoke-SqlQuery @'
SELECT TOP (200) a.AppealId AS id, a.Reason AS reason, a.Status AS status,
       a.CreatedAt AS createdAt, u.UserId AS userId, u.Name AS name, u.Email AS email,
       u.BanReason AS banReason
FROM dbo.UnbanAppeals a
JOIN dbo.Users u ON u.UserId = a.UserId
ORDER BY CASE WHEN a.Status = N'pending' THEN 0 ELSE 1 END, a.CreatedAt DESC
'@
            Write-Json $context 200 @{ appeals = @($appeals | ForEach-Object {
                @{
                    id = $_.id
                    userId = $_.userId
                    name = $_.name
                    email = $_.email
                    banReason = $_.banReason
                    reason = $_.reason
                    status = $_.status
                    createdAt = ConvertTo-UtcIsoString $_.createdAt
                }
            }) }
            continue
        }

        if ($path -eq "/api/admin/appeals/review" -and $method -eq "POST") {
            if ($null -eq (Get-AuthenticatedAdmin $context)) {
                Send-ApiError $context 401 "Sign in with the owner account to review appeals."
                continue
            }
            $data = Get-RequestBody $context
            $appealId = [long]0
            $decision = ([string]$data.decision).Trim().ToLowerInvariant()
            if (-not [long]::TryParse([string]$data.appealId, [ref]$appealId) -or $appealId -lt 1 -or $decision -notin @("approve", "deny")) {
                Send-ApiError $context 400 "Choose an appeal and a valid decision."
                continue
            }
            $approved = $decision -eq "approve"
            $reviewState = if ($approved) { "approved" } else { "denied" }
            $reviewed = [int](Invoke-SqlScalar @'
BEGIN TRY
    BEGIN TRANSACTION;
    DECLARE @UserId uniqueidentifier;
    SELECT @UserId = UserId FROM dbo.UnbanAppeals WITH (UPDLOCK, HOLDLOCK) WHERE AppealId = @AppealId AND Status = N'pending';
    IF @UserId IS NULL
    BEGIN
        ROLLBACK TRANSACTION;
        SELECT CAST(0 AS int);
        RETURN;
    END;
    IF @Decision = N'approve'
        UPDATE dbo.Users SET IsBanned = 0, BanReason = NULL, BannedAt = NULL, BannedBy = NULL WHERE UserId = @UserId;
    UPDATE dbo.UnbanAppeals SET Status = @Status, ReviewedAt = SYSUTCDATETIME(), ReviewedBy = NULL WHERE AppealId = @AppealId;
    COMMIT TRANSACTION;
    SELECT CAST(1 AS int);
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@ @{
                "@AppealId" = @{ type = [System.Data.SqlDbType]::BigInt; value = $appealId }
                "@Decision" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 8; value = $decision }
                "@Status" = @{ type = [System.Data.SqlDbType]::NVarChar; size = 12; value = $reviewState }
            })
            if ($reviewed -ne 1) {
                Send-ApiError $context 409 "That appeal has already been reviewed."
                continue
            }
            Write-Json $context 200 @{ reviewed = $true; decision = $decision }
            continue
        }

        if ($path -eq "/api/admin/logout" -and $method -eq "POST") {
            $cookie = $request.Cookies["dv_session"]
            if ($null -ne $cookie) {
                $Script:Sessions.Remove($cookie.Value)
            }
            $response.Headers.Add("Set-Cookie", "dv_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
            Write-Json $context 200 @{ signedOut = $true }
            continue
        }

        if ($path -eq "/api/logout" -and $method -eq "POST") {
            $cookie = $request.Cookies["dv_session"]
            if ($null -ne $cookie) {
                $Script:Sessions.Remove($cookie.Value)
            }
            $response.Headers.Add("Set-Cookie", "dv_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
            Write-Json $context 200 @{ signedOut = $true }
            continue
        }

        Send-ApiError $context 404 "API endpoint not found."
    }
    catch {
        Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $context -and -not $context.Response.OutputStream.CanWrite) {
            continue
        }
        if ($null -ne $context) {
            try {
                if ($_.Exception -is [System.ArgumentException]) {
                    Send-ApiError $context 400 $_.Exception.Message
                }
                else {
                    Send-ApiError $context 500 "The local server could not complete this request."
                }
            }
            catch {
            }
        }
    }
    finally {
        if ($null -ne $context) {
            try { $context.Response.Close() } catch { }
        }
    }
}

$listener.Stop()
$listener.Close()

using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

var port = 7777;
if (args.Length > 0 && int.TryParse(args[0], out var parsedPort))
{
    port = parsedPort;
}

var gate = new object();
var dataPath = Path.Combine(Directory.GetCurrentDirectory(), "players.json");
var accountsPath = Path.Combine(Directory.GetCurrentDirectory(), "accounts.json");
var worldPath = Path.Combine(Directory.GetCurrentDirectory(), "world.json");
var players = LoadPlayers(dataPath);
var accounts = LoadAccounts(accountsPath);
var world = LoadWorld(worldPath);
var endpoints = new Dictionary<string, IPEndPoint>(StringComparer.Ordinal);
var mapEndpoints = new HashSet<IPEndPoint>();
var activeWindow = TimeSpan.FromSeconds(10);
MapChange? lastMapChange = null;

if (NormalizeAccounts(accounts))
{
    SaveAccounts(accountsPath, accounts, gate);
}

void SaveAll()
{
    SavePlayers(dataPath, players, gate);
    SaveAccounts(accountsPath, accounts, gate);
}

using var udp = new UdpClient(port);
Console.WriteLine($"UDP server listening on 0.0.0.0:{port}");
Console.WriteLine("Payload format: id|name|x|y");
Console.WriteLine($"World loaded: {world.Width}x{world.Height} tiles");
Console.WriteLine($"World path: {worldPath}");
Console.WriteLine("Press Ctrl+C to stop.");

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    SaveAll();
    cts.Cancel();
};
AppDomain.CurrentDomain.ProcessExit += (_, _) => SaveAll();

var saveTask = Task.Run(async () =>
{
    try
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        while (await timer.WaitForNextTickAsync(cts.Token))
        {
            SavePlayers(dataPath, players, gate);
        }
    }
    catch (OperationCanceledException)
    {
    }
});

while (!cts.IsCancellationRequested)
{
    UdpReceiveResult result;
    try
    {
        result = await udp.ReceiveAsync(cts.Token);
    }
    catch (OperationCanceledException)
    {
        break;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Receive error: {ex.Message}");
        continue;
    }

    var message = Encoding.UTF8.GetString(result.Buffer);
    if (message.Equals("PING", StringComparison.Ordinal))
    {
        await SendToAsync(udp, "PONG", result.RemoteEndPoint);
        continue;
    }

    if (TryParseRegister(message, out var registerName, out var registerPassword, out var registerError))
    {
        if (registerError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + registerError, result.RemoteEndPoint);
            continue;
        }

        var created = false;
        lock (gate)
        {
            if (!accounts.ContainsKey(registerName))
            {
                accounts[registerName] = CreateAccount(registerName, registerPassword);
                created = true;
            }
        }

        if (!created)
        {
            await SendToAsync(udp, "ERR|exists", result.RemoteEndPoint);
            continue;
        }

        SaveAccounts(accountsPath, accounts, gate);
        await SendToAsync(udp, "OK", result.RemoteEndPoint);
        continue;
    }

    if (TryParseLogin(message, out var loginName, out var loginPassword, out var loginError))
    {
        if (loginError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + loginError, result.RemoteEndPoint);
            continue;
        }

        if (!TryValidateLogin(loginName, loginPassword, accounts, gate, out var loginReply, out var upgraded))
        {
            await SendToAsync(udp, "ERR|" + loginReply, result.RemoteEndPoint);
            continue;
        }
        if (upgraded)
        {
            SaveAccounts(accountsPath, accounts, gate);
        }

        var now = DateTime.UtcNow;
        var nameTaken = IsNameTaken(loginName, result.RemoteEndPoint, players, endpoints, gate, activeWindow, now);
        var spawnX = 0f;
        var spawnY = 0f;
        if (!nameTaken)
        {
            lock (gate)
            {
                var state = players.TryGetValue(loginName, out var existing)
                    ? existing with { LastSeenUtc = now }
                    : new PlayerState("login", loginName, 0, 0, now);
                spawnX = state.X;
                spawnY = state.Y;
                players[loginName] = state;
                endpoints[loginName] = result.RemoteEndPoint;
            }
        }

        var accessLevel = GetAccessLevel(loginName, accounts, gate);
        var reply = nameTaken
            ? "ERR|name_taken"
            : $"OK|{spawnX.ToString("0.###", CultureInfo.InvariantCulture)}|{spawnY.ToString("0.###", CultureInfo.InvariantCulture)}|{accessLevel}";
        await SendToAsync(udp, reply, result.RemoteEndPoint);
        continue;
    }

    if (TryParseChunkRequest(message, out var chunkRequest, out var chunkError))
    {
        if (chunkError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + chunkError, result.RemoteEndPoint);
            continue;
        }

        mapEndpoints.Add(result.RemoteEndPoint);
        var last = lastMapChange;
        if (last != null)
        {
            const int chunkSize = 64;
            var startX = chunkRequest.Cx * chunkSize;
            var startY = chunkRequest.Cy * chunkSize;
            var endX = startX + chunkSize - 1;
            var endY = startY + chunkSize - 1;
            if (last.X >= startX && last.X <= endX &&
                last.Y >= startY && last.Y <= endY)
            {
                var tileValue = world.GetTile(last.X, last.Y);
                Console.WriteLine(
                    $"Chunk {chunkRequest.Cx},{chunkRequest.Cy} includes last change ({last.X},{last.Y}) tile={tileValue}"
                );
            }
        }
        string chunkResponse;
        lock (gate)
        {
            chunkResponse = BuildChunkResponse(world, chunkRequest);
        }
        await SendToAsync(udp, chunkResponse, result.RemoteEndPoint);
        continue;
    }

    if (TryParseMapUpdate(message, out var mapUpdate, out var mapUpdateError))
    {
        if (mapUpdateError.Length != 0)
        {
            Console.WriteLine($"Map update rejected from {result.RemoteEndPoint}: {mapUpdateError}");
            await SendToAsync(udp, "ERR|" + mapUpdateError, result.RemoteEndPoint);
            continue;
        }

        Console.WriteLine($"Map update received from {result.RemoteEndPoint}: {mapUpdate.Changes.Length} changes");
        mapEndpoints.Add(result.RemoteEndPoint);
        MapUpdatePayload appliedUpdate;
        lock (gate)
        {
            appliedUpdate = ApplyMapUpdate(world, mapUpdate);
            SaveWorld(worldPath, world);
            world = LoadWorld(worldPath);
        }
        var appliedCount = appliedUpdate.Changes?.Length ?? 0;
        Console.WriteLine($"Map update applied: {appliedCount} changes saved");
        if (appliedCount > 0)
        {
            lastMapChange = appliedUpdate.Changes[0];
            var sample = lastMapChange;
            Console.WriteLine($"Map update sample applied: ({sample.X},{sample.Y}) tile={sample.Tile}");
        }
        if (appliedCount == 0 && mapUpdate.Changes.Length > 0)
        {
            var sample = mapUpdate.Changes
                .Take(3)
                .Select(change => $"({change.X},{change.Y})")
                .ToArray();
            Console.WriteLine(
                $"Map update ignored (out of bounds?). Sample coords: {string.Join(", ", sample)}. World {world.Width}x{world.Height}"
            );
        }

        var updateMessage = "MAPUPDATE|" + JsonSerializer.Serialize(appliedUpdate, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        });
        var updateBytes = Encoding.UTF8.GetBytes(updateMessage);
        List<IPEndPoint> playerTargets;
        lock (gate)
        {
            playerTargets = endpoints.Values.ToList();
        }
        var combinedTargets = new List<IPEndPoint>(mapEndpoints.Count + playerTargets.Count);
        combinedTargets.AddRange(mapEndpoints);
        combinedTargets.AddRange(playerTargets);

        var sentToMap = new HashSet<string>(StringComparer.Ordinal);
        var sentCount = 0;
        foreach (var endpoint in combinedTargets)
        {
            var key = endpoint.ToString();
            if (!sentToMap.Add(key))
            {
                continue;
            }

            try
            {
                await udp.SendAsync(updateBytes, updateBytes.Length, endpoint);
                sentCount++;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Send error: {ex.Message}");
            }
        }

        Console.WriteLine(
            $"Map update broadcast: {appliedCount} changes to {sentCount} endpoints (map {mapEndpoints.Count}, players {playerTargets.Count})"
        );
        continue;
    }

    if (!TryParsePayload(message, out var payload, out var error))
    {
        Console.WriteLine($"Invalid payload from {result.RemoteEndPoint}: {error}");
        continue;
    }

    var timestamp = DateTime.UtcNow;
    var duplicate = IsNameTaken(payload.Name, result.RemoteEndPoint, players, endpoints, gate, activeWindow, timestamp);
    if (duplicate)
    {
        await SendToAsync(udp, "ERR|name_taken", result.RemoteEndPoint);
        continue;
    }

    lock (gate)
    {
        players[payload.Name] = new PlayerState(
            payload.Id,
            payload.Name,
            payload.X,
            payload.Y,
            timestamp
        );
        endpoints[payload.Name] = result.RemoteEndPoint;
    }

    Console.WriteLine(
        $"From {result.RemoteEndPoint}: id={payload.Id}, name={payload.Name}, x={payload.X}, y={payload.Y}"
    );

    List<PlayerState> snapshot;
    List<IPEndPoint> targets;
    lock (gate)
    {
        var staleNames = players.Values
            .Where(player => timestamp - player.LastSeenUtc > activeWindow)
            .Select(player => player.Name)
            .Distinct()
            .ToList();
        foreach (var staleName in staleNames)
        {
            endpoints.Remove(staleName);
        }

        snapshot = players.Values
            .Where(player => timestamp - player.LastSeenUtc <= activeWindow)
            .ToList();
        targets = endpoints.Values.ToList();
    }

    var response = BuildBroadcast(snapshot);
    var bytes = Encoding.UTF8.GetBytes(response);
    var sentTo = new HashSet<string>(StringComparer.Ordinal);
    foreach (var endpoint in targets)
    {
        var key = endpoint.ToString();
        if (!sentTo.Add(key))
        {
            continue;
        }

        try
        {
            await udp.SendAsync(bytes, bytes.Length, endpoint);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Send error: {ex.Message}");
        }
    }
}

SaveAll();
await saveTask;

static bool TryParseRegister(string payload, out string name, out string password, out string error)
{
    name = string.Empty;
    password = string.Empty;
    error = string.Empty;

    if (!payload.StartsWith("REGISTER|", StringComparison.Ordinal))
    {
        return false;
    }

    var parts = payload.Split('|');
    if (parts.Length < 3)
    {
        error = "bad_register";
        return true;
    }

    name = parts[1].Trim();
    password = parts[2];
    if (name.Length == 0)
    {
        error = "bad_register";
    }

    if (password.Length == 0)
    {
        error = "bad_register";
    }

    return true;
}

static bool TryParseLogin(string payload, out string name, out string password, out string error)
{
    name = string.Empty;
    password = string.Empty;
    error = string.Empty;

    if (!payload.StartsWith("LOGIN|", StringComparison.Ordinal))
    {
        return false;
    }

    var parts = payload.Split('|');
    if (parts.Length < 3)
    {
        error = "bad_login";
        return true;
    }

    name = parts[1].Trim();
    password = parts[2];
    if (name.Length == 0 || password.Length == 0)
    {
        error = "bad_login";
    }

    return true;
}

static bool TryParsePayload(string payload, out PlayerPacket packet, out string error)
{
    packet = default;
    error = string.Empty;

    var parts = payload.Split('|');
    if (parts.Length != 4)
    {
        error = "expected 4 fields: id|name|x|y";
        return false;
    }

    var id = parts[0].Trim();
    var name = parts[1].Trim();
    if (id.Length == 0 || name.Length == 0)
    {
        error = "id and name must be non-empty";
        return false;
    }

    if (!float.TryParse(parts[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) ||
        !float.TryParse(parts[3], NumberStyles.Float, CultureInfo.InvariantCulture, out var y))
    {
        error = "x and y must be numbers (use '.' as decimal separator)";
        return false;
    }

    packet = new PlayerPacket(id, name, x, y);
    return true;
}

static bool TryParseChunkRequest(string payload, out ChunkRequest request, out string error)
{
    request = default;
    error = string.Empty;

    if (!payload.StartsWith("CHUNK|", StringComparison.Ordinal))
    {
        return false;
    }

    var parts = payload.Split('|');
    if (parts.Length < 3)
    {
        error = "bad_chunk";
        return true;
    }

    if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cx) ||
        !int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cy))
    {
        error = "bad_chunk";
        return true;
    }

    request = new ChunkRequest(cx, cy);
    return true;
}

static bool TryParseMapUpdate(string payload, out MapUpdatePayload update, out string error)
{
    update = new MapUpdatePayload();
    error = string.Empty;

    if (!payload.StartsWith("MAPUPDATE|", StringComparison.Ordinal))
    {
        return false;
    }

    var json = payload.Substring("MAPUPDATE|".Length);
    if (string.IsNullOrWhiteSpace(json))
    {
        error = "bad_map_update";
        return true;
    }

    try
    {
        update = JsonSerializer.Deserialize<MapUpdatePayload>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new MapUpdatePayload();
    }
    catch (Exception)
    {
        error = "bad_map_update";
        return true;
    }

    if (update.Changes == null || update.Changes.Length == 0)
    {
        error = "bad_map_update";
    }

    return true;
}

static MapUpdatePayload ApplyMapUpdate(WorldMap world, MapUpdatePayload update)
{
    if (update.Changes == null || update.Changes.Length == 0)
    {
        return new MapUpdatePayload();
    }

    var applied = new List<MapChange>();
    foreach (var change in update.Changes)
    {
        if (change.X < 0 || change.Y < 0 || change.X >= world.Width || change.Y >= world.Height)
        {
            continue;
        }

        world.SetTile(change.X, change.Y, change.Tile);
        applied.Add(change);
    }

    return new MapUpdatePayload
    {
        Changes = applied.ToArray()
    };
}

static bool IsNameTaken(
    string name,
    IPEndPoint source,
    Dictionary<string, PlayerState> players,
    Dictionary<string, IPEndPoint> endpoints,
    object gate,
    TimeSpan activeWindow,
    DateTime now)
{
    lock (gate)
    {
        if (!players.TryGetValue(name, out var existing))
        {
            return false;
        }

        if (now - existing.LastSeenUtc > activeWindow)
        {
            return false;
        }

        if (!endpoints.TryGetValue(name, out var endpoint))
        {
            return false;
        }

        return !endpoint.Equals(source);
    }
}

static bool TryValidateLogin(
    string name,
    string password,
    Dictionary<string, Account> accounts,
    object gate,
    out string error,
    out bool upgraded)
{
    error = string.Empty;
    upgraded = false;
    lock (gate)
    {
        if (!accounts.TryGetValue(name, out var account))
        {
            error = "not_found";
            return false;
        }

        if (!string.IsNullOrWhiteSpace(account.PasswordHash) &&
            !string.IsNullOrWhiteSpace(account.Salt))
        {
            if (!VerifyPassword(password, account.Salt, account.PasswordHash))
            {
                error = "wrong_password";
                return false;
            }
        }
        else if (!string.IsNullOrWhiteSpace(account.Password))
        {
            if (!string.Equals(account.Password, password, StringComparison.Ordinal))
            {
                error = "wrong_password";
                return false;
            }
            UpgradeAccountPassword(account, password);
            upgraded = true;
        }
        else
        {
            error = "wrong_password";
            return false;
        }
    }

    return true;
}

static string BuildBroadcast(IEnumerable<PlayerState> players)
{
    var lines = players.Select(player =>
        $"{player.Id}|{player.Name}|{player.X.ToString("0.###", CultureInfo.InvariantCulture)}|{player.Y.ToString("0.###", CultureInfo.InvariantCulture)}"
    );
    return string.Join('\n', lines);
}

static string BuildChunkResponse(WorldMap world, ChunkRequest request)
{
    const int chunkSize = 64;
    var tiles = new int[chunkSize * chunkSize];
    var startX = request.Cx * chunkSize;
    var startY = request.Cy * chunkSize;
    var index = 0;

    for (var y = 0; y < chunkSize; y++)
    {
        var worldY = startY + y;
        for (var x = 0; x < chunkSize; x++)
        {
            var worldX = startX + x;
            tiles[index++] = world.GetTile(worldX, worldY);
        }
    }

    var payload = new ChunkPayload
    {
        Cx = request.Cx,
        Cy = request.Cy,
        Size = chunkSize,
        Tiles = tiles
    };

    return JsonSerializer.Serialize(payload, new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    });
}

static Dictionary<string, PlayerState> LoadPlayers(string path)
{
    try
    {
        if (!File.Exists(path))
        {
            return new Dictionary<string, PlayerState>(StringComparer.Ordinal);
        }

        var json = File.ReadAllText(path, Encoding.UTF8);
        var list = JsonSerializer.Deserialize<List<PlayerState>>(json);
        return list == null
            ? new Dictionary<string, PlayerState>(StringComparer.Ordinal)
            : list.ToDictionary(item => item.Name, StringComparer.Ordinal);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Load error: {ex.Message}");
        return new Dictionary<string, PlayerState>(StringComparer.Ordinal);
    }
}

static Dictionary<string, Account> LoadAccounts(string path)
{
    try
    {
        if (!File.Exists(path))
        {
            return new Dictionary<string, Account>(StringComparer.Ordinal);
        }

        var json = File.ReadAllText(path, Encoding.UTF8);
        var list = JsonSerializer.Deserialize<List<Account>>(json);
        return list == null
            ? new Dictionary<string, Account>(StringComparer.Ordinal)
            : list.ToDictionary(item => item.Name, StringComparer.Ordinal);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Load error: {ex.Message}");
        return new Dictionary<string, Account>(StringComparer.Ordinal);
    }
}

static WorldMap LoadWorld(string path)
{
    try
    {
        if (!File.Exists(path))
        {
            var generated = WorldMap.Generate(256, 256);
            SaveWorld(path, generated);
            return generated;
        }

        var json = File.ReadAllText(path, Encoding.UTF8);
        var map = JsonSerializer.Deserialize<WorldMap>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (map == null || map.Tiles == null || map.Tiles.Length == 0)
        {
            var generated = WorldMap.Generate(256, 256);
            SaveWorld(path, generated);
            return generated;
        }

        return map;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"World load error: {ex.Message}");
        var generated = WorldMap.Generate(256, 256);
        SaveWorld(path, generated);
        return generated;
    }
}

static void SaveWorld(string path, WorldMap world)
{
    try
    {
        var json = JsonSerializer.Serialize(world, new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(path, json, Encoding.UTF8);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"World save error: {ex.Message}");
    }
}

static void SavePlayers(string path, Dictionary<string, PlayerState> players, object gate)
{
    try
    {
        List<PlayerState> snapshot;
        lock (gate)
        {
            snapshot = players.Values.ToList();
        }

        var json = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(path, json, Encoding.UTF8);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Save error: {ex.Message}");
    }
}

static void SaveAccounts(string path, Dictionary<string, Account> accounts, object gate)
{
    try
    {
        List<Account> snapshot;
        lock (gate)
        {
            snapshot = accounts.Values.ToList();
        }

        var json = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions
        {
            WriteIndented = true
        });
        File.WriteAllText(path, json, Encoding.UTF8);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Save error: {ex.Message}");
    }
}

static Account CreateAccount(string name, string password)
{
    var salt = RandomNumberGenerator.GetBytes(16);
    var hash = HashPassword(password, salt);
    return new Account
    {
        Name = name,
        PasswordHash = Convert.ToBase64String(hash),
        Salt = Convert.ToBase64String(salt),
        Password = string.Empty,
        AccessLevel = 5
    };
}

static void UpgradeAccountPassword(Account account, string password)
{
    var salt = RandomNumberGenerator.GetBytes(16);
    var hash = HashPassword(password, salt);
    account.Salt = Convert.ToBase64String(salt);
    account.PasswordHash = Convert.ToBase64String(hash);
    account.Password = string.Empty;
}

static byte[] HashPassword(string password, byte[] salt)
{
    return Rfc2898DeriveBytes.Pbkdf2(
        password,
        salt,
        100_000,
        HashAlgorithmName.SHA256,
        32);
}

static bool VerifyPassword(string password, string saltBase64, string hashBase64)
{
    try
    {
        var salt = Convert.FromBase64String(saltBase64);
        var expected = Convert.FromBase64String(hashBase64);
        var actual = HashPassword(password, salt);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
    catch (FormatException)
    {
        return false;
    }
}

static async Task SendToAsync(UdpClient udp, string message, IPEndPoint endpoint)
{
    var bytes = Encoding.UTF8.GetBytes(message);
    try
    {
        await udp.SendAsync(bytes, bytes.Length, endpoint);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Send error: {ex.Message}");
    }
}

static int GetAccessLevel(string name, Dictionary<string, Account> accounts, object gate)
{
    lock (gate)
    {
        if (accounts.TryGetValue(name, out var account))
        {
            return NormalizeAccessLevel(name, account.AccessLevel);
        }
    }

    return 5;
}

static bool NormalizeAccounts(Dictionary<string, Account> accounts)
{
    var changed = false;
    foreach (var (name, account) in accounts)
    {
        var normalized = NormalizeAccessLevel(name, account.AccessLevel);
        if (account.AccessLevel != normalized)
        {
            account.AccessLevel = normalized;
            changed = true;
        }
    }

    return changed;
}

static int NormalizeAccessLevel(string name, int level)
{
    if (string.Equals(name, "admin", StringComparison.OrdinalIgnoreCase))
    {
        return 1;
    }

    if (level >= 1 && level <= 5)
    {
        return level;
    }

    return 5;
}

readonly record struct PlayerPacket(string Id, string Name, float X, float Y);
readonly record struct ChunkRequest(int Cx, int Cy);

sealed record PlayerState(string Id, string Name, float X, float Y, DateTime LastSeenUtc);

sealed class ChunkPayload
{
    public int Cx { get; set; }
    public int Cy { get; set; }
    public int Size { get; set; }
    public int[] Tiles { get; set; } = Array.Empty<int>();
}

sealed class MapUpdatePayload
{
    public MapChange[] Changes { get; set; } = Array.Empty<MapChange>();
}

sealed class MapChange
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Tile { get; set; }
}

sealed class WorldMap
{
    public int Width { get; set; }
    public int Height { get; set; }
    public int[] Tiles { get; set; } = Array.Empty<int>();

    public int GetTile(int x, int y)
    {
        if (x < 0 || y < 0 || x >= Width || y >= Height)
        {
            return 0;
        }

        var index = y * Width + x;
        if (index < 0 || index >= Tiles.Length)
        {
            return 0;
        }

        return Tiles[index];
    }

    public void SetTile(int x, int y, int value)
    {
        if (x < 0 || y < 0 || x >= Width || y >= Height)
        {
            return;
        }

        var index = y * Width + x;
        if (index < 0 || index >= Tiles.Length)
        {
            return;
        }

        Tiles[index] = value;
    }

    public static WorldMap Generate(int width, int height)
    {
        var tiles = new int[width * height];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var value = ((x + y) % 7 == 0 || (x * 3 + y * 2) % 17 == 0) ? 1 : 0;
                tiles[y * width + x] = value;
            }
        }

        return new WorldMap
        {
            Width = width,
            Height = height,
            Tiles = tiles
        };
    }
}

sealed class Account
{
    public string Name { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public string Salt { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public int AccessLevel { get; set; }
}

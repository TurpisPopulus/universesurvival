using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

var port = 7777;
if (args.Length > 0 && int.TryParse(args[0], out var parsedPort))
{
    port = parsedPort;
}

var gate = new object();
var baseDir = AppContext.BaseDirectory;
var dataDir = Path.Combine(baseDir, "Data");
Directory.CreateDirectory(dataDir);
var playersPath = Path.Combine(dataDir, "players.json");
var accountsPath = Path.Combine(dataDir, "accounts.json");
var players = LoadPlayers(playersPath);
var accounts = LoadAccounts(accountsPath);
var world = LoadWorld(dataDir);
var endpoints = new Dictionary<string, IPEndPoint>(StringComparer.Ordinal);
var activeWindow = TimeSpan.FromSeconds(10);
var chunkSaveInterval = TimeSpan.FromSeconds(30);

if (NormalizeAccounts(accounts))
{
    SaveAccounts(accountsPath, accounts, gate);
}

void SaveAll()
{
    SavePlayers(playersPath, players, gate);
    SaveAccounts(accountsPath, accounts, gate);
    SaveDirtyChunks(dataDir, world, gate);
}

using var udp = new UdpClient(port);
Console.WriteLine($"UDP server listening on 0.0.0.0:{port}");
Console.WriteLine("Payload format: id|name|x|y");
Console.WriteLine($"World loaded: {world.Chunks.Count} chunks");
Console.WriteLine($"[DATA] baseDir   = {baseDir}");
Console.WriteLine($"[DATA] dataDir   = {dataDir}");
Console.WriteLine($"[DATA] playersPath = {playersPath}");
Console.WriteLine($"[DATA] accountsPath = {accountsPath}");
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
            SavePlayers(playersPath, players, gate);
        }
    }
    catch (OperationCanceledException)
    {
    }
});

var chunkSaveTask = Task.Run(async () =>
{
    try
    {
        using var timer = new PeriodicTimer(chunkSaveInterval);
        while (await timer.WaitForNextTickAsync(cts.Token))
        {
            SaveDirtyChunks(dataDir, world, gate);
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

        string? chunkResponse = null;
        lock (gate)
        {
            var chunk = GetOrCreateChunk(world, chunkRequest.Cx, chunkRequest.Cy);
            if (chunkRequest.LastKnownVersion < 0 || chunk.Version > chunkRequest.LastKnownVersion)
            {
                chunkResponse = BuildChunkResponse(chunk);
            }
        }
        if (chunkResponse != null)
        {
            await SendToAsync(udp, chunkResponse, result.RemoteEndPoint);
        }
        continue;
    }

    if (TryParseEdit(message, out var editPayload, out var editError))
    {
        if (editError.Length != 0)
        {
            Console.WriteLine($"Edit rejected from {result.RemoteEndPoint}: {editError}");
            await SendToAsync(udp, "ERR|" + editError, result.RemoteEndPoint);
            continue;
        }

        var appliedCount = 0;
        lock (gate)
        {
            appliedCount = ApplyEdits(world, editPayload);
        }
        Console.WriteLine($"[EDIT] applied changes={appliedCount} from {result.RemoteEndPoint}");
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
await chunkSaveTask;

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
    if (parts.Length < 4)
    {
        error = "bad_chunk";
        return true;
    }

    if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cx) ||
        !int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cy) ||
        !int.TryParse(parts[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out var lastKnownVersion))
    {
        error = "bad_chunk";
        return true;
    }

    request = new ChunkRequest(cx, cy, lastKnownVersion);
    return true;
}

static bool TryParseEdit(string payload, out EditPayload update, out string error)
{
    update = new EditPayload();
    error = string.Empty;

    if (!payload.StartsWith("EDIT|", StringComparison.Ordinal))
    {
        return false;
    }

    var json = payload.Substring("EDIT|".Length);
    if (string.IsNullOrWhiteSpace(json))
    {
        error = "bad_edit";
        return true;
    }

    try
    {
        update = JsonSerializer.Deserialize<EditPayload>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new EditPayload();
    }
    catch (Exception)
    {
        error = "bad_edit";
        return true;
    }

    if (update.Changes == null || update.Changes.Length == 0)
    {
        error = "bad_edit";
    }

    return true;
}

static int ApplyEdits(World world, EditPayload update)
{
    if (update.Changes == null || update.Changes.Length == 0)
    {
        return 0;
    }

    var applied = 0;
    foreach (var change in update.Changes)
    {
        var cx = FloorDiv(change.X, Chunk.ChunkSize);
        var cy = FloorDiv(change.Y, Chunk.ChunkSize);
        var localX = change.X - cx * Chunk.ChunkSize;
        var localY = change.Y - cy * Chunk.ChunkSize;
        if (localX < 0 || localX >= Chunk.ChunkSize || localY < 0 || localY >= Chunk.ChunkSize)
        {
            continue;
        }

        var chunk = GetOrCreateChunk(world, cx, cy);
        chunk.SetTile(localX, localY, change.Tile);
        chunk.Version++;
        chunk.IsDirty = true;
        applied++;
    }

    return applied;
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

static string BuildChunkResponse(Chunk chunk)
{
    var payload = new ChunkPayload
    {
        X = chunk.X,
        Y = chunk.Y,
        Size = Chunk.ChunkSize,
        Version = chunk.Version,
        Tiles = chunk.Tiles
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

static World LoadWorld(string dataDir)
{
    var chunks = new Dictionary<ChunkId, Chunk>();
    try
    {
        foreach (var path in Directory.EnumerateFiles(dataDir, "chunk_*.json"))
        {
            var chunk = LoadChunk(path);
            if (chunk == null)
            {
                continue;
            }

            var id = new ChunkId(chunk.X, chunk.Y);
            chunks[id] = chunk;
        }
    }
    catch (Exception ex)
    {
        Console.WriteLine($"World load error: {ex.Message}");
    }

    return new World(chunks);
}

static Chunk? LoadChunk(string path)
{
    try
    {
        var json = File.ReadAllText(path, Encoding.UTF8);
        var chunk = JsonSerializer.Deserialize<Chunk>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (chunk == null)
        {
            return null;
        }

        if (chunk.Tiles == null || chunk.Tiles.Length != Chunk.TileCount)
        {
            var repaired = new int[Chunk.TileCount];
            if (chunk.Tiles != null)
            {
                Array.Copy(chunk.Tiles, repaired, Math.Min(chunk.Tiles.Length, repaired.Length));
            }
            chunk.Tiles = repaired;
        }

        chunk.IsDirty = false;
        return chunk;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Chunk load error ({Path.GetFileName(path)}): {ex.Message}");
        return null;
    }
}

static void SaveDirtyChunks(string dataDir, World world, object gate)
{
    List<(Chunk chunk, int version)> dirty;
    lock (gate)
    {
        dirty = world.Chunks.Values
            .Where(chunk => chunk.IsDirty)
            .Select(chunk => (chunk, chunk.Version))
            .ToList();
    }

    foreach (var (chunk, version) in dirty)
    {
        try
        {
            var json = JsonSerializer.Serialize(chunk, new JsonSerializerOptions
            {
                WriteIndented = true
            });
            var path = Path.Combine(dataDir, $"chunk_{chunk.X}_{chunk.Y}.json");
            WriteAllTextAtomic(path, json);
            lock (gate)
            {
                if (chunk.Version == version)
                {
                    chunk.IsDirty = false;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Chunk save error ({chunk.X},{chunk.Y}): {ex.Message}");
        }
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
        WriteAllTextAtomic(path, json);
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
        WriteAllTextAtomic(path, json);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Save error: {ex.Message}");
    }
}

static void WriteAllTextAtomic(string path, string content)
{
    var dir = Path.GetDirectoryName(path);
    if (!string.IsNullOrEmpty(dir))
    {
        Directory.CreateDirectory(dir);
    }

    var tmp = path + ".tmp";
    File.WriteAllText(tmp, content, new UTF8Encoding(false));
    if (File.Exists(path))
    {
        File.Replace(tmp, path, null);
    }
    else
    {
        File.Move(tmp, path);
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

static Chunk GetOrCreateChunk(World world, int cx, int cy)
{
    var id = new ChunkId(cx, cy);
    if (world.Chunks.TryGetValue(id, out var chunk))
    {
        return chunk;
    }

    chunk = new Chunk
    {
        X = cx,
        Y = cy
    };
    world.Chunks[id] = chunk;
    return chunk;
}

static int FloorDiv(int value, int size)
{
    if (size <= 0)
    {
        return 0;
    }

    if (value >= 0)
    {
        return value / size;
    }

    return -(((-value - 1) / size) + 1);
}

readonly record struct PlayerPacket(string Id, string Name, float X, float Y);
readonly record struct ChunkRequest(int Cx, int Cy, int LastKnownVersion);
readonly record struct ChunkId(int X, int Y);

sealed record PlayerState(string Id, string Name, float X, float Y, DateTime LastSeenUtc);

sealed class ChunkPayload
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Size { get; set; }
    public int Version { get; set; }
    public int[] Tiles { get; set; } = Array.Empty<int>();
}

sealed class EditPayload
{
    public TileChange[] Changes { get; set; } = Array.Empty<TileChange>();
}

sealed class TileChange
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Tile { get; set; }
}

sealed class World
{
    public Dictionary<ChunkId, Chunk> Chunks { get; }

    public World(Dictionary<ChunkId, Chunk> chunks)
    {
        Chunks = chunks;
    }
}

sealed class Chunk
{
    public const int ChunkSize = 100;
    public const int TileCount = ChunkSize * ChunkSize;

    public int X { get; set; }
    public int Y { get; set; }
    public int Version { get; set; }
    public int[] Tiles { get; set; } = new int[TileCount];

    [JsonIgnore]
    public bool IsDirty { get; set; }

    public int GetTile(int localX, int localY)
    {
        if (localX < 0 || localY < 0 || localX >= ChunkSize || localY >= ChunkSize)
        {
            return 0;
        }

        var index = localY * ChunkSize + localX;
        if (index < 0 || index >= Tiles.Length)
        {
            return 0;
        }

        return Tiles[index];
    }

    public void SetTile(int localX, int localY, int value)
    {
        if (localX < 0 || localY < 0 || localX >= ChunkSize || localY >= ChunkSize)
        {
            return;
        }

        var index = localY * ChunkSize + localX;
        if (index < 0 || index >= Tiles.Length)
        {
            return;
        }

        Tiles[index] = value;
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

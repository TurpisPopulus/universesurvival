using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Buffers.Binary;

var port = 7777;
if (args.Length > 0 && int.TryParse(args[0], out var parsedPort))
{
    port = parsedPort;
}

const string SecurePrefix = "SEC1|";
const string SharedKeyBase64 = "vux6wYEw7jG+5bcgE3Y75s1RnwNy0OQ//EAUp7XNk2M=";
var sharedKey = LoadSharedKey();
var encKey = DeriveKey(sharedKey, 0x01);
var macKey = DeriveKey(sharedKey, 0x02);

var gate = new object();
var baseDir = AppContext.BaseDirectory;
var dataDir = Path.Combine(baseDir, "Data");
Directory.CreateDirectory(dataDir);
var playersPath = Path.Combine(dataDir, "players.json");
var accountsPath = Path.Combine(dataDir, "accounts.json");
var objectTypesPath = Path.Combine(baseDir, "object_types.json");
var resourceTypesPath = Path.Combine(baseDir, "resource_types.json");
var players = LoadPlayers(playersPath);
var accounts = LoadAccounts(accountsPath);
var objectTypes = LoadObjectTypes(objectTypesPath);
var resourceTypes = LoadResourceTypes(resourceTypesPath);
var world = LoadWorld(dataDir);
var objectWorld = LoadObjectWorld(dataDir);
var resourceWorld = LoadResourceWorld(dataDir);
var endpoints = new Dictionary<string, IPEndPoint>(StringComparer.Ordinal);
var activeWindow = TimeSpan.FromSeconds(10);
var chunkSaveInterval = TimeSpan.FromSeconds(30);
var logInterval = TimeSpan.FromSeconds(1);
var lastLogByPlayer = new Dictionary<string, DateTime>(StringComparer.Ordinal);
var broadcastInterval = TimeSpan.FromMilliseconds(33);

if (NormalizeAccounts(accounts))
{
    SaveAccounts(accountsPath, accounts, gate);
}

void SaveAll()
{
    SavePlayers(playersPath, players, gate);
    SaveAccounts(accountsPath, accounts, gate);
    SaveDirtyChunks(dataDir, world, gate);
    SaveDirtyObjectChunks(dataDir, objectWorld, gate);
    SaveDirtyResourceChunks(dataDir, resourceWorld, gate);
}

using var udp = new UdpClient(port);
Console.WriteLine($"UDP server listening on 0.0.0.0:{port}");
Console.WriteLine("Payload format: SEC1|base64(version+nonce+ciphertext+mac)");
Console.WriteLine($"World loaded: {world.Chunks.Count} chunks");
Console.WriteLine($"Objects loaded: {objectWorld.Chunks.Count} chunks");
Console.WriteLine($"Resources loaded: {resourceWorld.Chunks.Count} chunks");
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
            SaveDirtyObjectChunks(dataDir, objectWorld, gate);
            SaveDirtyResourceChunks(dataDir, resourceWorld, gate);
        }
    }
    catch (OperationCanceledException)
    {
    }
});

using var broadcastTimer = new PeriodicTimer(broadcastInterval);
Task<UdpReceiveResult>? receiveTask = null;
Task<bool>? tickTask = null;

while (!cts.IsCancellationRequested)
{
    if (receiveTask == null)
    {
        receiveTask = udp.ReceiveAsync(cts.Token).AsTask();
    }

    if (tickTask == null)
    {
        tickTask = broadcastTimer.WaitForNextTickAsync(cts.Token).AsTask();
    }

    var completed = await Task.WhenAny(receiveTask, tickTask);
    if (completed == tickTask)
    {
        try
        {
            if (!await tickTask)
            {
                break;
            }
        }
        catch (OperationCanceledException)
        {
            break;
        }
        finally
        {
            tickTask = null;
        }

        List<PlayerState> snapshot;
        List<IPEndPoint> targets;
        var now = DateTime.UtcNow;
        lock (gate)
        {
            var staleNames = players.Values
                .Where(player => now - player.LastSeenUtc > activeWindow)
                .Select(player => player.Name)
                .Distinct()
                .ToList();
            foreach (var staleName in staleNames)
            {
                endpoints.Remove(staleName);
                lastLogByPlayer.Remove(staleName);
            }

            snapshot = players.Values
                .Where(player => now - player.LastSeenUtc <= activeWindow)
                .Where(player => !string.Equals(player.Id, "login", StringComparison.Ordinal))
                .ToList();
            targets = endpoints.Values.ToList();
        }

        if (targets.Count > 0)
        {
            var response = EncryptMessage(BuildBroadcast(snapshot), encKey, macKey);
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

        continue;
    }

    UdpReceiveResult result;
    try
    {
        result = await receiveTask;
        receiveTask = null;
    }
    catch (OperationCanceledException)
    {
        break;
    }
    catch (Exception ex)
    {
        if (ex is SocketException socketEx && socketEx.SocketErrorCode == SocketError.ConnectionReset)
        {
            receiveTask = null;
            continue;
        }
        Console.WriteLine($"Receive error: {ex.Message}");
        receiveTask = null;
        continue;
    }

    var message = Encoding.UTF8.GetString(result.Buffer);
    if (!TryDecryptSecureMessage(message, encKey, macKey, out var decrypted, out var decryptError))
    {
        Console.WriteLine($"Rejected packet from {result.RemoteEndPoint}: {decryptError}");
        continue;
    }
    message = decrypted;
    if (message.Equals("PING", StringComparison.Ordinal))
    {
        await SendToAsync(udp, "PONG", result.RemoteEndPoint, encKey, macKey);
        continue;
    }

    if (TryParseRegister(message, out var registerName, out var registerPassword, out var registerAppearance, out var registerError))
    {
        if (registerError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + registerError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        var created = false;
        lock (gate)
        {
            if (!accounts.ContainsKey(registerName))
            {
                accounts[registerName] = CreateAccount(registerName, registerPassword, registerAppearance);
                created = true;
            }
        }

        if (!created)
        {
            await SendToAsync(udp, "ERR|exists", result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        SaveAccounts(accountsPath, accounts, gate);
        await SendToAsync(udp, "OK", result.RemoteEndPoint, encKey, macKey);
        continue;
    }

    if (TryParseLogin(message, out var loginName, out var loginPassword, out var loginError))
    {
        if (loginError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + loginError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        if (!TryValidateLogin(loginName, loginPassword, accounts, gate, out var loginReply, out var upgraded))
        {
            await SendToAsync(udp, "ERR|" + loginReply, result.RemoteEndPoint, encKey, macKey);
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
            var appearance = GetAppearance(loginName, accounts, gate);
            var state = players.TryGetValue(loginName, out var existing)
                ? existing with { Id = "login", LastSeenUtc = now, Appearance = appearance }
                : new PlayerState("login", loginName, 0, 0, now, appearance);
                spawnX = state.X;
                spawnY = state.Y;
                players[loginName] = state;
                endpoints[loginName] = result.RemoteEndPoint;
            }
        }

        var accessLevel = GetAccessLevel(loginName, accounts, gate);
        var appearancePayload = GetAppearance(loginName, accounts, gate);
        var reply = nameTaken
            ? "ERR|name_taken"
            : BuildLoginReply(spawnX, spawnY, accessLevel, appearancePayload);
        await SendToAsync(udp, reply, result.RemoteEndPoint, encKey, macKey);
        continue;
    }

    if (TryParseChunkRequest(message, out var chunkRequest, out var chunkError))
    {
        if (chunkError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + chunkError, result.RemoteEndPoint, encKey, macKey);
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
            await SendToAsync(udp, chunkResponse, result.RemoteEndPoint, encKey, macKey);
        }
        continue;
    }

    if (TryParseObjectsRequest(message, out var objectsRequest, out var objectsError))
    {
        if (objectsError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + objectsError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        string? objectsResponse = null;
        lock (gate)
        {
            var chunk = GetOrCreateObjectChunk(objectWorld, objectsRequest.Cx, objectsRequest.Cy);
            if (objectsRequest.LastKnownVersion < 0 || chunk.Version > objectsRequest.LastKnownVersion)
            {
                objectsResponse = BuildObjectsResponse(chunk);
            }
        }
        if (objectsResponse != null)
        {
            await SendToAsync(udp, objectsResponse, result.RemoteEndPoint, encKey, macKey);
        }
        continue;
    }

    if (TryParseResourcesRequest(message, out var resourcesRequest, out var resourcesError))
    {
        if (resourcesError.Length != 0)
        {
            await SendToAsync(udp, "ERR|" + resourcesError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        string? resourcesResponse = null;
        lock (gate)
        {
            var chunk = GetOrCreateResourceChunk(resourceWorld, resourcesRequest.Cx, resourcesRequest.Cy);
            if (resourcesRequest.LastKnownVersion < 0 || chunk.Version > resourcesRequest.LastKnownVersion)
            {
                resourcesResponse = BuildResourcesResponse(chunk);
            }
        }
        if (resourcesResponse != null)
        {
            await SendToAsync(udp, resourcesResponse, result.RemoteEndPoint, encKey, macKey);
        }
        continue;
    }

    if (TryParseEdit(message, out var editPayload, out var editError))
    {
        if (editError.Length != 0)
        {
            Console.WriteLine($"Edit rejected from {result.RemoteEndPoint}: {editError}");
            await SendToAsync(udp, "ERR|" + editError, result.RemoteEndPoint, encKey, macKey);
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

    if (TryParseObjectEdit(message, out var objectEditPayload, out var objectEditError))
    {
        if (objectEditError.Length != 0)
        {
            Console.WriteLine($"Object edit rejected from {result.RemoteEndPoint}: {objectEditError}");
            await SendToAsync(udp, "ERR|" + objectEditError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        var appliedCount = 0;
        lock (gate)
        {
            appliedCount = ApplyObjectEdits(objectWorld, objectEditPayload, objectTypes);
        }
        Console.WriteLine($"[OBJECT_EDIT] applied changes={appliedCount} from {result.RemoteEndPoint}");
        continue;
    }

    if (TryParseResourceEdit(message, out var resourceEditPayload, out var resourceEditError))
    {
        if (resourceEditError.Length != 0)
        {
            Console.WriteLine($"Resource edit rejected from {result.RemoteEndPoint}: {resourceEditError}");
            await SendToAsync(udp, "ERR|" + resourceEditError, result.RemoteEndPoint, encKey, macKey);
            continue;
        }

        var appliedCount = 0;
        lock (gate)
        {
            appliedCount = ApplyResourceEdits(resourceWorld, resourceEditPayload, resourceTypes);
        }
        Console.WriteLine($"[RESOURCE_EDIT] applied changes={appliedCount} from {result.RemoteEndPoint}");
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
        await SendToAsync(udp, "ERR|name_taken", result.RemoteEndPoint, encKey, macKey);
        continue;
    }

    lock (gate)
    {
        var appearance = payload.Appearance;
        if (players.TryGetValue(payload.Name, out var existing))
        {
            if (string.IsNullOrWhiteSpace(appearance))
            {
                appearance = existing.Appearance;
            }
        }
        players[payload.Name] = new PlayerState(
            payload.Id,
            payload.Name,
            payload.X,
            payload.Y,
            timestamp,
            appearance
        );
        endpoints[payload.Name] = result.RemoteEndPoint;
    }

    if (!string.IsNullOrWhiteSpace(payload.Appearance))
    {
        var updated = false;
        lock (gate)
        {
            if (accounts.TryGetValue(payload.Name, out var account))
            {
                if (!string.Equals(account.Appearance, payload.Appearance, StringComparison.Ordinal))
                {
                    account.Appearance = payload.Appearance;
                    updated = true;
                }
            }
        }
        if (updated)
        {
            SaveAccounts(accountsPath, accounts, gate);
        }
    }

    var shouldLog = true;
    if (logInterval > TimeSpan.Zero)
    {
        if (lastLogByPlayer.TryGetValue(payload.Name, out var lastLog) &&
            timestamp - lastLog < logInterval)
        {
            shouldLog = false;
        }
        else
        {
            lastLogByPlayer[payload.Name] = timestamp;
        }
    }

    if (shouldLog)
    {
        Console.WriteLine(
            $"From {result.RemoteEndPoint}: id={payload.Id}, name={payload.Name}, " +
            $"x={payload.X.ToString("0.###", CultureInfo.InvariantCulture)}, " +
            $"y={payload.Y.ToString("0.###", CultureInfo.InvariantCulture)}"
        );
    }

    // Broadcasts are handled by the periodic timer to keep a steady tick.
}

SaveAll();
await saveTask;
await chunkSaveTask;

static bool TryParseRegister(string payload, out string name, out string password, out string appearance, out string error)
{
    name = string.Empty;
    password = string.Empty;
    appearance = string.Empty;
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
    if (parts.Length >= 4)
    {
        appearance = parts[3].Trim();
    }
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
    if (parts.Length < 4)
    {
        error = "expected 4 fields: id|name|x|y (appearance optional)";
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

    var appearance = parts.Length >= 5 ? parts[4].Trim() : string.Empty;
    packet = new PlayerPacket(id, name, x, y, appearance);
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

static bool TryParseObjectsRequest(string payload, out ObjectsRequest request, out string error)
{
    request = default;
    error = string.Empty;

    if (!payload.StartsWith("OBJECTS|", StringComparison.Ordinal))
    {
        return false;
    }

    var parts = payload.Split('|');
    if (parts.Length < 4)
    {
        error = "bad_objects";
        return true;
    }

    if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cx) ||
        !int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cy) ||
        !int.TryParse(parts[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out var lastKnownVersion))
    {
        error = "bad_objects";
        return true;
    }

    request = new ObjectsRequest(cx, cy, lastKnownVersion);
    return true;
}

static bool TryParseResourcesRequest(string payload, out ResourcesRequest request, out string error)
{
    request = default;
    error = string.Empty;

    if (!payload.StartsWith("RESOURCES|", StringComparison.Ordinal))
    {
        return false;
    }

    var parts = payload.Split('|');
    if (parts.Length < 4)
    {
        error = "bad_resources";
        return true;
    }

    if (!int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cx) ||
        !int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var cy) ||
        !int.TryParse(parts[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out var lastKnownVersion))
    {
        error = "bad_resources";
        return true;
    }

    request = new ResourcesRequest(cx, cy, lastKnownVersion);
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

static bool TryParseObjectEdit(string payload, out ObjectEditPayload update, out string error)
{
    update = new ObjectEditPayload();
    error = string.Empty;

    if (!payload.StartsWith("OBJECT_EDIT|", StringComparison.Ordinal))
    {
        return false;
    }

    var json = payload.Substring("OBJECT_EDIT|".Length);
    if (string.IsNullOrWhiteSpace(json))
    {
        error = "bad_object_edit";
        return true;
    }

    try
    {
        update = JsonSerializer.Deserialize<ObjectEditPayload>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new ObjectEditPayload();
    }
    catch (Exception)
    {
        error = "bad_object_edit";
        return true;
    }

    if (update.Changes == null || update.Changes.Length == 0)
    {
        error = "bad_object_edit";
    }

    return true;
}

static bool TryParseResourceEdit(string payload, out ResourceEditPayload update, out string error)
{
    update = new ResourceEditPayload();
    error = string.Empty;

    if (!payload.StartsWith("RESOURCE_EDIT|", StringComparison.Ordinal))
    {
        return false;
    }

    var json = payload.Substring("RESOURCE_EDIT|".Length);
    if (string.IsNullOrWhiteSpace(json))
    {
        error = "bad_resource_edit";
        return true;
    }

    try
    {
        update = JsonSerializer.Deserialize<ResourceEditPayload>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? new ResourceEditPayload();
    }
    catch (Exception)
    {
        error = "bad_resource_edit";
        return true;
    }

    if (update.Changes == null || update.Changes.Length == 0)
    {
        error = "bad_resource_edit";
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

static int ApplyObjectEdits(ObjectWorld world, ObjectEditPayload update, Dictionary<string, ObjectType> objectTypes)
{
    if (update.Changes == null || update.Changes.Length == 0)
    {
        return 0;
    }

    var applied = 0;
    foreach (var change in update.Changes)
    {
        if (string.Equals(change.TypeId, "__remove__", StringComparison.OrdinalIgnoreCase))
        {
            var removeCx = FloorDiv(change.X, Chunk.ChunkSize);
            var removeCy = FloorDiv(change.Y, Chunk.ChunkSize);
            var removeChunk = GetOrCreateObjectChunk(world, removeCx, removeCy);
            var removed = removeChunk.Objects.RemoveAll(obj => obj.X == change.X && obj.Y == change.Y);
            if (removed > 0)
            {
                removeChunk.Version++;
                removeChunk.IsDirty = true;
                applied += removed;
            }
            continue;
        }

        if (string.IsNullOrWhiteSpace(change.TypeId))
        {
            continue;
        }

        if (!objectTypes.TryGetValue(change.TypeId, out var type))
        {
            continue;
        }

        var rotation = Math.Clamp(change.Rotation, 0, 3);
        var cx = FloorDiv(change.X, Chunk.ChunkSize);
        var cy = FloorDiv(change.Y, Chunk.ChunkSize);

        var chunk = GetOrCreateObjectChunk(world, cx, cy);
        var existing = chunk.Objects.FirstOrDefault(obj => obj.X == change.X && obj.Y == change.Y);
        if (existing != null)
        {
            existing.TypeId = change.TypeId;
            existing.Rotation = rotation;
            existing.IsBlocking = type.IsBlocking;
            existing.UpdatedUtc = DateTime.UtcNow;
        }
        else
        {
            chunk.Objects.Add(new ObjectEntry
            {
                EntityId = Guid.NewGuid().ToString("N"),
                TypeId = change.TypeId,
                X = change.X,
                Y = change.Y,
                Rotation = rotation,
                IsBlocking = type.IsBlocking,
                CreatedUtc = DateTime.UtcNow,
                UpdatedUtc = DateTime.UtcNow
            });
        }

        chunk.Version++;
        chunk.IsDirty = true;
        applied++;
    }

    return applied;
}

static int ApplyResourceEdits(ResourceWorld world, ResourceEditPayload update, Dictionary<string, ResourceType> resourceTypes)
{
    if (update.Changes == null || update.Changes.Length == 0)
    {
        return 0;
    }

    var applied = 0;
    foreach (var change in update.Changes)
    {
        if (string.Equals(change.TypeId, "__remove__", StringComparison.OrdinalIgnoreCase))
        {
            var removeCx = FloorDiv(change.X, Chunk.ChunkSize);
            var removeCy = FloorDiv(change.Y, Chunk.ChunkSize);
            var removeChunk = GetOrCreateResourceChunk(world, removeCx, removeCy);
            var removed = removeChunk.Resources.RemoveAll(res => res.X == change.X && res.Y == change.Y);
            if (removed > 0)
            {
                removeChunk.Version++;
                removeChunk.IsDirty = true;
                applied += removed;
            }
            continue;
        }

        if (string.IsNullOrWhiteSpace(change.TypeId))
        {
            continue;
        }

        if (!resourceTypes.TryGetValue(change.TypeId, out var type))
        {
            continue;
        }

        var cx = FloorDiv(change.X, Chunk.ChunkSize);
        var cy = FloorDiv(change.Y, Chunk.ChunkSize);
        var chunk = GetOrCreateResourceChunk(world, cx, cy);
        var existing = chunk.Resources.FirstOrDefault(res => res.X == change.X && res.Y == change.Y);
        if (existing != null)
        {
            existing.TypeId = change.TypeId;
            existing.Amount = type.MaxAmount;
            existing.UpdatedUtc = DateTime.UtcNow;
        }
        else
        {
            chunk.Resources.Add(new ResourceEntry
            {
                EntityId = Guid.NewGuid().ToString("N"),
                TypeId = change.TypeId,
                X = change.X,
                Y = change.Y,
                Amount = type.MaxAmount,
                CreatedUtc = DateTime.UtcNow,
                UpdatedUtc = DateTime.UtcNow
            });
        }

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
        $"{player.Id}|{player.Name}|{player.X.ToString("0.###", CultureInfo.InvariantCulture)}|{player.Y.ToString("0.###", CultureInfo.InvariantCulture)}|{player.Appearance}"
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

static string BuildObjectsResponse(ObjectChunk chunk)
{
    var payload = new ObjectChunkPayload
    {
        X = chunk.X,
        Y = chunk.Y,
        Version = chunk.Version,
        Objects = chunk.Objects
    };

    return JsonSerializer.Serialize(payload, new JsonSerializerOptions
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    });
}

static string BuildResourcesResponse(ResourceChunk chunk)
{
    var payload = new ResourceChunkPayload
    {
        X = chunk.X,
        Y = chunk.Y,
        Version = chunk.Version,
        Resources = chunk.Resources
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

static Dictionary<string, ObjectType> LoadObjectTypes(string path)
{
    try
    {
        if (!File.Exists(path))
        {
            var defaults = new ObjectTypeCatalog
            {
                Types = new List<ObjectType>
                {
                    new()
                    {
                        TypeId = "wall_wood",
                        DisplayName = "Wood Wall",
                        IsBlocking = true
                    },
                    new()
                    {
                        TypeId = "wall_stone",
                        DisplayName = "Stone Wall",
                        IsBlocking = true
                    }
                }
            };
            var json = JsonSerializer.Serialize(defaults, new JsonSerializerOptions
            {
                WriteIndented = true
            });
            WriteAllTextAtomic(path, json);
            return defaults.Types.ToDictionary(item => item.TypeId, StringComparer.OrdinalIgnoreCase);
        }

        var text = File.ReadAllText(path, Encoding.UTF8);
        var catalog = JsonSerializer.Deserialize<ObjectTypeCatalog>(text, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (catalog?.Types == null)
        {
            return new Dictionary<string, ObjectType>(StringComparer.OrdinalIgnoreCase);
        }

        return catalog.Types
            .Where(item => !string.IsNullOrWhiteSpace(item.TypeId))
            .ToDictionary(item => item.TypeId, StringComparer.OrdinalIgnoreCase);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Object types load error: {ex.Message}");
        return new Dictionary<string, ObjectType>(StringComparer.OrdinalIgnoreCase);
    }
}

static Dictionary<string, ResourceType> LoadResourceTypes(string path)
{
    try
    {
        if (!File.Exists(path))
        {
            var defaults = new ResourceTypeCatalog
            {
                Types = new List<ResourceType>
                {
                    new()
                    {
                        TypeId = "tree_oak",
                        DisplayName = "Oak Tree",
                        MaxAmount = 8,
                        GatherTool = "axe",
                        Drops = new List<ResourceDrop>
                        {
                            new() { ItemId = "wood_log", Min = 2, Max = 4 }
                        }
                    },
                    new()
                    {
                        TypeId = "tree_pine",
                        DisplayName = "Pine Tree",
                        MaxAmount = 10,
                        GatherTool = "axe",
                        Drops = new List<ResourceDrop>
                        {
                            new() { ItemId = "wood_log", Min = 3, Max = 5 },
                            new() { ItemId = "apple", Min = 0, Max = 1 }
                        }
                    }
                }
            };
            var json = JsonSerializer.Serialize(defaults, new JsonSerializerOptions
            {
                WriteIndented = true
            });
            WriteAllTextAtomic(path, json);
            return defaults.Types.ToDictionary(item => item.TypeId, StringComparer.OrdinalIgnoreCase);
        }

        var text = File.ReadAllText(path, Encoding.UTF8);
        var catalog = JsonSerializer.Deserialize<ResourceTypeCatalog>(text, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (catalog?.Types == null)
        {
            return new Dictionary<string, ResourceType>(StringComparer.OrdinalIgnoreCase);
        }

        return catalog.Types
            .Where(item => !string.IsNullOrWhiteSpace(item.TypeId))
            .ToDictionary(item => item.TypeId, StringComparer.OrdinalIgnoreCase);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Resource types load error: {ex.Message}");
        return new Dictionary<string, ResourceType>(StringComparer.OrdinalIgnoreCase);
    }
}

static ObjectWorld LoadObjectWorld(string dataDir)
{
    var chunks = new Dictionary<ChunkId, ObjectChunk>();
    try
    {
        foreach (var path in Directory.EnumerateFiles(dataDir, "objects_*.json"))
        {
            var chunk = LoadObjectChunk(path);
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
        Console.WriteLine($"Object world load error: {ex.Message}");
    }

    return new ObjectWorld(chunks);
}

static ResourceWorld LoadResourceWorld(string dataDir)
{
    var chunks = new Dictionary<ChunkId, ResourceChunk>();
    try
    {
        foreach (var path in Directory.EnumerateFiles(dataDir, "resources_*.json"))
        {
            var chunk = LoadResourceChunk(path);
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
        Console.WriteLine($"Resource world load error: {ex.Message}");
    }

    return new ResourceWorld(chunks);
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

static ObjectChunk? LoadObjectChunk(string path)
{
    try
    {
        var json = File.ReadAllText(path, Encoding.UTF8);
        var chunk = JsonSerializer.Deserialize<ObjectChunk>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (chunk == null)
        {
            return null;
        }

        chunk.Objects ??= new List<ObjectEntry>();
        chunk.IsDirty = false;
        return chunk;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Object chunk load error ({Path.GetFileName(path)}): {ex.Message}");
        return null;
    }
}

static ResourceChunk? LoadResourceChunk(string path)
{
    try
    {
        var json = File.ReadAllText(path, Encoding.UTF8);
        var chunk = JsonSerializer.Deserialize<ResourceChunk>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
        if (chunk == null)
        {
            return null;
        }

        chunk.Resources ??= new List<ResourceEntry>();
        chunk.IsDirty = false;
        return chunk;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Resource chunk load error ({Path.GetFileName(path)}): {ex.Message}");
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

static void SaveDirtyObjectChunks(string dataDir, ObjectWorld world, object gate)
{
    List<(ObjectChunk chunk, int version)> dirty;
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
            var path = Path.Combine(dataDir, $"objects_{chunk.X}_{chunk.Y}.json");
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
            Console.WriteLine($"Object chunk save error ({chunk.X},{chunk.Y}): {ex.Message}");
        }
    }
}

static void SaveDirtyResourceChunks(string dataDir, ResourceWorld world, object gate)
{
    List<(ResourceChunk chunk, int version)> dirty;
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
            var path = Path.Combine(dataDir, $"resources_{chunk.X}_{chunk.Y}.json");
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
            Console.WriteLine($"Resource chunk save error ({chunk.X},{chunk.Y}): {ex.Message}");
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

static Account CreateAccount(string name, string password, string appearance)
{
    var salt = RandomNumberGenerator.GetBytes(16);
    var hash = HashPassword(password, salt);
    return new Account
    {
        Name = name,
        PasswordHash = Convert.ToBase64String(hash),
        Salt = Convert.ToBase64String(salt),
        Password = string.Empty,
        AccessLevel = 5,
        Appearance = appearance
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

static async Task SendToAsync(UdpClient udp, string message, IPEndPoint endpoint, byte[] encKey, byte[] macKey)
{
    var secured = EncryptMessage(message, encKey, macKey);
    var bytes = Encoding.UTF8.GetBytes(secured);
    try
    {
        await udp.SendAsync(bytes, bytes.Length, endpoint);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Send error: {ex.Message}");
    }
}

static byte[] LoadSharedKey()
{
    var keyBase64 = Environment.GetEnvironmentVariable("UNIVERSE_NET_KEY");
    if (string.IsNullOrWhiteSpace(keyBase64))
    {
        keyBase64 = SharedKeyBase64;
    }

    try
    {
        var key = Convert.FromBase64String(keyBase64);
        if (key.Length != 32)
        {
            throw new InvalidOperationException("Shared key must be 32 bytes (base64).");
        }
        return key;
    }
    catch (FormatException ex)
    {
        throw new InvalidOperationException("Shared key must be valid base64.", ex);
    }
}

static byte[] DeriveKey(byte[] masterKey, byte tag)
{
    var tagged = new byte[1 + masterKey.Length];
    tagged[0] = tag;
    Buffer.BlockCopy(masterKey, 0, tagged, 1, masterKey.Length);
    return SHA256.HashData(tagged);
}

static bool TryDecryptSecureMessage(string payload, byte[] encKey, byte[] macKey, out string message, out string error)
{
    message = string.Empty;
    error = string.Empty;
    if (!payload.StartsWith(SecurePrefix, StringComparison.Ordinal))
    {
        error = "missing_secure_prefix";
        return false;
    }

    var base64 = payload[SecurePrefix.Length..];
    byte[] data;
    try
    {
        data = Convert.FromBase64String(base64);
    }
    catch (FormatException)
    {
        error = "invalid_base64";
        return false;
    }

    if (data.Length < 1 + 16 + 32)
    {
        error = "payload_too_short";
        return false;
    }

    var version = data[0];
    if (version != 1)
    {
        error = "unsupported_version";
        return false;
    }

    var macStart = data.Length - 32;
    var signed = new byte[macStart];
    Buffer.BlockCopy(data, 0, signed, 0, macStart);
    var mac = new byte[32];
    Buffer.BlockCopy(data, macStart, mac, 0, 32);

    using var hmac = new HMACSHA256(macKey);
    var expected = hmac.ComputeHash(signed);
    if (!CryptographicOperations.FixedTimeEquals(mac, expected))
    {
        error = "bad_mac";
        return false;
    }

    var nonce = new byte[16];
    Buffer.BlockCopy(data, 1, nonce, 0, 16);
    var cipherLen = macStart - 1 - 16;
    var cipher = new byte[cipherLen];
    Buffer.BlockCopy(data, 17, cipher, 0, cipherLen);
    var plain = AesCtrTransform(encKey, nonce, cipher);
    message = Encoding.UTF8.GetString(plain);
    return true;
}

static string EncryptMessage(string message, byte[] encKey, byte[] macKey)
{
    var nonce = RandomNumberGenerator.GetBytes(16);
    var plain = Encoding.UTF8.GetBytes(message);
    var cipher = AesCtrTransform(encKey, nonce, plain);
    var signed = new byte[1 + nonce.Length + cipher.Length];
    signed[0] = 1;
    Buffer.BlockCopy(nonce, 0, signed, 1, nonce.Length);
    Buffer.BlockCopy(cipher, 0, signed, 1 + nonce.Length, cipher.Length);
    using var hmac = new HMACSHA256(macKey);
    var mac = hmac.ComputeHash(signed);
    var payload = new byte[signed.Length + mac.Length];
    Buffer.BlockCopy(signed, 0, payload, 0, signed.Length);
    Buffer.BlockCopy(mac, 0, payload, signed.Length, mac.Length);
    return SecurePrefix + Convert.ToBase64String(payload);
}

static byte[] AesCtrTransform(byte[] key, byte[] nonce, byte[] input)
{
    var output = new byte[input.Length];
    ulong counter = 0;
    var offset = 0;
    while (offset < input.Length)
    {
        var keystream = BuildKeystreamBlock(key, nonce, counter);
        var chunk = Math.Min(keystream.Length, input.Length - offset);
        for (var i = 0; i < chunk; i++)
        {
            output[offset + i] = (byte)(input[offset + i] ^ keystream[i]);
        }
        offset += chunk;
        counter++;
    }
    return output;
}

static byte[] BuildKeystreamBlock(byte[] key, byte[] nonce, ulong counter)
{
    var counterBytes = new byte[8];
    BinaryPrimitives.WriteUInt64BigEndian(counterBytes, counter);
    var data = new byte[nonce.Length + counterBytes.Length];
    Buffer.BlockCopy(nonce, 0, data, 0, nonce.Length);
    Buffer.BlockCopy(counterBytes, 0, data, nonce.Length, counterBytes.Length);
    using var hmac = new HMACSHA256(key);
    return hmac.ComputeHash(data);
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

static ObjectChunk GetOrCreateObjectChunk(ObjectWorld world, int cx, int cy)
{
    var id = new ChunkId(cx, cy);
    if (world.Chunks.TryGetValue(id, out var chunk))
    {
        return chunk;
    }

    chunk = new ObjectChunk
    {
        X = cx,
        Y = cy
    };
    world.Chunks[id] = chunk;
    return chunk;
}

static ResourceChunk GetOrCreateResourceChunk(ResourceWorld world, int cx, int cy)
{
    var id = new ChunkId(cx, cy);
    if (world.Chunks.TryGetValue(id, out var chunk))
    {
        return chunk;
    }

    chunk = new ResourceChunk
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

static string GetAppearance(string name, Dictionary<string, Account> accounts, object gate)
{
    lock (gate)
    {
        if (accounts.TryGetValue(name, out var account))
        {
            return account.Appearance ?? string.Empty;
        }
    }

    return string.Empty;
}

static string BuildLoginReply(float x, float y, int accessLevel, string appearance)
{
    var reply = $"OK|{x.ToString("0.###", CultureInfo.InvariantCulture)}|{y.ToString("0.###", CultureInfo.InvariantCulture)}|{accessLevel}";
    if (!string.IsNullOrWhiteSpace(appearance))
    {
        reply += "|" + appearance;
    }

    return reply;
}

readonly record struct PlayerPacket(string Id, string Name, float X, float Y, string Appearance);
readonly record struct ChunkRequest(int Cx, int Cy, int LastKnownVersion);
readonly record struct ObjectsRequest(int Cx, int Cy, int LastKnownVersion);
readonly record struct ResourcesRequest(int Cx, int Cy, int LastKnownVersion);
readonly record struct ChunkId(int X, int Y);

sealed record PlayerState(string Id, string Name, float X, float Y, DateTime LastSeenUtc, string Appearance = "");

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

sealed class ObjectEditPayload
{
    public ObjectChange[] Changes { get; set; } = Array.Empty<ObjectChange>();
}

sealed class ResourceEditPayload
{
    public ResourceChange[] Changes { get; set; } = Array.Empty<ResourceChange>();
}

sealed class TileChange
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Tile { get; set; }
}

sealed class ObjectChange
{
    public int X { get; set; }
    public int Y { get; set; }
    public string TypeId { get; set; } = string.Empty;
    public int Rotation { get; set; }
}

sealed class ResourceChange
{
    public int X { get; set; }
    public int Y { get; set; }
    public string TypeId { get; set; } = string.Empty;
}

sealed class World
{
    public Dictionary<ChunkId, Chunk> Chunks { get; }

    public World(Dictionary<ChunkId, Chunk> chunks)
    {
        Chunks = chunks;
    }
}

sealed class ObjectWorld
{
    public Dictionary<ChunkId, ObjectChunk> Chunks { get; }

    public ObjectWorld(Dictionary<ChunkId, ObjectChunk> chunks)
    {
        Chunks = chunks;
    }
}

sealed class ResourceWorld
{
    public Dictionary<ChunkId, ResourceChunk> Chunks { get; }

    public ResourceWorld(Dictionary<ChunkId, ResourceChunk> chunks)
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

sealed class ObjectChunkPayload
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Version { get; set; }
    public List<ObjectEntry> Objects { get; set; } = new();
}

sealed class ResourceChunkPayload
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Version { get; set; }
    public List<ResourceEntry> Resources { get; set; } = new();
}

sealed class ObjectChunk
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Version { get; set; }
    public List<ObjectEntry> Objects { get; set; } = new();

    [JsonIgnore]
    public bool IsDirty { get; set; }
}

sealed class ResourceChunk
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Version { get; set; }
    public List<ResourceEntry> Resources { get; set; } = new();

    [JsonIgnore]
    public bool IsDirty { get; set; }
}

sealed class ObjectEntry
{
    public string EntityId { get; set; } = string.Empty;
    public string TypeId { get; set; } = string.Empty;
    public int X { get; set; }
    public int Y { get; set; }
    public int Rotation { get; set; }
    public bool IsBlocking { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime UpdatedUtc { get; set; }
}

sealed class ResourceEntry
{
    public string EntityId { get; set; } = string.Empty;
    public string TypeId { get; set; } = string.Empty;
    public int X { get; set; }
    public int Y { get; set; }
    public int Amount { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime UpdatedUtc { get; set; }
}

sealed class ObjectType
{
    public string TypeId { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public bool IsBlocking { get; init; }
}

sealed class ObjectTypeCatalog
{
    public List<ObjectType> Types { get; set; } = new();
}

sealed class ResourceType
{
    public string TypeId { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public int MaxAmount { get; init; } = 1;
    public string GatherTool { get; init; } = string.Empty;
    public List<ResourceDrop> Drops { get; init; } = new();
}

sealed class ResourceDrop
{
    public string ItemId { get; init; } = string.Empty;
    public int Min { get; init; }
    public int Max { get; init; }
}

sealed class ResourceTypeCatalog
{
    public List<ResourceType> Types { get; set; } = new();
}

sealed class Account
{
    public string Name { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public string Salt { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public int AccessLevel { get; set; }
    public string Appearance { get; set; } = string.Empty;
}

-- rig/Registry: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, Maid, RigCache)
    local Players=ctx.services.Players
    local RunService=ctx.services.RunService
    local Workspace=ctx.services.Workspace
    local LocalPlayer=ctx.localPlayer
    local CharacterRegistry = {}

    -- Internal cache: [charInstance] = { player, isNPC, name, teamName }
    local _chars = {}
    local _crEventMaid      = Maid.new()
    local _containerMaid    = Maid.new()
    local _playerMaids      = setmetatable({}, { __mode = "k" })
    local _watchedContainers= setmetatable({}, { __mode = "k" })
    local _containerWatchers= setmetatable({}, { __mode = "k" })

    local _pollDt    = 0
    local _resolveDt = 0
    local POLL_INTERVAL    = 0.25
    local RESOLVE_INTERVAL = 2.0

    local _running               = false
    local _generation            = 0
    local _humScanInProgress     = false
    local _humScanPending        = nil
    local _lastForceRescan       = 0
    local FORCE_RESCAN_THROTTLE  = 2.0
    local HUM_SCAN_MAX_INSTANCES = 20000
    local HUM_SCAN_YIELD_EVERY   = 400
    local _crCache   = {}
    local _crStamp   = {}

    -- Event callbacks: { onAdd = [], onRemove = [], onUpdate = [] }
    local _crCallbacks = { onAdd = {}, onRemove = {}, onUpdate = {} }

    local function _crEmit(event, char, data, reason)
        _crCache = {}
        _crStamp = {}
        for _, fn in ipairs(_crCallbacks[event] or {}) do
            local ok, err = pcall(fn, char, data, reason)
            if not ok then warn("[SwaX] CharacterRegistry callback failed:", err) end
        end
    end

    local function _subscribe(event, fn)
        if type(fn) ~= "function" then return function() end end
        local listeners = _crCallbacks[event]
        listeners[#listeners + 1] = fn
        local active = true
        return function()
            if not active then return end
            active = false
            for i = #listeners, 1, -1 do
                if listeners[i] == fn then
                    table.remove(listeners, i)
                    break
                end
            end
        end
    end

    function CharacterRegistry.OnAdd(fn)    return _subscribe("onAdd", fn) end
    function CharacterRegistry.OnRemove(fn) return _subscribe("onRemove", fn) end
    function CharacterRegistry.OnUpdate(fn) return _subscribe("onUpdate", fn) end

    local _getGeomCache=RigCache.Get
    local _destroyGeomCache=RigCache.Destroy

    -- One idempotent removal path prevents duplicate onRemove events and guarantees
    -- per-character connections/state are released together.
    local function _removeCharacter(char, reason)
        local data = _chars[char]
        if not data then return false end
        _chars[char] = nil
        if data.maid then data.maid:Clean() end
        _destroyGeomCache(char)
        _crEmit("onRemove", char, data, reason)
        return true
    end

    -- Identify local player's character (handles PF where .Character=nil)
    local function IsLocalChar(char)
        if not char then return false end
        if char == LocalPlayer.Character then return true end
        local sub = ctx.camera and ctx.camera.CameraSubject
        if sub then
            local ok, isDesc = pcall(function() return sub:IsDescendantOf(char) end)
            if ok and isDesc then return true end
            if sub == char then return true end
        end
        return false
    end

    CharacterRegistry.IsLocalChar = IsLocalChar

    -- Teammate detection (PF-native + standard Roblox fallback)
    local TEAMMATE_COLOR = Color3.fromRGB(0, 255, 234)
    local function IsTeammate(char)
        if not char then return false end
        local nameTagGui = char:FindFirstChild("NameTagGui", true)
        if nameTagGui then
            local playerTag = nameTagGui:FindFirstChild("PlayerTag")
            if playerTag then
                return playerTag.Visible == true and playerTag.TextColor3 == TEAMMATE_COLOR
            end
        end
        local data = _chars[char]
        if data and data.player then
            local theirTeam = data.player.Team
            local localTeam = LocalPlayer.Team
            return theirTeam ~= nil and localTeam ~= nil and theirTeam == localTeam
        end
        return false
    end

    CharacterRegistry.IsTeammate = IsTeammate

    -- Multi-strategy owner resolver
    local function ResolveOwner(char)
        local ok, p = pcall(function() return Players:GetPlayerFromCharacter(char) end)
        if ok and p then return p end
        local list = Players:GetPlayers()
        for _, pl in ipairs(list) do
            if pl.Character == char then return pl end
        end
        if char and char.Name then
            local cn = char.Name
            for _, pl in ipairs(list) do
                if pl.Name == cn then return pl end
            end
            local dm, dc = nil, 0
            for _, pl in ipairs(list) do
                if pl.DisplayName == cn then dm = pl; dc += 1 end
            end
            if dc == 1 then return dm end
        end
        return nil
    end

    -- Register or upgrade an entry
    local function _reg(char, player, isNPC, teamName)
        if not _running or not ctx.alive or not char then return end
        if IsLocalChar(char) then return end
        local inGame = false
        pcall(function() inGame = char:IsDescendantOf(game) end)
        if not inGame then return end
        local existing = _chars[char]
        if existing and not existing.isNPC and not player then return end
        local name = player and player.DisplayName
            or (existing and existing.name)
            or ("?" .. tostring(char.Name):sub(1, 8))
        local nextIsNPC = (player == nil) and (isNPC == true)
        local nextTeamName = teamName or (existing and existing.teamName) or ""
        if existing and existing.player == player and existing.isNPC == nextIsNPC
            and existing.name == name and existing.teamName == nextTeamName then
            return
        end
        local isNew = (existing == nil)
        local data = {
            player   = player,
            isNPC    = nextIsNPC,
            name     = name,
            teamName = nextTeamName,
            maid     = existing and existing.maid or Maid.new(),
        }
        _chars[char] = data
        if isNew then
            _crEmit("onAdd", char, data)
            pcall(function()
                data.maid:Give(char.AncestryChanged:Connect(function()
                    if not char:IsDescendantOf(game) then
                        _removeCharacter(char, "ancestry_removed")
                    end
                end))
            end)
        else
            _crEmit("onUpdate", char, data)
        end
    end

    local function _tryRegChar(char, teamName, forcePlayer)
        if not char then return end
        if IsLocalChar(char) then return end
        if not (char:IsA("Model") or char:IsA("Folder")) then return end
        local inGame = false
        pcall(function() inGame = char:IsDescendantOf(game) end)
        if not inGame then return end
        local owner = ResolveOwner(char)
        if owner then
            _reg(char, owner, false, teamName)
        elseif forcePlayer then
            _reg(char, nil, false, teamName)
        else
            local hasHum = char:FindFirstChildWhichIsA("Humanoid", true) ~= nil
            if hasHum then _reg(char, nil, true, teamName) end
        end
    end

    -- Container scanning
    local KNOWN_CONTAINERS = { players=true, characters=true, alive=true, teams=true, playermodels=true }

    local function _trackWatcher(obj, conn)
        if not obj or not conn then return conn end
        local list = _containerWatchers[obj]
        if not list then list = {}; _containerWatchers[obj] = list end
        list[#list + 1] = conn
        _containerMaid:Give(conn)
        return conn
    end

    local function _looksLikePlayerContainer(obj)
        if not (obj:IsA("Folder") or obj:IsA("Model")) then return false end
        if KNOWN_CONTAINERS[obj.Name:lower()] then return true end
        local count = 0
        for _, child in ipairs(obj:GetChildren()) do
            if child:IsA("Model") or child:IsA("Folder") then
                if child:FindFirstChildWhichIsA("Humanoid", true) then
                    count += 1
                    if count >= 2 then return true end
                end
            end
        end
        return false
    end

    local function _genOk(gen) return _running and ctx.alive and gen == _generation end

    local function _scanContainer(container, parentTeamName, isKnown, gen)
        if not _genOk(gen) or not container or not container:IsDescendantOf(Workspace) then return end
        if _watchedContainers[container] then return end
        _watchedContainers[container] = true
        local forcePlayer = isKnown or KNOWN_CONTAINERS[container.Name:lower()] or false
        local function _handleChild(child)
            if not _genOk(gen) then return end
            task.delay(0.05, function()
                if not _genOk(gen) then return end
                if not child or not child.Parent then return end
                if IsLocalChar(child) then return end
                if not (child:IsA("Model") or child:IsA("Folder")) then return end
                local owner = ResolveOwner(child)
                if owner then
                    _reg(child, owner, false, parentTeamName or container.Name)
                else
                    local hasHum = child:FindFirstChildWhichIsA("Humanoid", true) ~= nil
                    if hasHum then
                        _tryRegChar(child, parentTeamName or container.Name, forcePlayer)
                    elseif forcePlayer then
                        -- Team sub-folder — scan grandchildren
                        if not _watchedContainers[child] then
                            _watchedContainers[child] = true
                            for _, gc in ipairs(child:GetChildren()) do
                                task.delay(0.05, function()
                                    if not _genOk(gen) then return end
                                    _tryRegChar(gc, child.Name, true)
                                end)
                            end
                            pcall(function()
                                _trackWatcher(child, child.ChildAdded:Connect(function(gc)
                                    task.delay(0.05, function()
                                        if not _genOk(gen) then return end
                                        _tryRegChar(gc, child.Name, true)
                                    end)
                                end))
                                _trackWatcher(child, child.ChildRemoved:Connect(function(gc)
                                    if not _genOk(gen) then return end
                                    _removeCharacter(gc, "container_removed")
                                end))
                            end)
                        end
                    end
                end
            end)
        end
        for _, child in ipairs(container:GetChildren()) do _handleChild(child) end
        pcall(function()
            _trackWatcher(container, container.ChildAdded:Connect(function(child) _handleChild(child) end))
            _trackWatcher(container, container.ChildRemoved:Connect(function(child)
                if not _genOk(gen) then return end
                _removeCharacter(child, "container_removed")
            end))
        end)
    end

    local function _startWorkspaceWatcher(gen)
        if not _genOk(gen) then return end
        local function _tryContainer(obj)
            if _genOk(gen) and obj:IsDescendantOf(Workspace) and _looksLikePlayerContainer(obj) then
                local isKnown = KNOWN_CONTAINERS[obj.Name:lower()] == true
                task.spawn(_scanContainer, obj, nil, isKnown, gen)
            end
        end
        for _, obj in ipairs(Workspace:GetChildren()) do _tryContainer(obj) end
        _trackWatcher(Workspace, Workspace.ChildAdded:Connect(function(obj)
            if not _genOk(gen) then return end
            task.delay(0.3, function()
                if not _genOk(gen) then return end
                _tryContainer(obj)
            end)
        end))
    end

    local function _attachHumanoidWatcher(gen)
        if not _genOk(gen) then return end
        _trackWatcher(Workspace, Workspace.DescendantAdded:Connect(function(inst)
            if _genOk(gen) and inst:IsA("Humanoid") then
                task.delay(0.05, function()
                    if not _genOk(gen) then return end
                    local char = inst.Parent
                    if char and not IsLocalChar(char) then
                        local owner = ResolveOwner(char)
                        if not _genOk(gen) then return end
                        _reg(char, owner, owner == nil, "")
                    end
                end)
            end
        end))
    end

    local function _pollPlayers()
        for _, p in ipairs(Players:GetPlayers()) do
            if p == LocalPlayer then continue end
            local char = p.Character
            if not char then continue end
            local entry = _chars[char]
            if not entry then
                for c, data in pairs(_chars) do
                    if data.player == p and c ~= char then
                        _removeCharacter(c, "character_replaced")
                    end
                end
                _reg(char, p, false, "")
            elseif entry.isNPC then
                _reg(char, p, false, entry.teamName)
            end
        end
    end

    local function _humScan(gen)
        if not _genOk(gen) then return end
        if _humScanInProgress then _humScanPending = gen; return end
        _humScanInProgress = true
        local function doScan()
            local descendants = Workspace:GetDescendants()
            local scanCount = math.min(#descendants, HUM_SCAN_MAX_INSTANCES)
            for index = 1, scanCount do
                if index % HUM_SCAN_YIELD_EVERY == 0 then
                    task.wait()
                    if not _genOk(gen) then return end
                end
                local inst = descendants[index]
                if not _genOk(gen) then return end
                if inst:IsA("Humanoid") then
                    pcall(function()
                        local char = inst.Parent
                        if char and not IsLocalChar(char) then
                            local owner = ResolveOwner(char)
                            if not _genOk(gen) then return end
                            _reg(char, owner, owner == nil, "")
                        end
                    end)
                end
            end
            if #descendants > scanCount then
                warn(string.format(
                    "[SwaX] humanoid fallback scan capped at %d/%d instances",
                    scanCount,
                    #descendants
                ))
            end
        end
        local ok, err = pcall(doScan)
        if not ok then warn("[SwaX] _humScan failed:", err) end
        _humScanInProgress = false
        local pendingGeneration = _humScanPending
        _humScanPending = nil
        if pendingGeneration and _genOk(pendingGeneration) then
            task.spawn(_humScan, pendingGeneration)
        end
    end

    local function _resolveNPCs()
        for char, data in pairs(_chars) do
            if data.isNPC then
                local owner = ResolveOwner(char)
                if owner then _reg(char, owner, false, data.teamName) end
            end
        end
    end

    function CharacterRegistry.Init()
        if _running or not ctx.alive then return end
        _running = true
        _generation += 1
        _pollDt, _resolveDt = 0, 0
        local function _bindPlayer(p)
            if not _running or not ctx.alive or p == LocalPlayer then return end
            local playerMaid = _playerMaids[p]
            if playerMaid then playerMaid:Clean() end
            playerMaid = Maid.new()
            _playerMaids[p] = playerMaid
            if p.Character then _reg(p.Character, p, false, "") end
            pcall(function()
                playerMaid:Give(p.CharacterAdded:Connect(function(char)
                    if not _running or _playerMaids[p] ~= playerMaid then return end
                    local gen = _generation
                    task.delay(0.1, function()
                        if not _genOk(gen) or _playerMaids[p] ~= playerMaid then return end
                        for c, data in pairs(_chars) do
                            if data.player == p and c ~= char then
                                _removeCharacter(c, "character_replaced")
                            end
                        end
                        _reg(char, p, false, "")
                    end)
                end))
                playerMaid:Give(p.CharacterRemoving:Connect(function(c)
                    if not _running or _playerMaids[p] ~= playerMaid then return end
                    if _chars[c] then
                        _removeCharacter(c, "character_removed")
                    end
                end))
            end)
        end
        for _, p in ipairs(Players:GetPlayers()) do _bindPlayer(p) end
        _crEventMaid:Give(Players.PlayerAdded:Connect(_bindPlayer))
        _crEventMaid:Give(Players.PlayerRemoving:Connect(function(p)
            if not _running then return end
            for c, data in pairs(_chars) do
                if data.player == p then
                    _removeCharacter(c, "player_left")
                end
            end
            local playerMaid = _playerMaids[p]
            if playerMaid then
                playerMaid:Clean()
                _playerMaids[p] = nil
            end
        end))
        task.spawn(_startWorkspaceWatcher, _generation)
        task.spawn(_humScan, _generation)
        _attachHumanoidWatcher(_generation)
        -- Layer 2 + 5 heartbeat
        _crEventMaid:Give(RunService.Heartbeat:Connect(function(dt)
            if not _running or not ctx.alive then return end
            _pollDt    += dt
            _resolveDt += dt
            if _pollDt >= POLL_INTERVAL then
                _pollDt = 0
                _pollPlayers()
            end
            if _resolveDt >= RESOLVE_INTERVAL then
                _resolveDt = 0
                _resolveNPCs()
            end
        end))
    end

    function CharacterRegistry.Clean()
        _running = false
        _generation += 1
        _humScanPending = nil
        _pollDt, _resolveDt = 0, 0
        local current = {}
        for char in pairs(_chars) do current[#current + 1] = char end
        for _, char in ipairs(current) do _removeCharacter(char, "registry_clean") end
        -- Geometry also caches unregistered models, including the local character.
        RigCache.Clean()
        for player, playerMaid in pairs(_playerMaids) do
            playerMaid:Clean()
            _playerMaids[player] = nil
        end
        _crEventMaid:Clean()
        _containerMaid:Clean()
        _watchedContainers = setmetatable({}, { __mode = "k" })
        _containerWatchers = setmetatable({}, { __mode = "k" })
        _crCache, _crStamp = {}, {}
    end

    -- Cache with per-frame TTL to avoid repeated iteration.
    local CR_TTL     = 0.016

    function CharacterRegistry.ForceRescan()
        if not _running or not ctx.alive then return end
        local now = tick()
        if now - _lastForceRescan < FORCE_RESCAN_THROTTLE then return end
        _lastForceRescan = now
        _generation += 1
        _containerMaid:Clean()
        local current = {}
        for char in pairs(_chars) do current[#current + 1] = char end
        for _, char in ipairs(current) do _removeCharacter(char, "force_rescan") end
        _containerWatchers = setmetatable({}, { __mode = "k" })
        _watchedContainers  = setmetatable({}, { __mode = "k" })
        -- Flush GetAll() cache so stale results aren't served until TTL expires
        _crCache = {}
        _crStamp = {}
        _pollPlayers()
        task.spawn(_humScan, _generation)
        task.spawn(_startWorkspaceWatcher, _generation)
        _attachHumanoidWatcher(_generation)
    end

    function CharacterRegistry.GetAll(includeNPCs)
        local now = tick()
        local key = includeNPCs and "y" or "n"
        if _crCache[key] and (now - _crStamp[key]) < CR_TTL then
            return _crCache[key]
        end
        local out = {}
        for char, data in pairs(_chars) do
            if IsLocalChar(char) then continue end
            local inGame = false
            pcall(function() inGame = char:IsDescendantOf(game) end)
            if not inGame then
                _removeCharacter(char, "stale_cache")
                continue
            end
            if data.isNPC and not includeNPCs then continue end
            local cache = _getGeomCache(char)
            out[#out+1] = {
                char   = char,
                player = data.player,
                isNPC  = data.isNPC,
                name   = data.name,
                team   = data.teamName,
                hum    = cache and cache.humanoid,
            }
        end
        _crCache[key] = out
        _crStamp[key] = now
        return out
    end

    function CharacterRegistry.Count()
        local n = 0
        for char in pairs(_chars) do
            pcall(function() if char:IsDescendantOf(game) then n += 1 end end)
        end
        return n
    end

    function CharacterRegistry.GetData(char)
        return _chars[char]
    end

    function CharacterRegistry.GetHumanoid(char)
        local cache = _getGeomCache(char)
        return cache and cache.humanoid or nil
    end

    -- ════════════════════════════════════════════════════════════════
    -- MODULE: GeometryService
    -- FOV calculations, projection math, screen-space conversion,
    -- bounding boxes, distance calculations.

    return CharacterRegistry
end

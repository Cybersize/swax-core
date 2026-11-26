-- Conservative relationship resolver. Reads live data; never infers enemies
-- from name-tag colours, display names, clothing or arbitrary parent folders.
return function(ctx)
    local Players, Teams = ctx.services.Players, ctx.services.Teams
    local localPlayer = ctx.localPlayer
    local TeamService = {}
    local adapter = nil
    -- Exact field names and types must match on both sides. These are common
    -- replicated schemas, not proof of a game's damage/alliance rules.
    local FIELDS = {"TeamId", "TeamID", "FactionId", "FactionID", "Team", "Faction"}

    local function property(object, key)
        if object == nil then return nil end
        local ok, value = pcall(function() return object[key] end)
        if ok then return value end -- preserve false and zero
        return nil
    end

    local function liveInstance(value, class)
        return typeof(value) == "Instance" and value:IsA(class) and value:IsDescendantOf(game)
    end

    local function owner(char, hint)
        local function verified(player)
            return liveInstance(player, "Player") and player.Parent == Players and player.Character == char
        end
        local ok, player = pcall(function() return Players:GetPlayerFromCharacter(char) end)
        if ok and verified(player) then return player end
        if verified(hint) then return hint end
        -- Registry discovery may use unique names for custom rigs. That is not
        -- strong enough evidence to borrow a player's team for this resolver.
        return nil
    end

    local function localCharacter()
        local char = localPlayer.Character
        if liveInstance(char, "Model") then return char end
        local subject = ctx.camera and ctx.camera.CameraSubject
        for _ = 1, 32 do
            if not subject or subject == ctx.services.Workspace then return nil end
            if subject:IsA("Model") then return subject end
            subject = subject.Parent
        end
        return nil
    end

    local function validToken(value)
        local kind = typeof(value)
        if kind == "string" then return #value <= 128 and value:find("%S") ~= nil end
        if kind == "number" then return value == value and math.abs(value) < math.huge and value % 1 == 0 end
        if kind == "Instance" then return value:IsDescendantOf(game) end
        return false
    end

    -- Read only attributes/direct ValueObjects on the player or character.
    -- Reject contradictions, malformed values and partially replicated fields.
    local function field(player, char, key)
        local token, present, invalid = nil, false, false
        local function add(value)
            if not validToken(value) then invalid = true
            elseif present and (typeof(value) ~= typeof(token) or value ~= token) then invalid = true
            else token = value end
            present = true
        end
        for _, object in ipairs({player or false, char or false}) do
            if object then
                local ok, value = pcall(function() return object:GetAttribute(key) end)
                if not ok then present, invalid = true, true
                elseif value ~= nil then add(value) end
                local child = object:FindFirstChild(key)
                if child then
                    if child:IsA("StringValue") or child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("ObjectValue") then
                        add(property(child, "Value"))
                    else present, invalid = true, true end
                end
            end
        end
        return token, present, invalid
    end

    local function nativeRelationship(player)
        if not player then return nil end
        -- A stale Team reference must not override Neutral. Some games instead
        -- keep players Neutral and publish their own faction IDs.
        if property(localPlayer, "Neutral") ~= false or property(player, "Neutral") ~= false then return nil end
        local ours, theirs = property(localPlayer, "Team"), property(player, "Team")
        if not liveInstance(ours, "Team") or not liveInstance(theirs, "Team")
            or ours.Parent ~= Teams or theirs.Parent ~= Teams then return "Unknown", "incomplete_roblox_team" end
        return ours == theirs and "Ally" or "Enemy", "roblox_team"
    end

    -- Optional, explicit integration for a game's own alliance/FFA rules. The
    -- callback must be fast/non-yielding and return Ally, Enemy or Unknown.
    -- Errors/invalid results remain Unknown; they never fall through to Enemy.
    function TeamService.SetAdapter(callback)
        assert(callback == nil or type(callback) == "function", "Team adapter must be a function or nil")
        if not ctx.alive then return false end
        adapter = callback
        return true
    end
    ctx.maid:Give(function() adapter = nil end)

    function TeamService.Resolve(char, ownerHint)
        if not ctx.alive or not liveInstance(char, "Instance") then return "Unknown", "missing_character" end
        local ours = localCharacter()
        local player = owner(char, ownerHint)
        if char == ours or player == localPlayer then return "Self", "local_character" end
        if adapter then
            local ok, relation, reason = pcall(adapter, localPlayer, player, ours, char)
            if not ok then return "Unknown", "adapter_error" end
            if relation ~= "Ally" and relation ~= "Enemy" and relation ~= "Unknown" then
                return "Unknown", "invalid_adapter_result"
            end
            return relation, type(reason) == "string" and reason or "game_adapter"
        end
        if not player and ownerHint and property(ownerHint, "Character") ~= nil
            and property(ownerHint, "Character") ~= char then
            return "Unknown", "stale_character_owner"
        end
        local relation, reason = nativeRelationship(player)
        if relation == "Unknown" then return relation, reason end
        for _, key in ipairs(FIELDS) do
            local a, hasA, badA = field(localPlayer, ours, key)
            local b, hasB, badB = field(player, char, key)
            if badA or badB then return "Unknown", "invalid_or_conflicting_" .. key end
            if hasA ~= hasB then return "Unknown", "incomplete_" .. key end
            if hasA then
                if typeof(a) ~= typeof(b) then return "Unknown", "type_mismatch_" .. key end
                local candidate = a == b and "Ally" or "Enemy"
                if relation and relation ~= candidate then return "Unknown", "conflicting_team_sources" end
                if not relation then relation, reason = candidate, "field_" .. key end
            end
        end
        return relation or "Unknown", reason or "missing_team_data"
    end

    return TeamService
end

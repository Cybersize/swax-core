-- targeting/Selector: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, CharacterRegistry, GeometryService, VisibilityService, CoreMath)
    local Workspace=ctx.services.Workspace
    local LocalPlayer=ctx.localPlayer
    local TargetSelector = {}

    local function _getMotionPosition(char)
        local hum = CharacterRegistry.GetHumanoid(char)
        local root = hum and hum.RootPart
        if root and root:IsA("BasePart") then
            return root.Position
        end
        local part = GeometryService.GetAnyPart(char)
        return part and part.Position or nil
    end

    -- Prediction motion sampling. Only the character being aimed at is sampled.
    do
        local motion = setmetatable({}, { __mode = "k" })
        local MAX_SPEED = 1000
        local SAMPLE_TTL = 0.5
        local MOTION_HOLD = 0.12

        local function finiteNumber(value)
            return type(value) == "number" and value == value and math.abs(value) < math.huge
        end

        local function finiteVector(value)
            return typeof(value) == "Vector3" and finiteNumber(value.X)
                and finiteNumber(value.Y) and finiteNumber(value.Z)
        end

        local function motionPart(char)
            local hum = CharacterRegistry.GetHumanoid(char)
            local part = hum and hum.RootPart
            if part and part.Parent and part:IsA("BasePart") and part:IsDescendantOf(char) then return part end
            part = char:IsA("Model") and char.PrimaryPart or nil
            if part and part.Parent and part:IsA("BasePart") and part:IsDescendantOf(char) then return part end
            for _, name in ipairs({ "HumanoidRootPart", "HRP", "Root" }) do
                part = char:FindFirstChild(name)
                if part and part:IsA("BasePart") then return part end
            end
            return GeometryService.GetAnyPart(char)
        end

        local function sampleVelocity(char)
            local part = motionPart(char)
            local position = part and part.Position
            if not finiteVector(position) then motion[char] = nil; return Vector3.zero end
            local ok, physics = pcall(function() return part.AssemblyLinearVelocity end)
            if not ok or not finiteVector(physics) or physics.Magnitude > MAX_SPEED then physics = Vector3.zero end
            local now = os.clock()
            local state = motion[char]
            if not state or state.part ~= part or now < state.seen or now - state.seen > SAMPLE_TTL then
                motion[char] = { part = part, position = position, time = now, seen = now,
                    moved = now, velocity = Vector3.zero, discontinuity = false }
                return physics
            end
            state.seen = now
            local delta = position - state.position
            local elapsed = now - state.time
            if delta.Magnitude > 0.0001 and elapsed >= 0.0001 then
                local measured = delta / elapsed
                state.position, state.time, state.moved = position, now, now
                -- A teleport or rig replacement must not create a huge aim offset.
                state.discontinuity = delta.Magnitude > 64 or measured.Magnitude > MAX_SPEED
                state.velocity = state.discontinuity and Vector3.zero or measured
            elseif now - state.moved > MOTION_HOLD then
                state.velocity, state.time = Vector3.zero, now
            end
            if state.discontinuity then return Vector3.zero end
            if physics.Magnitude > 0.001 then return physics end
            -- CFrame/PivotTo movement and some replicated rigs report zero physics
            -- velocity. Hold measured motion briefly between replication packets.
            return state.velocity
        end

        ctx.maid:Give(CharacterRegistry.OnRemove(function(char) motion[char] = nil end))
        ctx.maid:Give(function() table.clear(motion) end)

        -- Prediction is additional lead time in seconds, including Projectile Mode.
        -- Both camera and mouse aim consume this same world-space lead point.
        function TargetSelector.PredictPos(char)
            if not char then return nil end
            local base = GeometryService.GetTargetPos(char)
            if not finiteVector(base) then motion[char] = nil; return nil end
            local velocity = sampleVelocity(char)
            local prediction = ConfigService.Get("Prediction")
            prediction = finiteNumber(prediction) and math.clamp(prediction, 0, 0.5) or 0
            local pos = base + velocity * prediction
            local speed = ConfigService.Get("BallisticSpeed")
            if finiteNumber(speed) and speed > 0 then
                local origin = ctx.camera and ctx.camera.CFrame.Position
                if not finiteVector(origin) then return nil end
                local gravity = 0
                if ConfigService.Get("DropCompensation") then
                    local value = Workspace.Gravity
                    gravity = finiteNumber(value) and math.max(value, 0) or 196.2
                end
                local acceleration = Vector3.new(0, -gravity, 0)
                local flight = CoreMath.InterceptTime(pos-origin, velocity, speed, acceleration)
                if not flight then return nil end -- do not invent a lead for an unreachable shot
                pos = pos + velocity * flight - acceleration * (0.5 * flight * flight)
            end
            return finiteVector(pos) and pos or base
        end
    end

    -- Validate a candidate entry as a legal target
    local function _isValidCandidate(entry)
        if not entry or not entry.char or CharacterRegistry.IsLocalChar(entry.char) then return false end
        local hum = entry.hum
        if hum and hum.Health <= 0 then return false, "dead" end
        local data = CharacterRegistry.GetData(entry.char)
        if data then
            if data.isNPC   and not ConfigService.Get("LockOnNPCs")     then return false, "team_filtered" end
            if not data.isNPC and not ConfigService.Get("LockOnPlayers") then return false, "team_filtered" end
        end
        if ConfigService.Get("TeamCheck") and not CharacterRegistry.IsEnemy(entry.char) then return false, "team_filtered_or_unknown" end
        if ConfigService.Get("WallCheck") and VisibilityService.IsBehindWall(entry.char) then
            return false, "behind_wall"
        end
        return true
    end

    -- GetBestTarget — single authoritative target selection API
    -- Returns an entry or nil. Does NOT touch lock state.
    -- Ranking and eligibility both use the displayed circle's pixel coordinates.
    -- World distance is handled separately by LockRange, never folded into FOV.
    function TargetSelector.GetSelectionScoreSquared(char)
        if not ctx.camera or not char then return math.huge end
        local targetPos = GeometryService.GetTargetPos(char)
        local screenPos = GeometryService.WorldToScreen(targetPos)
        if not screenPos then return math.huge end
        return CoreMath.ScreenDistanceSquared(screenPos, GeometryService.FOVOrigin())
    end

    -- GetBestTarget returns (bestEntry, currentLockedEntry).
    -- currentLockedEntry is the refreshed entry for currentLockedChar if it is
    -- still a valid candidate this frame, or nil if it dropped out.
    -- LockController uses currentLockedEntry to avoid switching targets every frame.
    function TargetSelector.GetBestTarget(currentLockedChar)
        if not ConfigService.Get("Enabled") then return nil, nil end
        if not ConfigService.Get("LockOnPlayers") and not ConfigService.Get("LockOnNPCs") then return nil, nil end
        local cam = ctx.camera
        if not cam then return nil, nil end
        local myC      = LocalPlayer.Character
        local myCenter = myC and _getMotionPosition(myC)
        local all      = CharacterRegistry.GetAll(ConfigService.Get("LockOnNPCs"))
        local fov      = ConfigService.Get("FOV")
        local fovOrigin = GeometryService.FOVOrigin()
        local fovSquared = fov * fov
        local lockRange = ConfigService.Get("LockRange")
        local rangeSquared = lockRange * lockRange
        local best, bestScore = nil, math.huge
        local currentEntry = nil   -- refreshed entry for currentLockedChar
        for _, e in ipairs(all) do
            local ok = _isValidCandidate(e)
            if not ok then
                continue
            end
            -- Use a cached root/part position for the cheap range filter before
            -- doing target-part lookup or screen projection.
            if lockRange > 0 and myCenter then
                local root = e.hum and e.hum.RootPart
                local anyPart = root or GeometryService.GetAnyPart(e.char)
                if anyPart then
                    local delta = myCenter - anyPart.Position
                    if delta:Dot(delta) > rangeSquared then
                        continue
                    end
                end
            end

            local targetPos = GeometryService.GetTargetPos(e.char)
            local screenPos = GeometryService.WorldToScreen(targetPos)
            if not screenPos then
                continue
            end
            local scoreSquared = CoreMath.ScreenDistanceSquared(screenPos, fovOrigin)
            if scoreSquared > fovSquared then
                continue
            end
            -- Track whether the currently-locked char is still valid this frame.
            if e.char == currentLockedChar then currentEntry = e end
            if scoreSquared < bestScore then
                bestScore = scoreSquared
                best = e
            end
        end
        return best, currentEntry
    end

    return TargetSelector
end

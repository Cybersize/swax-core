-- targeting/Lock: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, CharacterRegistry, GeometryService, VisibilityService, TargetSelector)
    local LocalPlayer=ctx.localPlayer
    local LockController = {}

    -- Lock states
    local LOCK_STATE = {
        Idle      = "Idle",
        Locked    = "Locked",
    }

    local _lockState        = LOCK_STATE.Idle
    local _lockActive       = false
    local _lockTarget       = nil       -- current target entry
    local _lockLockedT      = 0         -- time when Locked began
    local _lockDropReason   = nil       -- last drop reason string

    -- Diagnostic log (ring buffer)
    local _lockLog = {}
    local LOCK_LOG_MAX = 32
    local _lockLogHead = 0
    local _lockLogCount = 0

    local function _logTransition(from, to, reason)
        local entry = string.format("[%.2f] %s → %s%s",
            tick(), from, to, reason and (" [" .. reason .. "]") or "")
        _lockLogHead = (_lockLogHead % LOCK_LOG_MAX) + 1
        _lockLog[_lockLogHead] = entry
        _lockLogCount = math.min(_lockLogCount + 1, LOCK_LOG_MAX)
    end

    local function _setState(newState, reason)
        if newState ~= _lockState then
            _logTransition(_lockState, newState, reason)
            _lockState = newState
            if newState == LOCK_STATE.Locked then _lockLockedT = tick() end
        end
    end

    -- Called by the target scheduler and when right-click is pressed.
    function LockController.Update()
        if not _lockActive then
            LockController.DropTarget("right_click_released")
            return
        end
        if not ConfigService.Get("Enabled") then
            LockController.DropTarget("disabled")
            return
        end
        local bestCandidate, currentEntry = TargetSelector.GetBestTarget(_lockTarget and _lockTarget.char)
        -- Retain the current target while valid, even if another scores better.
        local nextTarget = currentEntry or bestCandidate
        if nextTarget then
            local targetChanged = _lockTarget and _lockTarget.char ~= nextTarget.char
            _lockTarget = nextTarget
            if _lockState ~= LOCK_STATE.Locked then
                _setState(LOCK_STATE.Locked)
            elseif targetChanged then
                _lockLockedT = tick()
                _logTransition(LOCK_STATE.Locked, LOCK_STATE.Locked, "target_changed")
            end
        elseif _lockTarget then
            -- A diagnostic failure must not retain an invalid target.
            local ok, reason = pcall(LockController.EvaluateDropReason)
            LockController.DropTarget(ok and reason or "target_invalid")
        end
    end

    -- Diagnose why a target is no longer valid.
    function LockController.EvaluateDropReason()
        local t = _lockTarget
        if not t or not t.char then return "registry_removed" end
        local inGame = false
        pcall(function() inGame = t.char:IsDescendantOf(game) end)
        if not inGame then return "registry_removed" end
        if ConfigService.Get("TeamCheck") then
            local relation, reason = CharacterRegistry.GetRelationship(t.char)
            if relation ~= "Enemy" then
                return relation == "Ally" and "team_filtered" or ("team_unknown:" .. tostring(reason))
            end
        end
        local hum = t.hum
        if hum and hum.Health <= 0 then return "dead" end
        local cf = GeometryService.GetCharBBox(t.char)
        if not cf then return "missing_bbox" end
        local myCenter = LocalPlayer.Character and GeometryService.GetCharCenter(LocalPlayer.Character)
        if myCenter then
            local eCenter = GeometryService.GetCharCenter(t.char)
            if eCenter and ConfigService.Get("LockRange") > 0 then
                if (myCenter - eCenter).Magnitude > ConfigService.Get("LockRange") then
                    return "distance_limit"
                end
            end
        end
        local fov = ConfigService.Get("FOV")
        if TargetSelector.GetSelectionScoreSquared(t.char) > fov * fov then return "out_of_fov" end
        if ConfigService.Get("WallCheck") and VisibilityService.IsBehindWall(t.char) then
            return "behind_wall"
        end
        return "target_invalid"
    end

    -- Force drop with explicit reason (callable externally)
    function LockController.DropTarget(reason)
        if _lockState == LOCK_STATE.Idle and not _lockTarget then return end
        local dropReason = reason or "forced"
        _lockTarget = nil
        _lockDropReason = dropReason
        _setState(LOCK_STATE.Idle, dropReason)
    end

    function LockController.SetActive(active)
        _lockActive = active == true
        if _lockActive then
            LockController.Update()
        else
            LockController.DropTarget("user_released")
        end
    end

    -- Returns the last N state-transition strings from the ring buffer.
    -- Format: "[time] From → To [reason]". Useful for live debug overlays and
    -- diagnosing whether lock drops are from input, wall_check, camera, or fov.
    function LockController.GetLog()
        local out = {}
        local first = _lockLogCount == LOCK_LOG_MAX
            and (_lockLogHead % LOCK_LOG_MAX) + 1 or 1
        for i = 1, _lockLogCount do
            local index = ((first + i - 2) % LOCK_LOG_MAX) + 1
            out[i] = _lockLog[index]
        end
        return out
    end

    -- Accessors
    function LockController.GetLockedTarget()
        if _lockState == LOCK_STATE.Locked then
            return _lockTarget
        end
        return nil
    end


    function LockController.GetState() return _lockState end
    function LockController.GetDropReason() return _lockDropReason end
    function LockController.GetLockDuration()
        if _lockState == LOCK_STATE.Locked then
            return tick() - _lockLockedT
        end
        return 0
    end

    function LockController.PrintLog()
        warn("══ [SwaX LockController Log] ══")
        for _, entry in ipairs(LockController.GetLog()) do warn(entry) end
        warn("Current state: " .. _lockState)
        if _lockTarget then warn("Current target: " .. tostring(_lockTarget.name)) end
        if _lockDropReason then warn("Last drop reason: " .. _lockDropReason) end
        warn("══════════════════════════════")
    end

    return LockController
end

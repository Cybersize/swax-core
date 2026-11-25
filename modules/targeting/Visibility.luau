-- targeting/Visibility: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, CharacterRegistry, GeometryService)
    local Workspace=ctx.services.Workspace
    local LocalPlayer=ctx.localPlayer
    local VisibilityService

    do
    VisibilityService = {}

    local WALL_HEIGHTS   = {0.20, 0.50, 0.80}
    local WALL_LATERALS  = {-0.20, 0, 0.20}
    local WALL_ALPHA     = 0.30   -- EWMA smoothing
    local WALL_VISIBLE   = 0.35   -- below = considered behind wall
    local WALL_TRANSP    = 0.65   -- transparency above this = ignored (glass/fence)
    local BW_TTL         = 0.10   -- seconds between full re-casts

    local _visConfidence = {}  -- [char] = 0..1 EWMA score
    local _bwResult      = {}  -- [char] = bool (cached)
    local _bwStamp       = {}  -- [char] = tick()

    local _bwParams = RaycastParams.new()
    _bwParams.FilterType = Enum.RaycastFilterType.Exclude
    local _bwFilter = {}
    local _visIndex = 1
    local _priorityChar = nil
    local LOW_HEIGHTS  = { 0.50 }
    local LOW_LATERALS = { 0 }
    local PRIORITY_BW_TTL = 0.05

    local function _rayVisible(origin, target, filter)
        local direction = target - origin
        if direction.Magnitude < 0.1 then return true end
        local unit = direction.Unit
        local filterCount = #filter
        for _ = 1, 4 do
            _bwParams.FilterDescendantsInstances = filter
            local hit = Workspace:Raycast(origin, direction, _bwParams)
            if not hit then return true end
            if not hit.Instance then return false end
            if hit.Instance.Transparency < WALL_TRANSP then return false end
            -- Transparent geometry is not automatically safe: continue the ray
            -- behind it so glass/fences cannot hide a solid obstruction.
            filter[filterCount + 1] = hit.Instance
            filterCount += 1
            origin = hit.Position + unit * 0.01
            direction = target - origin
            if direction.Magnitude < 0.1 then return true end
        end
        return false
    end

    -- Returns raw visibility fraction (0=fully blocked, 1=fully visible) via multi-ray
    local function _castVisibility(char)
        local cf, size = GeometryService.GetCharBBox(char)
        if not cf or not size then return 0 end
        local cam = ctx.camera
        if not cam then return 1 end
        local lc = LocalPlayer.Character
        -- Exclude: target char, local character (and all its children — equipped tools,
        -- character parts), and Camera (handles FPS viewmodels parented to Camera).
        -- This prevents the local weapon viewmodel from blocking visibility rays.
        table.clear(_bwFilter)
        if char then _bwFilter[#_bwFilter + 1] = char end
        if lc then _bwFilter[#_bwFilter + 1] = lc end
        if cam then _bwFilter[#_bwFilter + 1] = cam end
        local baseFilterCount = #_bwFilter
        local ok, origin = pcall(function() return cam.CFrame.Position end)
        if not ok or not origin then return 1 end
        local visible = 0
        local total   = 0
        local highQuality = ConfigService.Get("HighQualityVisibility") == true
        local heights = highQuality and WALL_HEIGHTS or LOW_HEIGHTS
        local laterals = highQuality and WALL_LATERALS or LOW_LATERALS
        for _, yFrac in ipairs(heights) do
            for _, latScale in ipairs(laterals) do
                total += 1
                local target = cf.Position
                    + cf.RightVector * (latScale * size.X)
                    + Vector3.new(0, (yFrac - 0.5) * size.Y, 0)
                local dir = target - origin
                if dir.Magnitude < 0.1 then
                    visible += 1
                    continue
                end
                for filterIndex = #_bwFilter, baseFilterCount + 1, -1 do
                    _bwFilter[filterIndex] = nil
                end
                if _rayVisible(origin, target, _bwFilter) then visible += 1 end
            end
        end
        return visible / math.max(total, 1)
    end

    -- Returns the EWMA confidence score (0=fully occluded, 1=fully visible)
    -- Confidence falls gradually on occlusion — one blocked frame does NOT drop lock.
    -- Read-only: returns cached confidence score. NEVER triggers a raycast.
    -- All raycasting happens exclusively in VisibilityService.UpdateAll (background).
    function VisibilityService.GetConfidence(char)
        return _visConfidence[char] or 1
    end

    function VisibilityService.SetPriorityChar(char)
        _priorityChar = char
    end

    -- Read-only: returns cached behind-wall result. NEVER triggers a raycast.
    function VisibilityService.IsBehindWall(char)
        return _bwResult[char] or false
    end

    -- Internal: do the actual raycast + EWMA update for one char.
    local function _castAndStore(char)
        local rawVis = _castVisibility(char)
        local prev   = _visConfidence[char] or rawVis
        local smooth = rawVis * WALL_ALPHA + prev * (1 - WALL_ALPHA)
        _visConfidence[char] = smooth
        _bwResult[char]      = smooth < WALL_VISIBLE
        _bwStamp[char]       = tick()
    end

    -- The locked target is latency-sensitive. Refresh it at up to 20 Hz without
    -- increasing the ordinary round-robin raycast budget.
    function VisibilityService.UpdatePriority()
        local char = _priorityChar
        if not char then return end
        if not CharacterRegistry.GetData(char) then
            _priorityChar = nil
            return
        end
        local now = tick()
        if now - (_bwStamp[char] or 0) >= PRIORITY_BW_TTL then
            _castAndStore(char)
        end
    end

    -- Called from background loop ONLY — never from RenderStepped.
    function VisibilityService.UpdateAll()
        local all = CharacterRegistry.GetAll(true)
        local count = #all
        if count == 0 then _visIndex = 1; return end
        local now = tick()
        local budget = math.min(count, ConfigService.Get("HighQualityVisibility") and 3 or 8)
        local priority = _priorityChar
        if priority and not CharacterRegistry.GetData(priority) then
            priority = nil
            _priorityChar = nil
        end

        -- Fallback priority update in case the 20 Hz path was delayed.
        if priority and budget > 0 and now - (_bwStamp[priority] or 0) >= BW_TTL then
            _castAndStore(priority)
            budget -= 1
        end

        local casts = 0
        local attempts = 0
        while casts < budget and attempts < count do
            attempts += 1
            if _visIndex > count then _visIndex = 1 end
            local entry = all[_visIndex]
            _visIndex += 1
            if entry and entry.char ~= priority
                and (now - (_bwStamp[entry.char] or 0) >= BW_TTL) then
                _castAndStore(entry.char)
                casts += 1
            end
        end
    end

    function VisibilityService.ClearChar(char)
        _visConfidence[char] = nil
        _bwResult[char]      = nil
        _bwStamp[char]       = nil
        if _priorityChar == char then _priorityChar = nil end
    end

    end -- VisibilityService private scope

    return VisibilityService
end

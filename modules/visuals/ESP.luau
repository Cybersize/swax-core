-- visuals/ESP: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, CharacterRegistry, GeometryService, VisibilityService)
    local CoreGui=ctx.services.CoreGui
    local VisualDebug = {}

    -- ── Optional profiling ────────────────────────────────────────────
    -- Set PROF_ENABLED = true to print counters ~once/sec to the console.
    local PROF_ENABLED = false
    local _prof = {
        espUpdates=0, espRenders=0, aabbProjections=0, skelProjections=0,
        drawWrites=0, drawSkipped=0,
        charRegistered=0, charCulled=0, charProcessed=0,
        renderTimeSum=0, renderTimeMax=0, renderTimeSamples=0, reportT=0,
    }

    -- ── Drawing guard ─────────────────────────────────────────────────
    local _drawingAvailable = type(Drawing) == "table" or type(Drawing) == "userdata"
    local _drawStub = setmetatable({}, {
        __newindex = function() end, __index = function() return false end })
    local function _newDraw(kind, props)
        if not _drawingAvailable then return _drawStub end
        local ok, d = pcall(function() return Drawing.new(kind) end)
        if not ok or not d then return _drawStub end
        for k, v in pairs(props) do pcall(function() d[k] = v end) end
        return d
    end

    -- ── Property-diffed write helper ──────────────────────────────────
    -- Returns 1 if the property was written, 0 if unchanged.
    -- Vector2/Color3/Vector3 equality is value-based in Luau; == is safe.
    local function _setD(obj, prop, val)
        if not obj then return 0 end
        if obj[prop] ~= val then obj[prop] = val; return 1 end
        return 0
    end

    -- ── Internal tables ───────────────────────────────────────────────
    local _espCache    = {}   -- [char] → { Drawing objects }
    local SKEL_BONES   = GeometryService.SKELETON_LIMIT
    local _occColor    = Color3.new(0.4, 0.4, 0.4)   -- static occluded-box colour

    -- Per-char state written by ESPStateUpdater, read by ESPRenderer.
    -- dirty=true → renderer must re-project this character next tick.
    local _espState    = {}
    -- Last values written to Drawing objects for property diffing.
    local _espRendered = {}
    -- Roblox-native Highlight/BillboardGui visuals.
    local _nativeVisuals = {}
    local _visualStyleVersion = 0
    for _, key in ipairs({
        "Accent", "ChamsColor", "ChamsOutline", "ChamsFillTransp",
        "ChamsOutlineTransp", "ChamsWallOnly", "Chams", "Box", "Name",
        "Health", "Distance", "AccurateBoxes", "ExactBoxes",
    }) do
        ConfigService.OnChanged(key, function() _visualStyleVersion += 1 end)
    end

    local function _nativeBoxEnabled()
        return ConfigService.Get("Box") == true
            and not ConfigService.Get("AccurateBoxes")
            and not ConfigService.Get("ExactBoxes")
    end

    local function _drawingBoxEnabled()
        return ConfigService.Get("Box") == true
            and (ConfigService.Get("AccurateBoxes") or ConfigService.Get("ExactBoxes"))
    end

    -- Work-queue for the round-robin renderer.
    local _espOrder      = {}
    local _espOrderDirty = true

    -- Per-frame camera snapshot written at the top of RenderStepped.
    local _camCf = nil   -- Camera.CFrame
    local _camVp = nil   -- Camera.ViewportSize

    -- True when at least one ESP feature is enabled (refreshed by updater).
    local _anyESPActive = false
    local _nativeWasActive = false
    local _needs2DProjection = false
    local _needsVisibility = false

    -- ════════════════════════════════════════════════════════════════
    -- STAGE 1 — ESPRegistry  (event-driven lifecycle)
    -- ════════════════════════════════════════════════════════════════

    local function _removeESP(char)
        local c = _espCache[char]
        if c and c.Sk then
            for _, ln in ipairs(c.Sk) do pcall(function() ln:Remove() end) end
        end
        if c then
            for k, o in pairs(c) do
                if k ~= "Sk" then pcall(function() o:Remove() end) end
            end
        end
        local native = _nativeVisuals[char]
        if native then
            if native.Highlight then pcall(function() native.Highlight:Destroy() end) end
            -- Child GUI objects are destroyed with their owned BillboardGui. Never
            -- iterate every cached Instance here because _adornee is a character part.
            if native.Billboard then pcall(function() native.Billboard:Destroy() end) end
        end
        _espCache[char]    = nil
        _nativeVisuals[char]= nil
        _espState[char]    = nil
        _espRendered[char] = nil
        _espOrderDirty     = true
        VisibilityService.ClearChar(char)
    end

    CharacterRegistry.OnRemove(_removeESP)

    local function _createVisuals(char, skeletonSegments)
        if not char then return end
        local ac = ConfigService.Get("Accent")
        local c = _espCache[char] or {}
        local isNewCharacter = _espCache[char] == nil
        local needsBox = _drawingBoxEnabled()
        local needsTracer = ConfigService.Get("Tracers")
        local needsSkeleton = ConfigService.Get("Skeleton")

        if needsBox and not c.Box then
            c.Box        = _newDraw("Square",{Thickness=1.5, Color=ac, Filled=false, Visible=false})
            c.BoxOutline = _newDraw("Square",{Thickness=2.5, Color=Color3.new(0,0,0), Filled=false, Visible=false})
            c.OccBox     = _newDraw("Square",{Thickness=1.5, Color=_occColor, Filled=false, Visible=false})
        end
        if needsTracer and not c.Tracer then
            c.Tracer = _newDraw("Line", {Thickness=1, Color=ac, Visible=false})
        end
        if needsSkeleton then
            c.Sk = c.Sk or {}
            for j = #c.Sk + 1, math.min(skeletonSegments and #skeletonSegments or 0, SKEL_BONES) do
                c.Sk[j] = _newDraw("Line", {Thickness=1, Color=ac, Visible=false})
            end
        end
        _espCache[char] = c
        if isNewCharacter then
            _espRendered[char] = { _allHidden = true }
            _espOrderDirty = true
            if PROF_ENABLED then _prof.charRegistered += 1 end
        elseif not _espRendered[char] then
            _espRendered[char] = { _allHidden = true }
        end
    end

    -- Pick up characters registered before this module loaded.
    -- Validate registry membership inside the deferred call to avoid a race
    -- where the character is removed before the deferred callback fires.
    CharacterRegistry.OnAdd(function(char)
        task.defer(function()
            if not CharacterRegistry.GetData(char) then return end
            if not char:IsDescendantOf(game)        then return end
            _createVisuals(char)
        end)
    end)

    local function _rebuildOrder()
        local t = {}
        for char in pairs(_espCache) do t[#t+1] = char end
        _espOrder      = t
        _espOrderDirty = false
    end

    -- World-space joints come from the same animated rig data as targeting.
    local function _getSkelPoints(char)
        return GeometryService.GetSkeletonSegments(char)
    end

    -- DrawEntry: legacy function — no longer called in the render path.
    -- ESPStateUpdater and ESPRenderer handle all rendering.
    function VisualDebug.DrawEntry(_entry)
        return false
    end

    -- ════════════════════════════════════════════════════════════════
    -- STAGE 2 — ESPStateUpdater  (Heartbeat scheduler, ~20 Hz)
    -- Computes per-char state. Writes _espState[char]. Marks dirty.
    -- All slow work lives here: part lookups, raycasts, health, chams.
    -- ════════════════════════════════════════════════════════════════

    local ESP_UPDATE_HZ  = 20   -- state-updater target rate
    local SKEL_UPDATE_HZ = 15   -- skeleton world-pos refresh rate
    local TEXT_UPDATE_HZ = 5    -- distance-string / name refresh rate

    local _updaterSkelDt = 0
    local _updaterTextDt = 0
    local _updaterPruneDt = 0

    local function _resolveEspColor(entry, isTeammate)
        if entry.isNPC then return Color3.fromRGB(255, 80, 80) end
        if isTeammate then return Color3.fromRGB(80, 255, 80) end
        return ConfigService.Get("Accent")
    end

    local function _resolveChamsColor(entry, char, isTeammate)
        if isTeammate then return Color3.fromRGB(60, 130, 255) end
        if entry.isNPC then return Color3.fromRGB(255, 120, 40) end
        return ConfigService.Get("ChamsColor")
    end

    -- Native visuals are tracked by Roblox at render rate. Lua only updates
    -- content and styles at the scheduled state-update rate.

    local function _destroyNativeVisuals(char)
        local visual = _nativeVisuals[char]
        if not visual then return end
        if visual.Highlight then pcall(function() visual.Highlight:Destroy() end) end
        if visual.Billboard then pcall(function() visual.Billboard:Destroy() end) end
        _nativeVisuals[char] = nil
    end

    local function _makeNativeText(parent, name, size, position, color)
        local label = Instance.new("TextLabel")
        label.Name = name
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.GothamBold
        label.Position = position
        label.Size = size
        label.TextColor3 = color
        label.TextSize = 12
        label.TextStrokeTransparency = 0.35
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.Parent = parent
        return label
    end

    local function _getBillboardAdornee(entry)
        local humanoid = entry and entry.hum
        local root
        pcall(function() root = humanoid and humanoid.RootPart end)
        if root and root:IsA("BasePart") then return root end

        local char = entry and entry.char
        if not char then return nil end
        local fallback = char:FindFirstChild("HumanoidRootPart", true)
            or char:FindFirstChild("Head", true)
            or GeometryService.GetAnyPart(char)
        return fallback and fallback:IsA("BasePart") and fallback or nil
    end

    local NATIVE_BBOX_INTERVAL = 0.50

    local function _updateNativeBillboardGeometry(visual, char, adornee, force)
        if not visual or not visual.Billboard or not adornee then return end
        local now = os.clock()
        if not force and now - (visual._bboxAt or 0) < NATIVE_BBOX_INTERVAL then
            return
        end
        visual._bboxAt = now

        local bboxCf, bboxSize = GeometryService.GetCharBBox(char)
        if not bboxCf or not bboxSize then return end
        local desiredOffset = bboxCf.Position - adornee.Position

        if force or visual._bboxX ~= bboxSize.X or visual._bboxY ~= bboxSize.Y
            or visual._bboxZ ~= bboxSize.Z then
            visual.Billboard.Size = UDim2.new(
                bboxSize.X * 1.05, 0,
                bboxSize.Y * 1.05, 0
            )
            visual._bboxX, visual._bboxY, visual._bboxZ =
                bboxSize.X, bboxSize.Y, bboxSize.Z
        end
        if force or visual._bboxOffset ~= desiredOffset then
            visual.Billboard.StudsOffsetWorldSpace = desiredOffset
            visual._bboxOffset = desiredOffset
        end
    end

    local function _createNativeBillboard(visual, adornee)
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "_SwaXInfo"
        billboard.Adornee = adornee
        billboard.AlwaysOnTop = true
        billboard.LightInfluence = 0
        billboard.MaxDistance = 10000
        billboard.Size = UDim2.new(4, 0, 6, 0)
        billboard.Parent = CoreGui

        local box = Instance.new("Frame")
        box.Name = "ApproximateBox"
        box.BackgroundTransparency = 1
        box.BorderSizePixel = 0
        box.Position = UDim2.fromScale(0.02, 0.02)
        box.Size = UDim2.fromScale(0.96, 0.96)
        box.Parent = billboard
        local stroke = Instance.new("UIStroke")
        stroke.Thickness = 1
        stroke.Parent = box

        local healthBackground = Instance.new("Frame")
        healthBackground.Name = "HealthBackground"
        healthBackground.BackgroundColor3 = Color3.new(0, 0, 0)
        healthBackground.BorderSizePixel = 0
        healthBackground.Position = UDim2.fromScale(-0.03, 0.02)
        healthBackground.Size = UDim2.fromScale(0.025, 0.96)
        healthBackground.Parent = billboard
        local healthFill = Instance.new("Frame")
        healthFill.Name = "HealthFill"
        healthFill.BorderSizePixel = 0
        healthFill.AnchorPoint = Vector2.new(0, 1)
        healthFill.Position = UDim2.fromScale(0, 1)
        healthFill.Size = UDim2.fromScale(1, 1)
        healthFill.Parent = healthBackground

        visual.Billboard = billboard
        visual.Box = box
        visual.BoxStroke = stroke
        visual.NameLabel = _makeNativeText(
            billboard, "Name", UDim2.fromScale(1, 0.14), UDim2.fromScale(0, -0.15),
            Color3.new(1, 1, 1)
        )
        visual.DistanceLabel = _makeNativeText(
            billboard, "Distance", UDim2.fromScale(1, 0.14), UDim2.fromScale(0, 1.01),
            Color3.new(1, 1, 1)
        )
        visual.HealthBackground = healthBackground
        visual.HealthFill = healthFill
        visual._styleVersion = nil
        visual._billboardEnabled = nil
        visual._adornee = nil
        visual._bodyGeometryActive = false
        visual._bboxAt = nil
        visual._bboxX, visual._bboxY, visual._bboxZ = nil, nil, nil
        visual._bboxOffset = nil
        visual._boxColor = nil
        visual._nameText = nil
        visual._nameColor = nil
        visual._distanceText = nil
        visual._healthFrac = nil
    end

    local function _syncNativeGeometry(visual, char, adornee, needBodyGeometry)
        if not visual.Billboard or not adornee then return end
        pcall(function()
            local adorneeChanged = visual._adornee ~= adornee
            if adorneeChanged then
                visual.Billboard.Adornee = adornee
                visual._adornee = adornee
            end
            local bodyWasActive = visual._bodyGeometryActive == true
            local bodyStarted = needBodyGeometry and not bodyWasActive
            visual._bodyGeometryActive = needBodyGeometry
            if needBodyGeometry then
                _updateNativeBillboardGeometry(
                    visual, char, adornee, adorneeChanged or bodyStarted
                )
            elseif bodyWasActive then
                visual.Billboard.Size = UDim2.new(4, 0, 6, 0)
                visual.Billboard.StudsOffsetWorldSpace = Vector3.zero
                visual._bboxAt = nil
                visual._bboxX, visual._bboxY, visual._bboxZ = nil, nil, nil
                visual._bboxOffset = nil
            end
        end)
    end

    local function _syncNativeStyles(
        visual, entry, state, needHighlight, needBillboard,
        showBox, showName, showHealth, showDistance
    )
        local char = entry.char
        local color = state.col or _resolveEspColor(entry, state.isTeammate)
        local styleDirty = visual._styleVersion ~= _visualStyleVersion

        if visual.Highlight then
            local behind = state.behind == true
            local fillColor = _resolveChamsColor(entry, char, state.isTeammate)
            pcall(function()
                if styleDirty or visual._fillColor ~= fillColor then
                    visual.Highlight.FillColor = fillColor
                    visual._fillColor = fillColor
                end
                if styleDirty then
                    visual.Highlight.FillTransparency = ConfigService.Get("ChamsFillTransp")
                    visual.Highlight.OutlineColor = ConfigService.Get("ChamsOutline")
                    visual.Highlight.OutlineTransparency = ConfigService.Get("ChamsOutlineTransp")
                end
                visual.Highlight.Enabled = needHighlight
                    and not (ConfigService.Get("ChamsWallOnly") and not behind)
            end)
        end

        if visual.Billboard then
            local shouldEnable = needBillboard
                and (showBox or showName or showDistance or showHealth)
            if visual._billboardEnabled ~= shouldEnable then
                visual.Billboard.Enabled = shouldEnable
                visual._billboardEnabled = shouldEnable
            end
            if styleDirty then
                visual.Box.Visible = showBox
                visual.NameLabel.Visible = showName
                visual.DistanceLabel.Visible = showDistance
                visual.HealthBackground.Visible = showHealth
                visual.HealthFill.Visible = showHealth
            end
            local boxColor = state.behind and _occColor or color
            if visual._boxColor ~= boxColor then
                visual.BoxStroke.Color = boxColor
                visual._boxColor = boxColor
            end
            if visual._nameText ~= state.text then
                visual.NameLabel.Text = state.text
                visual._nameText = state.text
            end
            if visual._nameColor ~= color then
                visual.NameLabel.TextColor3 = color
                visual._nameColor = color
            end
            if visual._distanceText ~= state.distStr then
                visual.DistanceLabel.Text = state.distStr
                visual._distanceText = state.distStr
            end
            local hp = math.clamp(state.hpFrac or 1, 0, 1)
            if visual._healthFrac ~= hp then
                visual.HealthFill.Size = UDim2.fromScale(1, hp)
                visual.HealthFill.BackgroundColor3 = Color3.new(1 - hp, hp, 0)
                visual._healthFrac = hp
            end
        end
        visual._styleVersion = _visualStyleVersion
    end

    local function _ensureNativeVisuals(entry, state)
        local char = entry.char
        local needHighlight = ConfigService.Get("Chams")
        local showBox = _nativeBoxEnabled()
        local showName = ConfigService.Get("Name")
        local showHealth = ConfigService.Get("Health")
        local showDistance = ConfigService.Get("Distance")
        local needBodyGeometry = showBox or showHealth
        local needBillboard = showBox or showName or showHealth or showDistance
        local adornee = needBillboard and _getBillboardAdornee(entry) or nil
        if needBillboard and not adornee then needBillboard = false end
        if not needHighlight and not needBillboard then
            _destroyNativeVisuals(char)
            return nil
        end

        local visual = _nativeVisuals[char] or {}
        if visual.Highlight and not visual.Highlight.Parent then visual.Highlight = nil end
        if needHighlight and not visual.Highlight then
            local ok, highlight = pcall(function()
                if not char:IsA("Model") then return nil end
                local instance = Instance.new("Highlight")
                instance.Name = "_SwaXHighlight"
                instance.Adornee = char
                instance.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                instance.Parent = CoreGui
                return instance
            end)
            if ok and highlight then
                visual.Highlight = highlight
                visual._styleVersion = nil
            end
        elseif not needHighlight and visual.Highlight then
            pcall(function() visual.Highlight:Destroy() end)
            visual.Highlight = nil
        end

        if visual.Billboard and not visual.Billboard.Parent then visual.Billboard = nil end
        if needBillboard and not visual.Billboard then
            _createNativeBillboard(visual, adornee)
        end
        _nativeVisuals[char] = visual
        _syncNativeGeometry(visual, char, adornee, needBodyGeometry)
        _syncNativeStyles(
            visual, entry, state, needHighlight, needBillboard,
            showBox, showName, showHealth, showDistance
        )
        return visual
    end

    local function _updateOneChar(entry, doSkel, doText)
        local char = entry.char

        local state = _espState[char]
        if not state then
            state = { bboxCf=nil, bboxSz=nil, col=nil, behind=false,
                      text="", hpFrac=1, distInt=0, distStr="[0m]", bones=nil }
            _espState[char] = state
        end

        -- Share one teammate lookup across ESP/chams colours in this update.
        -- Refresh each pass so team and name-tag colour changes remain immediate.
        state.isTeammate = (not entry.isNPC or ConfigService.Get("Chams"))
            and CharacterRegistry.IsTeammate(char) or false
        local col = _resolveEspColor(entry, state.isTeammate)
        if col ~= state.col then state.col = col end

        -- Visibility / behind-wall (reads cached result — no raycast here). Ignore
        -- old cache data whenever neither wall checking nor wall-only chams needs it.
        local needsOcclusion = ConfigService.Get("WallCheck")
            or (ConfigService.Get("Chams") and ConfigService.Get("ChamsWallOnly"))
        local behind = needsOcclusion and VisibilityService.IsBehindWall(char) or false
        if behind ~= state.behind then state.behind = behind end

        -- Native Highlight/BillboardGui visuals do not need a Lua projection.
        -- Only opt-in accurate boxes, tracers, and skeletons require the bbox path.
        local needsProjection = _drawingBoxEnabled()
            or ConfigService.Get("Tracers")
            or ConfigService.Get("Skeleton")
        local cf, sz
        if needsProjection then
            cf, sz = GeometryService.GetCharBBox(char)
            if cf ~= state.bboxCf or sz ~= state.bboxSz then
                state.bboxCf = cf; state.bboxSz = sz
            end
        else
            state.bboxCf, state.bboxSz = nil, nil
        end

        local center = cf and cf.Position
        if not center then
            local root = entry.hum and entry.hum.RootPart
            local anyPart = root or GeometryService.GetAnyPart(char)
            center = anyPart and anyPart.Position
        end

        -- Health (only computed when the bar is enabled)
        if ConfigService.Get("Health") then
            local hum = entry.hum
            local hp  = hum and math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1) or 1
            if math.abs(hp - state.hpFrac) > 0.005 then
                state.hpFrac = hp
            end
        end

        -- Distance string (TEXT_UPDATE_HZ — avoids per-frame string alloc)
        if doText and ConfigService.Get("Distance") and _camCf and center then
            local newDist = math.floor(((_camCf.Position) - center).Magnitude)
            if newDist ~= state.distInt then
                state.distInt = newDist
                state.distStr = "[" .. newDist .. "m]"
            end
        end

        -- Name (TEXT_UPDATE_HZ)
        if doText then
            local nameStr = (entry.player and entry.player.Name) or entry.name or "?"
            if nameStr ~= state.text then state.text = nameStr end
        end

        -- Skeleton world positions (SKEL_UPDATE_HZ, only when enabled)
        if doSkel then
            if ConfigService.Get("Skeleton") then
                state.bones = _getSkelPoints(char)
            elseif state.bones ~= nil then
                state.bones = nil
            end
        end

        if needsProjection then _createVisuals(char, state.bones) end
        _ensureNativeVisuals(entry, state)
    end

    -- Called from the background task.spawn loop.
    local function ESPStateUpdater_Tick(dt)
        _needs2DProjection = _drawingBoxEnabled()
            or ConfigService.Get("Tracers")
            or ConfigService.Get("Skeleton")
        _needsVisibility = ConfigService.Get("WallCheck")
            or (ConfigService.Get("Chams") and ConfigService.Get("ChamsWallOnly"))
        _anyESPActive = ConfigService.Get("Box") or ConfigService.Get("Name")
            or ConfigService.Get("Health") or ConfigService.Get("Tracers")
            or ConfigService.Get("Distance") or ConfigService.Get("Skeleton")
            or ConfigService.Get("Chams")

        _updaterSkelDt += dt
        _updaterTextDt += dt
        _updaterPruneDt += dt
        local doSkel = _updaterSkelDt >= (1 / SKEL_UPDATE_HZ)
        local doText = _updaterTextDt >= (1 / TEXT_UPDATE_HZ)
        if doSkel then _updaterSkelDt = 0 end
        if doText then _updaterTextDt = 0 end

        if not _anyESPActive then
            if _nativeWasActive then
                for _, visual in pairs(_nativeVisuals) do
                    if visual.Highlight then
                        pcall(function() visual.Highlight.Enabled = false end)
                    end
                    if visual.Billboard then
                        pcall(function()
                            visual.Billboard.Enabled = false
                            visual._billboardEnabled = false
                        end)
                    end
                end
                _nativeWasActive = false
            end
            return
        end
        _nativeWasActive = true
        if PROF_ENABLED then _prof.espUpdates += 1 end

        local all = CharacterRegistry.GetAll(true)

        -- OnRemove handles normal lifecycle cleanup. Keep a low-frequency fallback
        -- for unexpected registry misses without allocating a table 20 times/sec.
        if _updaterPruneDt >= 1 then
            _updaterPruneDt %= 1
            local valid = {}
            for _, e in ipairs(all) do valid[e.char] = true end
            for char in pairs(_espState) do
                if not valid[char] then _removeESP(char) end
            end
        end

        -- Update each character
        for _, entry in ipairs(all) do
            if not CharacterRegistry.IsLocalChar(entry.char) then
                _updateOneChar(entry, doSkel, doText)
            end
        end
    end

    -- Stubs kept for backward compatibility (UI buttons call RebuildAll/UpdateAll).
    function VisualDebug.RebuildAll() end
    function VisualDebug.UpdateAll()  end
    function VisualDebug.UpdatePositions()
        -- Intentional no-op: ESPRenderer.RendererTick handles projection.
    end

    -- ════════════════════════════════════════════════════════════════
    -- STAGE 3 — ESPRenderer  (RenderStepped dt-accumulator)
    -- Fires at adaptive Hz via accumulator — NOT a full traversal every frame.
    -- Reads _espState, projects to screen, writes Drawing props only on change.
    -- Enforces a per-tick os.clock() time budget.
    -- ════════════════════════════════════════════════════════════════

    local _rendererDt      = 0
    local _rendererRRIdx   = 1    -- round-robin cursor (starve-prevention)
    local _wasESPActive    = false   -- tracks previous _anyESPActive for one-shot hide
    local RENDERER_BUDGET  = 0.0015  -- 1.5 ms max per scheduled renderer invocation

    local function _rendererHz()
        local n = #_espOrder
        if n <= 4  then return 30 end
        if n <= 10 then return 20 end
        return 15
    end

    -- Hide all drawings for a char without re-writing already-hidden objects.
    local function _hideChar(c, rend)
        if rend and rend._allHidden then return end  -- already fully hidden
        if c.Box        and c.Box.Visible        then c.Box.Visible        = false end
        if c.BoxOutline and c.BoxOutline.Visible then c.BoxOutline.Visible = false end
        if c.OccBox     and c.OccBox.Visible     then c.OccBox.Visible     = false end
        if c.Name       and c.Name.Visible       then c.Name.Visible       = false end
        if c.Tracer     and c.Tracer.Visible     then c.Tracer.Visible     = false end
        if c.Dist       and c.Dist.Visible       then c.Dist.Visible       = false end
        if c.HpBar      and c.HpBar.Visible      then c.HpBar.Visible      = false end
        if c.HpBG       and c.HpBG.Visible       then c.HpBG.Visible       = false end
        if c.Sk then
            for _, ln in ipairs(c.Sk) do
                if ln.Visible then ln.Visible = false end
            end
        end
        if rend then rend._allHidden = true end
    end

    local function _renderChar(char, cam, vp)
        local c    = _espCache[char];    if not c    then return end
        local rend = _espRendered[char]; if not rend then return end
        local state = _espState[char]

        if not state then _hideChar(c, rend); return end
        local cf, sz = state.bboxCf, state.bboxSz
        if not cf or not sz then _hideChar(c, rend); return end

        -- ── Cheap culls before ProjectAABB ────────────────────────────
        -- 1. Depth cull: character centre must be in front of camera.
        local ctr = cf.Position
        local cs
        pcall(function() cs = cam:WorldToViewportPoint(ctr) end)
        if not cs or cs.Z <= 0 then _hideChar(c, rend); return end

        -- 2. Viewport margin cull (skip clearly off-screen characters).
        if vp then
            local margin = 400
            if cs.X < -margin or cs.X > vp.X + margin
                or cs.Y < -margin or cs.Y > vp.Y + margin then
                _hideChar(c, rend); return
            end
        end

        -- 3. Distance range cull.
        local maxRange = ConfigService.Get("LockRange")
        if maxRange > 0 and _camCf then
            if (_camCf.Position - ctr).Magnitude > maxRange + 50 then
                _hideChar(c, rend); return
            end
        end

        -- ── AABB projection ───────────────────────────────────────────
        local sMinX, sMaxX, sMinY, sMaxY
        if ConfigService.Get("ExactBoxes") then
            sMinX, sMaxX, sMinY, sMaxY = GeometryService.ProjectAABB(cf, sz)
        else
            sMinX, sMaxX, sMinY, sMaxY = GeometryService.ProjectTwoPoint(char, cf, sz)
        end
        if not sMinX then _hideChar(c, rend); return end
        if PROF_ENABLED then _prof.aabbProjections += 1 end

        rend._allHidden = false
        local boxH  = sMaxY - sMinY
        local boxW  = sMaxX - sMinX
        local px    = (sMinX + sMaxX) * 0.5
        local topY  = sMinY
        local botY  = sMaxY
        local behind = state.behind
        local col    = state.col
        local writes = 0

        -- ── Box ───────────────────────────────────────────────────────
        local sb = _drawingBoxEnabled()
        writes += _setD(c.Box,        "Visible", sb)
        writes += _setD(c.BoxOutline, "Visible", sb)
        if sb then
            local bs = Vector2.new(boxW, boxH)
            local bp = Vector2.new(px - boxW * 0.5, topY)
            writes += _setD(c.BoxOutline, "Size",     bs)
            writes += _setD(c.BoxOutline, "Position", bp)
            writes += _setD(c.Box,        "Size",     bs)
            writes += _setD(c.Box,        "Position", bp)
            local boxCol = behind and Color3.new(0.8, 0.8, 0.8) or col
            writes += _setD(c.Box,   "Color",   boxCol)
            writes += _setD(c.OccBox,"Visible", behind)
            if behind then
                writes += _setD(c.OccBox, "Size",     bs)
                writes += _setD(c.OccBox, "Position", bp)
            end
        else
            writes += _setD(c.OccBox, "Visible", false)
        end

        -- ── Name ─────────────────────────────────────────────────────
        local sn = ConfigService.Get("Name")
        writes += _setD(c.Name, "Visible", sn)
        if sn then
            writes += _setD(c.Name, "Text",     state.text)
            writes += _setD(c.Name, "Color",    col)
            writes += _setD(c.Name, "Position", Vector2.new(px, topY - 16))
        end

        -- ── Tracer ───────────────────────────────────────────────────
        local st = ConfigService.Get("Tracers")
        writes += _setD(c.Tracer, "Visible", st)
        if st and vp then
            writes += _setD(c.Tracer, "From",  Vector2.new(vp.X * 0.5, vp.Y))
            writes += _setD(c.Tracer, "To",    Vector2.new(px, botY))
            writes += _setD(c.Tracer, "Color", col)
        end

        -- ── Distance ─────────────────────────────────────────────────
        local sd = ConfigService.Get("Distance")
        writes += _setD(c.Dist, "Visible", sd)
        if sd then
            writes += _setD(c.Dist, "Text",     state.distStr)
            writes += _setD(c.Dist, "Position", Vector2.new(px, botY + 5))
        end

        -- ── Health bar ───────────────────────────────────────────────
        local shp = ConfigService.Get("Health")
        writes += _setD(c.HpBar, "Visible", shp)
        writes += _setD(c.HpBG,  "Visible", shp)
        if shp then
            local hp  = state.hpFrac
            local bx  = px - boxW * 0.5 - 5
            writes += _setD(c.HpBG,  "Size",     Vector2.new(3, boxH))
            writes += _setD(c.HpBG,  "Position", Vector2.new(bx, topY))
            writes += _setD(c.HpBar, "Size",     Vector2.new(3, boxH * hp))
            writes += _setD(c.HpBar, "Position", Vector2.new(bx, botY - boxH * hp))
            writes += _setD(c.HpBar, "Color",    Color3.new(1 - hp, hp, 0))
        end

        -- ── Skeleton ─────────────────────────────────────────────────
        if c.Sk then
            local showSkel = ConfigService.Get("Skeleton") and state.bones and not behind
            if showSkel then
                local bones = state.bones
                for j, ln in ipairs(c.Sk) do
                    local bone = bones[j]
                    if bone then
                        local sp1, sp2
                        pcall(function()
                            sp1 = cam:WorldToViewportPoint(bone[1])
                            sp2 = cam:WorldToViewportPoint(bone[2])
                        end)
                        if sp1 and sp2 and sp1.Z > 0 and sp2.Z > 0 then
                            writes += _setD(ln, "From",    Vector2.new(sp1.X, sp1.Y))
                            writes += _setD(ln, "To",      Vector2.new(sp2.X, sp2.Y))
                            writes += _setD(ln, "Color",   col)
                            writes += _setD(ln, "Visible", true)
                        else
                            writes += _setD(ln, "Visible", false)
                        end
                    else
                        writes += _setD(ln, "Visible", false)
                    end
                end
                if PROF_ENABLED then _prof.skelProjections += 1 end
            else
                for _, ln in ipairs(c.Sk) do
                    writes += _setD(ln, "Visible", false)
                end
            end
        end

        if PROF_ENABLED then _prof.drawWrites += writes; _prof.charProcessed += 1 end
    end

    function VisualDebug.RendererTick(dt)
        if not _needs2DProjection then
            -- Hide exactly once on the active→inactive transition; skip per-frame
            -- loop on every subsequent frame while the feature remains off.
            if _wasESPActive then
                if _espOrderDirty then _rebuildOrder() end
                for _, char in ipairs(_espOrder) do
                    local c = _espCache[char]
                    if c then _hideChar(c, _espRendered[char]) end
                end
                _wasESPActive = false
            end
            return
        end
        _wasESPActive = true

        _rendererDt += dt
        local hz       = _rendererHz()
        local interval = 1 / hz
        if _rendererDt < interval then return end
        _rendererDt = _rendererDt % interval

        if _espOrderDirty then _rebuildOrder() end
        local n = #_espOrder
        if n == 0 then return end

        if PROF_ENABLED then _prof.espRenders += 1 end
        local cam = ctx.camera; if not cam then return end
        local vp  = _camVp

        -- Budget is always enforced regardless of profiling state.
        -- Profiling records elapsed time as a separate concern.
        local startIdx = _rendererRRIdx
        local t0       = os.clock()
        for offset = 0, n - 1 do
            local idx  = (startIdx + offset - 1) % n + 1
            local char = _espOrder[idx]
            if char then _renderChar(char, cam, vp) end
            -- Advance cursor after every item so the next tick resumes here.
            _rendererRRIdx = (idx % n) + 1
            if os.clock() - t0 >= RENDERER_BUDGET then break end
        end

        if PROF_ENABLED then
            local elapsed = os.clock() - t0
            _prof.renderTimeSum     += elapsed
            _prof.renderTimeSamples += 1
            if elapsed > _prof.renderTimeMax then _prof.renderTimeMax = elapsed end
        end
    end

    -- FOV Circle
    local _fovCircle = _newDraw("Circle",{Thickness=2, Color=ConfigService.Get("Accent"),
        Filled=false, Visible=false, NumSides=64})
    local _fovLast = { visible = false, x=0, y=0, radius=0, filled=false, color=Color3.new() }

    function VisualDebug.UpdateFOV()
        local show = ConfigService.Get("ShowFOV") == true
        if not show then
            if _fovLast.visible then
                _fovCircle.Visible = false
                _fovLast.visible = false
            end
            return
        end
        local origin = GeometryService.FOVOrigin()
        local radius = ConfigService.Get("FOV")
        local filled = ConfigService.Get("FOVFill")
        local color = ConfigService.Get("Accent")
        if _fovLast.visible and _fovLast.x == origin.X and _fovLast.y == origin.Y
            and _fovLast.radius == radius and _fovLast.filled == filled
            and _fovLast.color == color then return end
        _fovCircle.Position = origin
        _fovCircle.Radius = radius
        _fovCircle.Filled = filled
        _fovCircle.Color = color
        _fovCircle.Visible = true
        _fovLast.visible = true
        _fovLast.x = origin.X
        _fovLast.y = origin.Y
        _fovLast.radius = radius
        _fovLast.filled = filled
        _fovLast.color = color
    end

    function VisualDebug.GetFOVCircle() return _fovCircle end

    -- Crosshair
    local _xhLines    = {}; local _xhLinesOut = {}
    for i = 1, 4 do
        _xhLines[i]    = _newDraw("Line",  {Visible=false, Thickness=1, Color=Color3.new(1,1,1)})
        _xhLinesOut[i] = _newDraw("Line",  {Visible=false, Thickness=3, Color=Color3.new(0,0,0)})
    end
    local _xhDot    = _newDraw("Circle",{Visible=false, Filled=true, Radius=3, Color=Color3.new(1,1,1), NumSides=32})
    local _xhDotOut = _newDraw("Circle",{Visible=false, Filled=true, Radius=5, Color=Color3.new(0,0,0), NumSides=32})
    local _xhRing   = _newDraw("Circle",{Visible=false, Filled=false, Radius=10, Thickness=1, Color=Color3.new(1,1,1), NumSides=64})
    local _xhRingOut= _newDraw("Circle",{Visible=false, Filled=false, Radius=11, Thickness=3, Color=Color3.new(0,0,0), NumSides=64})
    -- Full signature of every crosshair input so ANY change triggers a redraw.
    local _xhLast = { valid=false, x=0, y=0, style="", size=0, gap=0, thick=0, color=Color3.new(), outline=false }
    local _xhWasShowing = false

    function VisualDebug.UpdateCrosshair()
        local show = ConfigService.Get("Crosshair")
        if not show then
            if _xhWasShowing then
                for _, l in ipairs(_xhLines)    do l.Visible = false end
                for _, l in ipairs(_xhLinesOut) do l.Visible = false end
                _xhDot.Visible=false; _xhDotOut.Visible=false
                _xhRing.Visible=false; _xhRingOut.Visible=false
                _xhWasShowing = false
            end
            _xhLast.valid = false
            return
        end
        _xhWasShowing = true
        local style  = ConfigService.Get("CrosshairStyle")
        local size   = ConfigService.Get("CrosshairSize")
        local gap    = ConfigService.Get("CrosshairGap")
        local thick  = ConfigService.Get("CrosshairThickness")
        local col    = ConfigService.Get("CrosshairColor")
        local outline= ConfigService.Get("CrosshairOutline")
        local origin = GeometryService.FOVOrigin()
        local sx, sy = origin.X, origin.Y
        -- Compare scalar inputs directly; avoid building a concatenated signature
        -- string every update.
        if _xhLast.valid and _xhLast.x == sx and _xhLast.y == sy
            and _xhLast.style == style and _xhLast.size == size
            and _xhLast.gap == gap and _xhLast.thick == thick
            and _xhLast.color == col and _xhLast.outline == outline then return end
        _xhLast.valid = true
        _xhLast.x, _xhLast.y = sx, sy
        _xhLast.style, _xhLast.size, _xhLast.gap = style, size, gap
        _xhLast.thick, _xhLast.color, _xhLast.outline = thick, col, outline
        local showCross = style=="Cross" or style=="Cross+Dot"
        for j = 1, 4 do
            _xhLines[j].Visible    = showCross
            _xhLinesOut[j].Visible = showCross and outline
            if showCross then
                local fromPoint, toPoint
                if j == 1 then
                    fromPoint = Vector2.new(sx, sy-gap-size); toPoint = Vector2.new(sx, sy-gap)
                elseif j == 2 then
                    fromPoint = Vector2.new(sx, sy+gap); toPoint = Vector2.new(sx, sy+gap+size)
                elseif j == 3 then
                    fromPoint = Vector2.new(sx-gap-size, sy); toPoint = Vector2.new(sx-gap, sy)
                else
                    fromPoint = Vector2.new(sx+gap, sy); toPoint = Vector2.new(sx+gap+size, sy)
                end
                _xhLines[j].From=fromPoint; _xhLines[j].To=toPoint
                _xhLines[j].Color=col;      _xhLines[j].Thickness=thick
                _xhLinesOut[j].From=fromPoint; _xhLinesOut[j].To=toPoint
                _xhLinesOut[j].Thickness=thick+2
            end
        end
        local showDot = style=="Dot" or style=="Cross+Dot"
        local dotR    = math.max(thick+1, 2)
        _xhDotOut.Visible=showDot and outline; _xhDot.Visible=showDot
        if showDot then
            _xhDot.Position=origin;    _xhDot.Radius=dotR;   _xhDot.Color=col
            _xhDotOut.Position=origin; _xhDotOut.Radius=dotR+2
        end
        local showRing = style=="Circle"
        _xhRingOut.Visible=showRing and outline; _xhRing.Visible=showRing
        if showRing then
            _xhRing.Position=origin;    _xhRing.Radius=size;   _xhRing.Color=col; _xhRing.Thickness=thick
            _xhRingOut.Position=origin; _xhRingOut.Radius=size+1; _xhRingOut.Thickness=thick+2
        end
    end

    -- Profiling overlay — prints counters to console once per second.
    -- Only active when PROF_ENABLED = true; otherwise zero runtime cost.
    function VisualDebug.DrawDebugOverlay()
        if not PROF_ENABLED then return end
        local now = os.clock()
        if now - _prof.reportT < 1 then return end
        _prof.reportT = now
        local avgMs = _prof.renderTimeSamples > 0
            and (_prof.renderTimeSum / _prof.renderTimeSamples * 1000) or 0
        warn(string.format(
            "[SwaX ESP] updTicks=%d rendTicks=%d AABB=%d skel=%d writes=%d "
            .. "chars=%d proc=%d culled=%d avgRenderMs=%.2f maxRenderMs=%.2f",
            _prof.espUpdates, _prof.espRenders,
            _prof.aabbProjections, _prof.skelProjections,
            _prof.drawWrites, _prof.charRegistered,
            _prof.charProcessed, _prof.charCulled,
            avgMs, _prof.renderTimeMax * 1000))
        _prof.espUpdates=0; _prof.espRenders=0
        _prof.aabbProjections=0; _prof.skelProjections=0
        _prof.drawWrites=0; _prof.charProcessed=0; _prof.charCulled=0
        _prof.renderTimeSum=0; _prof.renderTimeMax=0; _prof.renderTimeSamples=0
    end

    function VisualDebug.Clean()
        for char in pairs(_espCache) do _removeESP(char) end
        for char in pairs(_nativeVisuals) do _removeESP(char) end
        table.clear(_espState)
        table.clear(_espRendered)
        table.clear(_espOrder)
        local function remove(object)
            if object then pcall(function() object:Remove() end) end
        end
        remove(_fovCircle)
        for _, line in ipairs(_xhLines) do remove(line) end
        for _, line in ipairs(_xhLinesOut) do remove(line) end
        for _, object in ipairs({_xhDot, _xhDotOut, _xhRing, _xhRingOut}) do remove(object) end
    end

    -- Public scheduling boundary; all visual caches stay private to this module.
    VisualDebug.UPDATE_HZ=ESP_UPDATE_HZ
    VisualDebug.UpdateState=ESPStateUpdater_Tick
    function VisualDebug.NeedsVisibility() return _needsVisibility end
    function VisualDebug.SetCameraSnapshot(cf,viewport) _camCf,_camVp=cf,viewport end

    return VisualDebug
end

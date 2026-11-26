-- Original CrispyLib interface, wired only to the modular core.
return function(ctx, ConfigService, Runtime, CharacterRegistry, Scheduler, LockController, VisualDebug, WeaponScanner)
    local CoreUI = {}
    local RELEASE = "https://github.com/Cybersize/Crispylib/releases/download/v3.3.0/CrispyLib.lua"

    local function compatible(library)
        return type(library) == "table"
            and type(library.CreateWindow) == "function"
            and type(library.CreateLoadingScreen) == "function"
            and type(library.State) == "table" and type(library.State.Get) == "function"
            and type(library.Config) == "table" and type(library.Config.OnApplied) == "function"
            and type(library.Config.CreateProfileUI) == "function"
    end

    local function resolveLibrary()
        local environment = _G
        if type(getgenv) == "function" then
            local ok, value = pcall(getgenv)
            if ok and type(value) == "table" then environment = value end
        end
        for _, candidate in ipairs({environment, _G}) do
            local library = rawget(candidate, "CrispyLib")
            if compatible(library) then return library end
        end
        local errors = {}
        local function attempt(label, read)
            local ok, result = pcall(function()
                local source = read()
                assert(type(source) == "string" and #source > 0, "empty library source")
                local chunk, compileError = loadstring(source, "@" .. label)
                assert(chunk, compileError)
                local library = chunk()
                assert(compatible(library), "CrispyLib 3.3-compatible config API required")
                return library
            end)
            if ok then return result end
            errors[#errors + 1] = label .. ": " .. tostring(result)
            return nil
        end
        local library = attempt(RELEASE, function() return game:HttpGet(RELEASE) end)
        if library then return library end
        if type(readfile) == "function" then
            local paths = {"CrispyLib.lua", "CrispyLib.refactored.lua"}
            local configured = rawget(environment, "CRISPYLIB_PATH")
            if type(configured) == "string" and configured ~= "" then table.insert(paths, 1, configured) end
            for _, path in ipairs(paths) do
                library = attempt(path, function() return readfile(path) end)
                if library then return library end
            end
        end
        error("[SwaX Core] Original UI could not load. No headless instance was started.\n"
            .. table.concat(errors, "\n"), 0)
    end

    function CoreUI.Init()
        local CrispyLib = resolveLibrary()
        assert(ctx.alive, "SwaX Core was unloaded while loading the UI")
        local loader = CrispyLib.CreateLoadingScreen({Title="SwaX", Subtitle="v7.0 — Modular Refactor"})
        ctx.maid:Give(loader)
        Runtime.Loader = loader
        loader:SetStatus("Preparing core controls...")
        loader:SetProgress(0.5)

        local window = CrispyLib:CreateWindow({
            Title="SwaX", Subtitle="v7.0 — Universal", ConfigName="SwaXCore",
            AutoLoad=false, -- Load after every control and the OnApplied observer exist.
            Size=UDim2.new(0,820,0,545), DragStyle=1,
            Keybind=Enum.KeyCode.RightShift, ShowUserInfo=true,
        })
        ctx.maid:Give(window)
        Runtime.Window = window
        Runtime.GUI = window._screenGui or window._sg
        if Runtime.GUI then ctx.maid:Give(Runtime.GUI.Destroying:Connect(Runtime.Destroy)) end

        local bindings = {}
        local function bind(tab, kind, name, key, flag, options)
            local spec = options or {}
            spec.Name, spec.Flag, spec.Default = name, flag, ConfigService.Get(key)
            spec.Callback = function(value) ConfigService.Set(key, value) end
            local control = tab["Add" .. kind](tab, spec)
            bindings[#bindings + 1] = {key=key, flag=flag}
            ctx.maid:Give(ConfigService.OnChanged(key, function(value) control:Set(value, true) end))
            return control
        end
        local function toggle(tab, name, key, flag, description)
            return bind(tab, "Toggle", name, key, flag, {Description=description})
        end
        local function slider(tab, name, key, flag, step)
            local range = assert(ConfigService.Ranges[key], key)
            return bind(tab, "Slider", name, key, flag, {Min=range[1], Max=range[2], Step=step or 1})
        end
        local function dropdown(tab, name, key, flag)
            return bind(tab, "Dropdown", name, key, flag, {Options=ConfigService.Options[key]})
        end

        -- Same sidebar, tabs, sections and controls as the original interface.
        window:AddSidebarSection("Combat")
        local aim = window:AddTab({Name="Aimbot", Icon="🎯"})
        aim:AddSection({Title="Lock-On", Description="Hold right-click to activate."})
        toggle(aim, "Enabled", "Enabled", "a_en")
        toggle(aim, "Lock Players", "LockOnPlayers", "a_plr")
        toggle(aim, "Lock NPCs", "LockOnNPCs", "a_npc")
        toggle(aim, "Team Check", "TeamCheck", "a_team",
            "Strict: confirmed enemies only. Missing/conflicting teams are skipped; name-tag colors are ignored.")
        toggle(aim, "Wall Check", "WallCheck", "a_wall")
        toggle(aim, "High-Quality Visibility", "HighQualityVisibility", "a_wallhq",
            "Uses extra rays per sampled character. Higher CPU cost.")
        aim:AddDivider({Label="Targeting"})
        local partOptions = table.clone(ConfigService.Options.TargetPart)
        partOptions[#partOptions + 1] = "ClosestPart"
        local partControl = aim:AddDropdown({Name="Target Part", Options=partOptions, Flag="a_part",
            Default=ConfigService.Get("ClosestPart") and "ClosestPart" or ConfigService.Get("TargetPart"),
            Callback=function(value)
                if value == "ClosestPart" then ConfigService.Set("ClosestPart", true)
                elseif ConfigService.Set("TargetPart", value) then ConfigService.Set("ClosestPart", false) end
            end})
        local function refreshPart()
            partControl:Set(ConfigService.Get("ClosestPart") and "ClosestPart" or ConfigService.Get("TargetPart"), true)
        end
        ctx.maid:Give(ConfigService.OnChanged("TargetPart", refreshPart))
        ctx.maid:Give(ConfigService.OnChanged("ClosestPart", refreshPart))
        dropdown(aim, "FOV Method", "FOVMethod", "a_fmet")
        slider(aim, "FOV (px)", "FOV", "a_fov")
        slider(aim, "Range (0=∞)", "LockRange", "a_rng")
        slider(aim, "Extra Lead Time (s)", "Prediction", "a_pred", 0.01)

        aim:AddDivider({Label="Ballistic / Projectile"})
        toggle(aim, "Drop Compensation", "DropCompensation", "a_drop")
        local function projectileSpeed(value)
            if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return 500 end
            return math.clamp(value, 1, ConfigService.Ranges.BallisticSpeed[2])
        end
        local function applyProjectile(enabled, speed)
            ConfigService.Set("BallisticSpeed", enabled == true and projectileSpeed(speed) or 0)
        end
        local projectileToggle = aim:AddToggle({Name="Projectile Mode", Flag="a_balena",
            Description="Solves distance, target velocity and projectile travel time. Off = no speed-based lead.",
            Default=ConfigService.Get("BallisticSpeed") > 0,
            Callback=function(value) applyProjectile(value, CrispyLib.State.Get("a_bspd")) end})
        toggle(aim, "Auto Projectile Speed", "AutoProjectileSpeed", "a_bauto",
            "Read equipped gun config. Missing/conflicting values use the manual fallback below."):DependsOn(projectileToggle)
        local speedControl = aim:AddSlider({Name="Manual / Fallback Speed (st/s)", Flag="a_bspd",
            Description="Used when Auto is off or no unambiguous readable gun config is found. Drop uses Workspace.Gravity.",
            Min=1, Max=ConfigService.Ranges.BallisticSpeed[2], Step=1,
            Default=ConfigService.Get("BallisticSpeed") > 0 and ConfigService.Get("BallisticSpeed") or 500,
            Callback=function(value) applyProjectile(CrispyLib.State.Get("a_balena"), value) end})
        speedControl:DependsOn(projectileToggle)
        ctx.maid:Give(ConfigService.OnChanged("BallisticSpeed", function(value)
            projectileToggle:Set(value > 0, true)
            if value > 0 then speedControl:Set(value, true) end
        end))
        CoreUI.ProjectileStatusCard = aim:AddDataCard({Name="Projectile Speed", Value="Off",
            Description="Enable Projectile Mode", Subtext="studs / second"})
        function CoreUI.UpdateProjectileStatus()
            local info = WeaponScanner.GetStatus()
            local card = CoreUI.ProjectileStatusCard
            if info.mode == "off" then
                card:Set("Off"); card:SetSubtext("studs / second"); card:SetDescription("Enable Projectile Mode")
            else
                card:Set(string.format("%g", info.effectiveSpeed))
                if info.mode == "auto" then
                    card:SetSubtext("Auto config • studs/s")
                    card:SetDescription(info.tool.Name .. " / " .. info.field)
                elseif info.mode == "manual" then
                    card:SetSubtext("Manual • studs/s"); card:SetDescription("Automatic search disabled")
                else
                    card:SetSubtext("Fallback • studs/s"); card:SetDescription(info.reason:gsub("_", " "))
                end
            end
        end
        aim:AddButton({Name="Scan Equipped Gun", Callback=function()
            WeaponScanner.Scan(); CoreUI.UpdateProjectileStatus()
            print("[SwaX Core] " .. WeaponScanner.Describe()) -- full source path / fallback reason
        end})
        Scheduler.Add("UI.Projectile",0.5,CoreUI.UpdateProjectileStatus)
        CoreUI.UpdateProjectileStatus()
        aim:AddDivider({Label="Aim Settings"})
        dropdown(aim, "Aim Mode", "AimMode", "a_aimmode")
        slider(aim, "Smooth X", "SmoothX", "a_sx")
        slider(aim, "Smooth Y", "SmoothY", "a_sy")
        slider(aim, "Hit Chance %", "HitChance", "a_hc")

        local fov = window:AddTab({Name="FOV", Icon="⭕"})
        fov:AddSection({Title="FOV Circle"})
        toggle(fov, "Show", "ShowFOV", "f_show")
        toggle(fov, "Fill", "FOVFill", "f_fill")
        bind(fov, "ColorPicker", "Global Accent / ESP Color", "Accent", "ui_accent")
        local function applyAccent(color)
            window:SetAccent(color)
            local circle = VisualDebug.GetFOVCircle()
            if circle then circle.Color = color end
        end
        ctx.maid:Give(ConfigService.OnChanged("Accent", applyAccent))
        fov:AddSection({Title="Crosshair"})
        toggle(fov, "Crosshair", "Crosshair", "xh_on")
        dropdown(fov, "Style", "CrosshairStyle", "xh_sty")
        slider(fov, "Size", "CrosshairSize", "xh_sz")
        slider(fov, "Gap", "CrosshairGap", "xh_gap")
        slider(fov, "Thickness", "CrosshairThickness", "xh_thk")
        bind(fov, "ColorPicker", "Crosshair Color", "CrosshairColor", "xh_col")
        toggle(fov, "Outline", "CrosshairOutline", "xh_out")

        window:AddSidebarSection("Visuals")
        local esp = window:AddTab({Name="ESP", Icon="👁"})
        esp:AddSection({Title="ESP Options"})
        toggle(esp, "Boxes", "Box", "e_box")
        toggle(esp, "Names", "Name", "e_name")
        toggle(esp, "Health Bars", "Health", "e_hp")
        toggle(esp, "Tracers", "Tracers", "e_trc")
        toggle(esp, "Distance", "Distance", "e_dist")
        toggle(esp, "Skeleton", "Skeleton", "e_skel")
        toggle(esp, "Accurate Boxes", "AccurateBoxes", "e_accbox")
        toggle(esp, "Exact Eight-Corner Boxes", "ExactBoxes", "e_exactbox")
        esp:AddDivider({Label="Chams"})
        toggle(esp, "Chams", "Chams", "e_chams")
        toggle(esp, "Wall-Only Chams", "ChamsWallOnly", "e_chamswall")
        bind(esp, "ColorPicker", "Chams Fill Color", "ChamsColor", "e_chamsclr")
        bind(esp, "ColorPicker", "Chams Outline Color", "ChamsOutline", "e_chamsout")
        slider(esp, "Fill Transparency", "ChamsFillTransp", "e_chamsfill", 0.05)
        slider(esp, "Outline Transparency", "ChamsOutlineTransp", "e_chamsouttr", 0.05)
        local characterCard = esp:AddDataCard({Name="Registered Characters", Value=tostring(CharacterRegistry.Count())})
        Scheduler.Add("UI.Status", 1, function() characterCard:Set(tostring(CharacterRegistry.Count())) end)

        window:AddSidebarSection("Settings")
        local config = window:AddTab({Name="Config", Icon="💾"})
        config:AddSection({Title="Profiles"})
        CrispyLib.Config.CreateProfileUI(config)
        local function configAction(action)
            local ok, err = CrispyLib.Config[action]()
            if not ok and err ~= "config does not exist" then
                warn("[SwaX Core] Config " .. action .. ": " .. tostring(err))
            end
            return ok
        end
        config:AddDivider()
        config:AddButton({Name="Save", Callback=function() configAction("Save") end})
        config:AddButton({Name="Load", Callback=function() configAction("Load") end})
        config:AddButton({Name="Reset Core Settings", Callback=function()
            for key, value in pairs(ConfigService.Defaults) do ConfigService.Set(key, value, true) end
        end})
        config:AddDivider({Label="Script"})
        config:AddButton({Name="Force Rescan", Callback=CharacterRegistry.ForceRescan})
        config:AddButton({Name="Print Lock Log", Callback=LockController.PrintLog})
        config:AddButton({Name="Destroy Script", Description="Stops the core and cleans all owned resources. (End)",
            Callback=Runtime.Destroy})

        -- Capture the complete flag snapshot first: two composite controls share
        -- a runtime setting, and their silent refreshes also update Crispy state.
        function CoreUI.SyncSettings()
            if not ctx.alive then return end
            local values = {}
            for _, binding in ipairs(bindings) do values[binding.key] = CrispyLib.State.Get(binding.flag) end
            local part = CrispyLib.State.Get("a_part")
            local ballistic, speed = CrispyLib.State.Get("a_balena"), CrispyLib.State.Get("a_bspd")
            for _, binding in ipairs(bindings) do
                local value = values[binding.key]
                if value ~= nil then ConfigService.Set(binding.key, value, true) end
            end
            if part == "ClosestPart" then ConfigService.Set("ClosestPart", true, true)
            elseif part ~= nil and ConfigService.Set("TargetPart", part, true) then
                ConfigService.Set("ClosestPart", false, true)
            end
            applyProjectile(ballistic, speed)
            applyAccent(ConfigService.Get("Accent"))
        end
        -- Current library API covers Load, Apply, Import and profile switching,
        -- including loads with feature callbacks disabled; no method patches.
        ctx.maid:Give(CrispyLib.Config.OnApplied(CoreUI.SyncSettings))
        configAction("Load")
        assert(ctx.alive, "SwaX Core was unloaded while loading its config")
        CoreUI.SyncSettings()
        if type(CrispyLib.Config.AutoSave) == "function" then
            local token = CrispyLib.Config.AutoSave(30)
            if token then ctx.maid:Give(function()
                if CrispyLib.Config._autoSaveToken == token then CrispyLib.Config.StopAutoSave()
                elseif CrispyLib.Tasks and type(CrispyLib.Tasks.Cancel) == "function" then CrispyLib.Tasks:Cancel(token) end
            end) end
        end
        if CrispyLib.System and type(CrispyLib.System.StatsBar) == "function" and not CrispyLib.System._statsHandle then
            ctx.maid:Give(CrispyLib.System.StatsBar({FPS=true, Ping=true}))
        end
        ctx.maid:Give(ctx.services.UserInputService.InputBegan:Connect(function(input, processed)
            if not processed and not ctx.services.UserInputService:GetFocusedTextBox()
                and input.KeyCode == Enum.KeyCode.End then Runtime.Destroy() end
        end))
        loader:SetStatus("Core ready — hold right-click to lock")
        loader:SetProgress(1)
        loader:Finish()
        Runtime.Loader = nil
    end

    return CoreUI
end

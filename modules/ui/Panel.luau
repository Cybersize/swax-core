-- ui/Panel: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, Runtime, CharacterRegistry, Scheduler, LockController)
    local UserInputService=ctx.services.UserInputService
    local Workspace=ctx.services.Workspace
    local LocalPlayer=ctx.localPlayer
    -- Native, dependency-free controls. Right Shift hides the panel; End unloads.
    local CoreUI = {}
    function CoreUI.Init()
        local palette = {bg=Color3.fromRGB(19,22,27), row=Color3.fromRGB(28,32,39),
            text=Color3.fromRGB(235,238,243), muted=Color3.fromRGB(156,166,182)}
        local function create(class, props, parent)
            local object = Instance.new(class)
            for key, value in pairs(props) do object[key] = value end
            object.Parent = parent
            return object
        end
        local function corner(parent, radius)
            create("UICorner", {CornerRadius=UDim.new(0,radius or 6)}, parent)
        end
        local gui = create("ScreenGui", {Name="SwaXCoreUI", ResetOnSpawn=false,
            IgnoreGuiInset=true, ZIndexBehavior=Enum.ZIndexBehavior.Sibling, DisplayOrder=30}, LocalPlayer:WaitForChild("PlayerGui"))
        ctx.maid:Give(gui)
        Runtime.GUI = gui
        local panel = create("Frame", {Name="Panel", Size=UDim2.fromOffset(390,520),
            Position=UDim2.fromOffset(24,80), BackgroundColor3=palette.bg, BorderSizePixel=0}, gui)
        corner(panel,10)
        create("UIStroke", {Color=Color3.fromRGB(53,62,75),Thickness=1},panel)
        local scale = create("UIScale", {Scale=1}, panel)
        local function resize()
            local camera = Workspace.CurrentCamera
            if camera then scale.Scale=math.clamp(math.min(camera.ViewportSize.X/430,camera.ViewportSize.Y/580),0.4,1) end
        end
        resize()
        local title = create("TextLabel", {Size=UDim2.new(1,-32,0,28), Position=UDim2.fromOffset(16,12),
            BackgroundTransparency=1, Text="SwaX / CORE", TextColor3=palette.text,
            Font=Enum.Font.GothamBold, TextSize=19, TextXAlignment=Enum.TextXAlignment.Left},panel)
        create("TextLabel", {Size=UDim2.new(1,-32,0,20), Position=UDim2.fromOffset(16,42),
            BackgroundTransparency=1, Text="Hold right-click to lock • Right Shift to hide", TextColor3=palette.muted,
            Font=Enum.Font.Gotham, TextSize=12, TextXAlignment=Enum.TextXAlignment.Left},panel)
        local tabs = create("Frame", {Size=UDim2.new(1,-32,0,32),Position=UDim2.fromOffset(16,72),BackgroundTransparency=1},panel)
        local pages, buttons = {}, {}
        local function button(parent, text, size, position)
            local b=create("TextButton",{Size=size,Position=position,Text=text,TextSize=12,
                Font=Enum.Font.GothamMedium,TextColor3=palette.text,BackgroundColor3=palette.row,
                BorderSizePixel=0,AutoButtonColor=true},parent)
            corner(b)
            return b
        end
        for i,name in ipairs({"Aim","Visuals"}) do
            local page=create("ScrollingFrame",{Name=name,Size=UDim2.new(1,-32,1,-175),Position=UDim2.fromOffset(16,114),
                BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,CanvasSize=UDim2.new(),
                AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y},panel)
            create("UIListLayout",{Padding=UDim.new(0,6),SortOrder=Enum.SortOrder.LayoutOrder},page)
            pages[name]=page
            local b=button(tabs,name,UDim2.new(0.5,-4,1,0),UDim2.new((i-1)*0.5,(i-1)*4,0,0))
            buttons[name]=b
            ctx.maid:Give(b.Activated:Connect(function()
                for key,p in pairs(pages) do p.Visible=key==name end
                for key,t in pairs(buttons) do t.BackgroundColor3=key==name and ConfigService.Get("Accent") or palette.row end
            end))
            page.Visible=i==1
        end
        buttons.Aim.BackgroundColor3=ConfigService.Get("Accent")
        local order=0
        local function row(page,label)
            order+=1
            local r=create("Frame",{Size=UDim2.new(1,-7,0,36),BackgroundColor3=palette.row,BorderSizePixel=0,LayoutOrder=order},pages[page])
            corner(r)
            create("TextLabel",{Size=UDim2.new(1,-140,1,0),Position=UDim2.fromOffset(10,0),BackgroundTransparency=1,
                Text=label,TextSize=12,Font=Enum.Font.Gotham,TextColor3=palette.text,TextXAlignment=Enum.TextXAlignment.Left,
                TextTruncate=Enum.TextTruncate.AtEnd},r)
            return r
        end
        local function watch(key,callback)
            callback(ConfigService.Get(key))
            ctx.maid:Give(ConfigService.OnChanged(key,callback))
        end
        local function toggle(page,label,key)
            local r=row(page,label)
            local b=button(r,"",UDim2.fromOffset(116,26),UDim2.new(1,-122,0,5))
            watch(key,function(value)
                b.Text=value and "ON" or "OFF"
                b.TextColor3=value and ConfigService.Get("Accent") or palette.muted
            end)
            ctx.maid:Give(b.Activated:Connect(function() ConfigService.Set(key,not ConfigService.Get(key)) end))
        end
        local function number(page,label,key,step)
            local r=row(page,label)
            local down=button(r,"−",UDim2.fromOffset(24,26),UDim2.new(1,-122,0,5))
            local field=create("TextBox",{Size=UDim2.fromOffset(62,26),Position=UDim2.new(1,-96,0,5),Text="",ClearTextOnFocus=false,
                BackgroundColor3=palette.bg,TextColor3=palette.text,TextSize=12,Font=Enum.Font.Code,BorderSizePixel=0},r)
            corner(field)
            local up=button(r,"+",UDim2.fromOffset(24,26),UDim2.new(1,-32,0,5))
            local function refresh(value) field.Text=string.format("%g",value) end
            watch(key,refresh)
            ctx.maid:Give(field.FocusLost:Connect(function()
                local value=tonumber(field.Text)
                if value then ConfigService.Set(key,value) end
                refresh(ConfigService.Get(key))
            end))
            ctx.maid:Give(down.Activated:Connect(function() ConfigService.Set(key,ConfigService.Get(key)-step) end))
            ctx.maid:Give(up.Activated:Connect(function() ConfigService.Set(key,ConfigService.Get(key)+step) end))
        end
        local function cycle(page,label,key)
            local r=row(page,label)
            local b=button(r,"",UDim2.fromOffset(116,26),UDim2.new(1,-122,0,5))
            watch(key,function(value) b.Text=value end)
            ctx.maid:Give(b.Activated:Connect(function()
                local options=ConfigService.Options[key]
                ConfigService.Set(key,options[((table.find(options,ConfigService.Get(key)) or 0)%#options)+1])
            end))
        end
        for _,item in ipairs({{"Enabled","Enabled"},{"Players","LockOnPlayers"},{"NPCs","LockOnNPCs"},
            {"Team check","TeamCheck"},{"Wall check","WallCheck"},{"Detailed wall checks","HighQualityVisibility"}}) do toggle("Aim",item[1],item[2]) end
        cycle("Aim","Aim output","AimMode")
        cycle("Aim","Target region","TargetPart")
        toggle("Aim","Closest region","ClosestPart")
        cycle("Aim","FOV origin","FOVMethod")
        number("Aim","FOV radius","FOV",25)
        number("Aim","Range (0 = unlimited)","LockRange",100)
        number("Aim","Prediction (seconds)","Prediction",0.01)
        number("Aim","Smooth X (%)","SmoothX",5)
        number("Aim","Smooth Y (%)","SmoothY",5)
        number("Aim","Hit chance (%)","HitChance",5)
        number("Aim","Projectile speed (0 = off)","BallisticSpeed",100)
        toggle("Aim","Projectile drop correction","DropCompensation")
        for _,item in ipairs({{"FOV circle","ShowFOV"},{"Filled FOV","FOVFill"},{"Crosshair","Crosshair"},
            {"Crosshair outline","CrosshairOutline"},{"Boxes","Box"},{"Names","Name"},{"Health bars","Health"},
            {"Distance","Distance"},{"Tracers","Tracers"},{"Skeleton","Skeleton"},{"Accurate boxes","AccurateBoxes"},
            {"Eight-corner boxes","ExactBoxes"},{"Chams","Chams"},{"Wall-only chams","ChamsWallOnly"}}) do toggle("Visuals",item[1],item[2]) end
        cycle("Visuals","Crosshair style","CrosshairStyle")
        number("Visuals","Crosshair size","CrosshairSize",1)
        number("Visuals","Crosshair gap","CrosshairGap",1)
        number("Visuals","Crosshair thickness","CrosshairThickness",1)
        number("Visuals","Chams fill transparency","ChamsFillTransp",0.05)
        number("Visuals","Chams outline transparency","ChamsOutlineTransp",0.05)
        local status=create("TextLabel",{Size=UDim2.new(1,-32,0,19),Position=UDim2.new(0,16,1,-50),BackgroundTransparency=1,
            Text="Ready",TextColor3=palette.muted,TextSize=11,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,
            TextTruncate=Enum.TextTruncate.AtEnd},panel)
        local reset=button(panel,"Reset",UDim2.fromOffset(72,22),UDim2.new(0,16,1,-27))
        local close=button(panel,"Unload (End)",UDim2.fromOffset(116,22),UDim2.new(1,-132,1,-27))
        ctx.maid:Give(reset.Activated:Connect(function()
            for key,value in pairs(ConfigService.Defaults) do ConfigService.Set(key,value) end
        end))
        ctx.maid:Give(close.Activated:Connect(Runtime.Destroy))
        Scheduler.Add("UI.Status",0.5,function()
            local locked=LockController.GetLockedTarget()
            status.Text=string.format("%d characters  /  %s",CharacterRegistry.Count(),locked and ("Locked: "..locked.name) or "Ready")
            resize()
        end)
        ctx.maid:Give(UserInputService.InputBegan:Connect(function(input,processed)
            if processed or UserInputService:GetFocusedTextBox() then return end
            if input.KeyCode==Enum.KeyCode.RightShift then panel.Visible=not panel.Visible
            elseif input.KeyCode==Enum.KeyCode.End then Runtime.Destroy() end
        end))
        -- Header dragging; only one global movement listener is owned by the app.
        local dragging, origin, start
        ctx.maid:Give(title.InputBegan:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then
                dragging,origin,start=true,input.Position,panel.Position
            end
        end))
        ctx.maid:Give(UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then
                local delta=input.Position-origin
                panel.Position=UDim2.new(start.X.Scale,start.X.Offset+delta.X,start.Y.Scale,start.Y.Offset+delta.Y)
            end
        end))
        ctx.maid:Give(UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
        end))
        ctx.maid:Give(gui.Destroying:Connect(Runtime.Destroy))
    end


    return CoreUI
end

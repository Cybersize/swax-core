do
    local Scanner=components.weapons
    local function fixture(fn)
        local oldChar=player.Character
        local old={speed=ConfigService.Get("BallisticSpeed"),auto=ConfigService.Get("AutoProjectileSpeed"),
            prediction=ConfigService.Get("Prediction"),drop=ConfigService.Get("DropCompensation")}
        local char=Instance.new("Model");char.Name="WeaponTestCharacter";char.Parent=workspace;player.Character=char
        local tool=Instance.new("Tool");tool.Name="TestRifle";tool.Parent=char
        ConfigService.Set("AutoProjectileSpeed",true);ConfigService.Set("BallisticSpeed",500)
        local f={char=char,tool=tool}
        function f:value(name,value,class,parent)
            local object=Instance.new(class or "NumberValue");object.Name=name;object.Value=value;object.Parent=parent or tool
            return object
        end
        local ok,err=pcall(fn,f)
        char:Destroy();player.Character=oldChar
        ConfigService.Set("BallisticSpeed",old.speed);ConfigService.Set("AutoProjectileSpeed",old.auto)
        ConfigService.Set("Prediction",old.prediction);ConfigService.Set("DropCompensation",old.drop)
        Scanner.GetStatus() -- drop all watchers/references to the unequipped fixture
        assert(ok,err)
    end
    local function test(name,fn) check(name,function() fixture(fn) end) end
    local function expectFallback(reason)
        local info=Scanner.GetStatus()
        assert(info.mode=="manual_fallback" and info.effectiveSpeed==500 and info.speed==nil)
        if reason then assert(info.reason==reason,info.reason) end
    end

    test("Equipped Tool BulletSpeed attributes are used automatically",function(f)
        f.tool:SetAttribute("BulletSpeed",1200)
        local speed,mode=Scanner.GetEffectiveSpeed();assert(speed==1200 and mode=="auto")
    end)
    test("Official-style Configuration/BulletSpeed NumberValues are discovered",function(f)
        local config=Instance.new("Configuration");config.Name="Configuration";config.Parent=f.tool
        f:value("BulletSpeed",1800,"NumberValue",config)
        assert(Scanner.GetEffectiveSpeed()==1800)
        assert(Scanner.GetStatus().source:find("Configuration.BulletSpeed.Value",1,true))
    end)
    test("Nested gun configuration attributes are scanned",function(f)
        local config=Instance.new("Folder");config.Name="Settings";config.Parent=f.tool;config:SetAttribute("ProjectileSpeed",750)
        assert(Scanner.GetEffectiveSpeed()==750)
    end)
    test("Recognized speed aliases normalize case and separators only",function(f)
        for _,key in ipairs({"bullet_speed","PROJECTILE-SPEED","MuzzleVelocity","bulletVelocity"}) do
            f.tool:SetAttribute(key,950);Scanner.Scan();assert(Scanner.GetEffectiveSpeed()==950)
            f.tool:SetAttribute(key,nil)
        end
    end)
    test("Generic speed, movement speed and tracer speed are not treated as bullet speed",function(f)
        f.tool:SetAttribute("Speed",999);f.tool:SetAttribute("WalkSpeed",16);f.tool:SetAttribute("TracerSpeed",300)
        expectFallback("no_readable_speed_config")
    end)
    test("Unequipped Backpack weapons are not used as the current gun",function(f)
        local backpack=Instance.new("Backpack");backpack.Parent=player
        local other=Instance.new("Tool");other:SetAttribute("BulletSpeed",9000);other.Parent=backpack
        expectFallback("no_readable_speed_config");backpack:Destroy()
    end)
    test("Other world weapons cannot supply the equipped gun's speed",function(f)
        local other=Instance.new("Tool");other:SetAttribute("BulletSpeed",9000);other.Parent=workspace
        expectFallback("no_readable_speed_config");other:Destroy()
    end)
    test("String numbers are not silently converted into speed values",function(f)
        f:value("BulletSpeed","1200","StringValue");expectFallback("invalid_speed_value")
    end)
    test("Zero, negative, nonfinite, vector and excessive speeds use manual fallback",function(f)
        for _,value in ipairs({0,-1,math.huge,0/0,Scanner.MAX_SPEED+1,Vector3.new(100,0,0),false}) do
            f.tool:SetAttribute("BulletSpeed",value);Scanner.Scan();expectFallback("invalid_speed_value")
        end
    end)
    test("Duplicate agreeing config values are accepted",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);f:value("ProjectileSpeed",1000)
        assert(Scanner.GetEffectiveSpeed()==1000 and Scanner.GetStatus().matches==2)
    end)
    test("Conflicting fire-mode/config values are reported, not averaged",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);f:value("ProjectileSpeed",1500)
        expectFallback("conflicting_speed_values")
    end)
    test("Explicit studs-per-second units are supported",function(f)
        f.tool:SetAttribute("BulletSpeed",1000)
        for _,unit in ipairs({"studs/s","stud/s","studs/sec","studs per second"}) do
            f.tool:SetAttribute("BulletSpeedUnits",unit);Scanner.Scan();assert(Scanner.GetEffectiveSpeed()==1000)
        end
    end)
    test("Meters/second metadata is rejected instead of guessed or silently converted",function(f)
        f.tool:SetAttribute("MuzzleVelocity",900);f.tool:SetAttribute("MuzzleVelocityUnits","m/s")
        expectFallback("unsupported_or_conflicting_units")
    end)
    test("Sibling unit ValueObjects apply to the speed config",function(f)
        f:value("BulletSpeed",1400);f:value("SpeedUnits","studs/s","StringValue")
        assert(Scanner.GetEffectiveSpeed()==1400)
    end)
    test("Changing declared units immediately invalidates the cached detection",function(f)
        f.tool:SetAttribute("BulletSpeed",1400);f.tool:SetAttribute("SpeedUnits","studs/s")
        assert(Scanner.GetEffectiveSpeed()==1400)
        f.tool:SetAttribute("SpeedUnits","m/s");expectFallback("unsupported_or_conflicting_units")
    end)
    test("Changing a gun's speed attribute updates without waiting for polling",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        f.tool:SetAttribute("BulletSpeed",1600);assert(Scanner.GetEffectiveSpeed()==1600)
    end)
    test("Changing NumberValue speed updates immediately",function(f)
        local value=f:value("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        value.Value=1900;assert(Scanner.GetEffectiveSpeed()==1900)
    end)
    test("Renaming a speed config cannot leave its old speed active",function(f)
        local value=f:value("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        value.Name="UnrelatedSpeed";expectFallback("no_readable_speed_config")
    end)
    test("Newly replicated speed config triggers a fresh scan",function(f)
        expectFallback("no_readable_speed_config")
        local value=f:value("BulletSpeed",1500);f.tool.DescendantAdded:Fire(value)
        assert(Scanner.GetEffectiveSpeed()==1500)
    end)
    test("Removed config clears the previous automatic speed",function(f)
        local value=f:value("BulletSpeed",1500);assert(Scanner.GetEffectiveSpeed()==1500)
        f.tool.DescendantRemoving:Fire(value);value.Parent=nil
        expectFallback("no_readable_speed_config");value:Destroy()
    end)
    test("Gun switches never reuse the old gun's speed",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        f.tool.Parent=workspace
        local other=Instance.new("Tool");other:SetAttribute("BulletSpeed",2500);other.Parent=f.char
        assert(Scanner.GetEffectiveSpeed()==2500);f.tool:Destroy()
    end)
    test("Unequipping immediately discards automatic speed",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        f.tool.Parent=workspace;expectFallback("no_equipped_tool");f.tool:Destroy()
    end)
    test("Respawns cannot reuse a previous character's gun config",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);assert(Scanner.GetEffectiveSpeed()==1000)
        local replacement=Instance.new("Model");replacement.Parent=workspace;player.Character=replacement
        expectFallback("no_equipped_tool");replacement:Destroy()
    end)
    test("Multiple equipped Tools are ambiguous rather than first-child wins",function(f)
        f.tool:SetAttribute("BulletSpeed",1000)
        local other=Instance.new("Tool");other:SetAttribute("BulletSpeed",2500);other.Parent=f.char
        expectFallback("multiple_equipped_tools")
    end)
    test("Turning Auto off uses the exact manual value",function(f)
        f.tool:SetAttribute("BulletSpeed",1500);assert(Scanner.GetEffectiveSpeed()==1500)
        ConfigService.Set("AutoProjectileSpeed",false)
        local speed,mode=Scanner.GetEffectiveSpeed();assert(speed==500 and mode=="manual")
    end)
    test("Automatic detection never overwrites the saved manual fallback",function(f)
        f.tool:SetAttribute("BulletSpeed",1500);assert(Scanner.GetEffectiveSpeed()==1500)
        assert(ConfigService.Get("BallisticSpeed")==500 and mockCrispy.controls.a_bspd:Get()==500)
    end)
    test("Discovery cannot silently enable Projectile Mode",function(f)
        f.tool:SetAttribute("BulletSpeed",1500);ConfigService.Set("BallisticSpeed",0)
        assert(Scanner.Scan()==1500)
        local speed,mode=Scanner.GetEffectiveSpeed();assert(speed==0 and mode=="off")
    end)
    test("Valid automatic speeds above the manual slider limit are not clamped",function(f)
        f.tool:SetAttribute("BulletSpeed",20000);assert(Scanner.GetEffectiveSpeed()==20000)
    end)
    test("Oversized config trees fail to manual instead of trusting a partial search",function(f)
        f.tool:SetAttribute("BulletSpeed",1500)
        for _=1,Scanner.MAX_NODES do local node=Instance.new("Folder");node.Parent=f.tool end
        expectFallback("scan_limit");assert(Scanner.GetStatus().examined<=Scanner.MAX_NODES)
    end)
    test("Config traversal depth is bounded",function(f)
        f.tool:SetAttribute("BulletSpeed",1500)
        local parent=f.tool
        for _=1,Scanner.MAX_DEPTH+1 do local node=Instance.new("Folder");node.Parent=parent;parent=node end
        expectFallback("scan_limit")
    end)
    test("ModuleScript source is not executed or parsed as active gun configuration",function(f)
        local module=Instance.new("ModuleScript");module.Name="GunConfig";module.Source="error('must not execute'); return {BulletSpeed=1500}"
        module.Parent=f.tool;expectFallback("no_readable_speed_config")
    end)
    test("Original UI displays the detected source and keeps its Auto toggle synchronized",function(f)
        f.tool:SetAttribute("BulletSpeed",1350)
        components.ui.UpdateProjectileStatus()
        local card=components.ui.ProjectileStatusCard
        assert(card.value=="1350" and card.subtext:find("Auto config",1,true) and card.description:find("TestRifle / BulletSpeed",1,true))
        mockCrispy.controls.a_bauto:Set(false);assert(not ConfigService.Get("AutoProjectileSpeed"))
        components.ui.UpdateProjectileStatus();assert(card.value=="500" and card.subtext:find("Manual",1,true))
    end)
    test("Profile loads reapply the automatic-speed preference",function(f)
        mockCrispy.Config.Apply({a_bauto=false},{Callbacks=false});flush()
        assert(not ConfigService.Get("AutoProjectileSpeed"))
        mockCrispy.Config.Apply({a_bauto=true},{Callbacks=false});flush()
        assert(ConfigService.Get("AutoProjectileSpeed"))
    end)
    test("Scan button reports conflicts and keeps the manual fallback visible",function(f)
        f.tool:SetAttribute("BulletSpeed",1000);f:value("ProjectileSpeed",1500)
        Runtime.Window._tabs[1].buttons["Scan Equipped Gun"]()
        local card=components.ui.ProjectileStatusCard
        assert(card.value=="500" and card.subtext:find("Fallback",1,true) and card.description:find("conflicting speed values",1,true))
    end)
    test("The real projectile selector consumes automatic speed, not the fallback",function(f)
        local rig=Instance.new("Model");rig.Parent=workspace
        local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(100,0,0);head.Parent=rig
        local root=Instance.new("Part");root.Name="HumanoidRootPart";root.Position=head.Position;root.AssemblyLinearVelocity=Vector3.new(50,0,0)
        root.Parent=rig;rig.PrimaryPart=root
        local frame=Camera.CFrame;Camera.CFrame=CFrame.new()
        ConfigService.Set("Prediction",0);ConfigService.Set("DropCompensation",false);ConfigService.Set("BallisticSpeed",1000)
        f.tool:SetAttribute("BulletSpeed",100)
        vectorNear(TargetSelector.PredictPos(rig),Vector3.new(200,0,0),1e-5)
        ConfigService.Set("AutoProjectileSpeed",false)
        vectorNear(TargetSelector.PredictPos(rig),Vector3.new(100+50*100/950,0,0),1e-5)
        Camera.CFrame=frame;rig:Destroy()
    end)
    test("Automatic scanning is scheduled at bounded 500ms intervals",function(f)
        assert(Scheduler.names["Weapon.Scan"].interval==0.5 and Scheduler.names["UI.Projectile"].interval==0.5)
        f.tool:SetAttribute("BulletSpeed",1500);Scanner.Update();assert(Scanner.GetStatus().speed==1500)
    end)
end

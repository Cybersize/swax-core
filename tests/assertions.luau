flush()
check("Native UI starts without downloading code",function() assert(Runtime.GUI and Runtime.GUI.Parent==pg) end)
check("Core-only configuration",function() assert(ConfigService.Get("AutoHeal")==nil and ConfigService.Get("SpeedHack")==nil) end)
check("Reject unknown settings",function() assert(not ConfigService.Set("Missing",true)) end)
check("Reject wrong setting types",function() assert(not ConfigService.Set("FOV","invalid")) end)
check("Reject nonfinite settings",function() assert(not ConfigService.Set("FOV",0/0) and not ConfigService.Set("FOV",math.huge)) end)
check("Clamp numeric settings",function() ConfigService.Set("FOV",99999);assert(ConfigService.Get("FOV")==1000) end)
check("Validate enum settings",function() assert(not ConfigService.Set("TargetPart","Weapon") and not ConfigService.Set("AimMode","Invalid")) end)
check("Setting subscriptions can disconnect",function()
    local count=0;local off=ConfigService.OnChanged("FOV",function() count+=1 end)
    ConfigService.Set("FOV",200);off();ConfigService.Set("FOV",201);assert(count==1)
end)
check("Maid cleanup is idempotent",function()
    local m=Maid.new();local count=0;m:Give(function() count+=1 end);m:Clean();m:Clean();assert(count==1)
end)
check("Maid supports nested cleanable resources",function()
    local m=Maid.new();local count=0;m:Give({Clean=function() count+=1 end});m:Clean();assert(count==1)
end)
check("Scheduler prevents duplicate names and callback overlap",function()
    local oldJobs,oldNames=Scheduler.jobs,Scheduler.names;Scheduler.jobs={};Scheduler.names={}
    local count=0;Scheduler.Add("test",0,function() count+=1;Scheduler.Step(0.1) end)
    assert(not pcall(Scheduler.Add,"test",0,function() end));Scheduler.Step(0.1);assert(count==1)
    Scheduler.jobs,Scheduler.names=oldJobs,oldNames
end)
check("Stable lock retains its current valid target",function()
    local original=TargetSelector.GetBestTarget;local a={char={},name="A"};local b={char={},name="B"}
    TargetSelector.GetBestTarget=function() return a,nil end;LockController.SetActive(true)
    assert(LockController.GetLockedTarget()==a)
    TargetSelector.GetBestTarget=function() return b,a end;LockController.Update();assert(LockController.GetLockedTarget()==a)
    LockController.SetActive(false);TargetSelector.GetBestTarget=original;assert(LockController.GetLockedTarget()==nil)
end)
check("Focus loss releases lock",function()
    local original=TargetSelector.GetBestTarget;TargetSelector.GetBestTarget=function() return {char={},name="A"},nil end
    LockController.SetActive(true);game:GetService("UserInputService").WindowFocusReleased:Fire()
    assert(LockController.GetLockedTarget()==nil);TargetSelector.GetBestTarget=original
end)
local rig=Instance.new("Model");rig.Name="TestRig";rig.Parent=workspace
local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(2,6,3);head.Parent=rig
check("Resolve head without a Humanoid",function() assert(GeometryService.GetAimPos(rig,"Head")==head.Position) end)
check("Cached head reads its live position",function() head.Position=Vector3.new(8,9,10);assert(GeometryService.GetAimPos(rig,"Head")==head.Position) end)
local animated=Instance.new("Model");animated.Name="AnimatedRig";animated.Parent=workspace
local driver=Instance.new("Part");driver.Name="Driver";driver.Parent=animated
local bone=Instance.new("Bone");bone.Name="mixamorig:Head";bone.TransformedWorldCFrame=CFrame.new(5,7,9);bone.Parent=driver
check("Custom head uses the animated bone",function() assert(GeometryService.GetAimPos(animated,"Head")==bone.TransformedWorldCFrame.Position) end)
check("Animated pose updates do not wait for a cache rescan",function()
    bone.TransformedWorldCFrame=CFrame.new(6,2,9);assert(GeometryService.GetAimPos(animated,"Head")==bone.TransformedWorldCFrame.Position)
end)
check("Nil character is safe",function() assert(GeometryService.GetAimPos(nil,"Head")==nil) end)
check("Reset restores every default",function()
    for k,v in pairs(ConfigService.Defaults) do ConfigService.Set(k,v) end
    for k,v in pairs(ConfigService.Defaults) do assert(ConfigService.Get(k)==v,k) end
end)
rig:Destroy();animated:Destroy()
check("Unload clears the UI, render binding and scheduler",function()
    Runtime.Destroy();Runtime.Destroy();assert(not Context.alive and Runtime.GUI.Parent==nil and next(bindings)==nil and #Scheduler.jobs==0)
end)
check("Unload disconnects all owned signal listeners",function()
    for _,s in ipairs(allSignals) do for _,c in ipairs(s.listeners) do assert(not c.Connected,"Leaked signal listener") end end
end)

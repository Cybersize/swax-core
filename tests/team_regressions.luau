-- Real resolver/registry/selection/aim code; deterministic engine fixtures.
do
    local TeamService=components.teams
    local Players,Teams=game:GetService("Players"),game:GetService("Teams")
    local fields={"TeamId","TeamID","FactionId","FactionID","Team","Faction"}
    local function fixture(fn)
        local old={character=player.Character,team=player.Team,neutral=player.Neutral,subject=Camera.CameraSubject}
        local attributes={};for _,key in ipairs(fields) do attributes[key]=player:GetAttribute(key);player:SetAttribute(key,nil) end
        local ours=Instance.new("Model");ours.Name="LocalRig";ours.Parent=workspace;player.Character=ours
        local char=Instance.new("Model");char.Name="OtherRig";char.Parent=workspace
        local head=Instance.new("Part");head.Name="Head";head.Position=Vector3.new(10,0,-100);head.Parent=char
        local other=Instance.new("Player");other.Name="Other";other.DisplayName="Other";other.UserId=2;other.Character=char;other.Parent=Players
        local a=Instance.new("Team");a.Name="Red";a.Parent=Teams
        local b=Instance.new("Team");b.Name="Blue";b.Parent=Teams
        player.Team=a;player.Neutral=false;other.Team=b;other.Neutral=false
        Players.PlayerAdded:Fire(other)
        local f={ours=ours,char=char,other=other,a=a,b=b,head=head}
        function f:custom()
            player.Team=nil;self.other.Team=nil;player.Neutral=true;self.other.Neutral=true
        end
        local ok,err=pcall(fn,f)
        TeamService.SetAdapter(nil);ConfigService.Set("TeamCheck",false);LockController.SetActive(false);AimController.ClearTarget()
        Players.PlayerRemoving:Fire(other)
        other:Destroy();char:Destroy();ours:Destroy();a:Destroy();b:Destroy()
        player.Character=old.character;player.Team=old.team;player.Neutral=old.neutral;Camera.CameraSubject=old.subject
        for _,key in ipairs(fields) do player:SetAttribute(key,attributes[key]) end
        assert(ok,err)
    end
    local function test(name,fn) check(name,function() fixture(fn) end) end

    test("Native team identity distinguishes allies and enemies",function(f)
        assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        f.other.Team=f.a;assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        assert(CharacterRegistry.IsTeammate(f.char) and not CharacterRegistry.IsEnemy(f.char))
        assert(CharacterRegistry.GetRelationship(f.ours)=="Self")
    end)
    test("Equal team names/colors do not collapse different Team objects",function(f)
        f.b.Name=f.a.Name;f.a.TeamColor="same";f.b.TeamColor="same"
        assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("Neutral players do not use stale native Team references",function(f)
        f.other.Neutral=true;assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        f.other.Neutral=false;player.Neutral=true;assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("Missing or destroyed native teams remain Unknown",function(f)
        f.other.Team=nil;assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        f.other.Team=f.b;f.b:Destroy();assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("Name-tag colours cannot override native teams",function(f)
        local tag=Instance.new("ScreenGui");tag.Name="NameTagGui";tag.Parent=f.char
        local label=Instance.new("TextLabel");label.Name="PlayerTag";label.Visible=true
        label.TextColor3=Color3.fromRGB(0,255,234);label.Parent=tag
        assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        f.other.Team=f.a;label.Visible=false;label.TextColor3=Color3.fromRGB(255,0,0)
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
    end)
    test("A name tag alone never proves an enemy or ally",function(f)
        f:custom()
        local tag=Instance.new("ScreenGui");tag.Name="NameTagGui";tag.Parent=f.char
        local label=Instance.new("TextLabel");label.Name="PlayerTag";label.Visible=true
        label.TextColor3=Color3.fromRGB(0,255,234);label.Parent=tag
        assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        assert(not CharacterRegistry.IsEnemy(f.char) and not CharacterRegistry.IsTeammate(f.char))
    end)
    test("Matching custom faction attributes resolve live, including neutral games",function(f)
        f:custom();player:SetAttribute("FactionId",7);f.char:SetAttribute("FactionId",7)
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        f.char:SetAttribute("FactionId",8);assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("String faction fields are exact and case-sensitive",function(f)
        f:custom();player:SetAttribute("Faction","Blue");f.other:SetAttribute("Faction","Blue")
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        f.other:SetAttribute("Faction","blue");assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("Zero faction IDs are preserved rather than discarded as absent",function(f)
        f:custom();player:SetAttribute("TeamId",0);f.other:SetAttribute("TeamId",0)
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        f.other:SetAttribute("TeamId",1);assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("String/number ID mismatches and one-sided fields remain Unknown",function(f)
        f:custom();player:SetAttribute("TeamId",7)
        assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        f.other:SetAttribute("TeamId","7");assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("Empty, boolean and nonfinite faction values fail closed",function(f)
        f:custom();player:SetAttribute("TeamId",1)
        for _,value in ipairs({"", "   ", false, math.huge, 0/0, 1.5}) do
            f.other:SetAttribute("TeamId",value);assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        end
    end)
    test("Native and custom sources that disagree are not guessed",function(f)
        player:SetAttribute("FactionId",3);f.other:SetAttribute("FactionId",3)
        local relation,reason=CharacterRegistry.GetRelationship(f.char)
        assert(relation=="Unknown" and reason=="conflicting_team_sources")
    end)
    test("Incomplete custom fields cannot silently override a native relationship",function(f)
        player:SetAttribute("FactionID",1)
        assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("Conflicting player/character fields remain Unknown",function(f)
        f:custom();player:SetAttribute("TeamID",1);f.other:SetAttribute("TeamID",2);f.char:SetAttribute("TeamID",1)
        assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("Direct ValueObjects support custom teams without recursive UI guesses",function(f)
        f:custom()
        local a=Instance.new("StringValue");a.Name="Faction";a.Value="A";a.Parent=player
        local b=Instance.new("StringValue");b.Name="Faction";b.Value="B";b.Parent=f.char
        assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        b.Value="A";assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        a:Destroy()
    end)
    test("Attribute/ValueObject disagreement is treated as a conflict",function(f)
        f:custom();player:SetAttribute("TeamId",1);f.other:SetAttribute("TeamId",1)
        local value=Instance.new("IntValue");value.Name="TeamId";value.Value=2;value.Parent=f.char
        assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
    end)
    test("ObjectValue factions compare live instance identity",function(f)
        f:custom()
        local a=Instance.new("ObjectValue");a.Name="Faction";a.Value=f.a;a.Parent=player
        local b=Instance.new("ObjectValue");b.Name="Faction";b.Value=f.a;b.Parent=f.char
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        b.Value=f.b;assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        f.b:Destroy();assert(CharacterRegistry.GetRelationship(f.char)=="Unknown");a:Destroy()
    end)
    test("Custom characters can use camera-subject faction data",function(f)
        f:custom();player.Character=nil
        local subject=Instance.new("Part");subject.Parent=f.ours;Camera.CameraSubject=subject
        f.ours:SetAttribute("FactionID",4);f.char:SetAttribute("FactionID",4)
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        f.char:SetAttribute("FactionID",5);assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("Unmapped custom rigs do not borrow teams by username",function(f)
        local custom=Instance.new("Model");custom.Name=f.other.Name;custom.Parent=workspace
        assert(TeamService.Resolve(custom,f.other)=="Unknown")
        custom:Destroy()
    end)
    test("Custom local respawns immediately use the new character's faction",function(f)
        f:custom();f.ours:SetAttribute("FactionId",1);f.char:SetAttribute("FactionId",1)
        assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        local replacement=Instance.new("Model");replacement.Parent=workspace;replacement:SetAttribute("FactionId",2)
        player.Character=replacement;assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        replacement:Destroy()
    end)
    test("Respawns and native team changes are read without stale relationship caches",function(f)
        f.other.Team=f.a;assert(CharacterRegistry.GetRelationship(f.char)=="Ally")
        f.other.Team=f.b;assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        f.other.Character=nil;assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        f.other.Character=f.char;assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)
    test("Stale registered owner mappings cannot be rescued by old faction attributes",function(f)
        f:custom();player:SetAttribute("FactionId",1);f.char:SetAttribute("FactionId",2)
        assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
        local replacement=Instance.new("Model");replacement.Parent=workspace;f.other.Character=replacement
        local relation,reason=CharacterRegistry.GetRelationship(f.char)
        assert(relation=="Unknown" and reason=="stale_character_owner")
        replacement:Destroy()
    end)
    test("Explicit game adapters handle special rules and fail closed on errors",function(f)
        TeamService.SetAdapter(function(_,target,ours,char)
            assert(target==f.other and ours==f.ours and char==f.char);return "Ally","game_alliance"
        end)
        local relation,reason=CharacterRegistry.GetRelationship(f.char);assert(relation=="Ally" and reason=="game_alliance")
        TeamService.SetAdapter(function() error("adapter failed") end)
        relation,reason=CharacterRegistry.GetRelationship(f.char);assert(relation=="Unknown" and reason=="adapter_error")
        TeamService.SetAdapter(function() return false end);assert(CharacterRegistry.GetRelationship(f.char)=="Unknown")
        TeamService.SetAdapter(nil);assert(CharacterRegistry.GetRelationship(f.char)=="Enemy")
    end)

    local function selectionFixture(f,fn)
        local all,pos,screen,origin=CharacterRegistry.GetAll,GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin
        local oldRange=ConfigService.Get("LockRange")
        CharacterRegistry.GetAll=function() return {{char=f.char,name="Other",isNPC=false}} end
        GeometryService.GetTargetPos=function() return Vector3.new(10,0,-100) end
        GeometryService.WorldToScreen=function() return Vector2.new(100,100) end
        GeometryService.FOVOrigin=function() return Vector2.new(100,100) end
        ConfigService.Set("LockRange",0);ConfigService.Set("TeamCheck",true)
        local ok,err=pcall(fn)
        CharacterRegistry.GetAll,GeometryService.GetTargetPos,GeometryService.WorldToScreen,GeometryService.FOVOrigin=all,pos,screen,origin
        ConfigService.Set("TeamCheck",false);ConfigService.Set("LockRange",oldRange);LockController.SetActive(false)
        assert(ok,err)
    end
    test("Selection accepts confirmed enemies only when Team Check is on",function(f)
        selectionFixture(f,function()
            assert(TargetSelector.GetBestTarget().char==f.char)
            f.other.Team=f.a;assert(TargetSelector.GetBestTarget()==nil)
            f.other.Neutral=true;assert(TargetSelector.GetBestTarget()==nil)
            ConfigService.Set("TeamCheck",false);assert(TargetSelector.GetBestTarget().char==f.char)
        end)
    end)
    test("Unregistered unknown targets cannot bypass the team filter",function(f)
        selectionFixture(f,function()
            f.other.Character=nil
            Players.PlayerRemoving:Fire(f.other)
            assert(CharacterRegistry.GetData(f.char)==nil)
            assert(TargetSelector.GetBestTarget()==nil)
        end)
    end)
    test("Existing locks are dropped when a target becomes a teammate",function(f)
        selectionFixture(f,function()
            LockController.SetActive(true);assert(LockController.GetLockedTarget().char==f.char)
            f.other.Team=f.a;LockController.Update()
            assert(LockController.GetLockedTarget()==nil and LockController.GetDropReason()=="team_filtered")
        end)
    end)
    test("Aim update drops unknown targets between selection ticks",function(f)
        selectionFixture(f,function()
            LockController.SetActive(true);assert(LockController.GetLockedTarget())
            f.other.Neutral=true;AimController.Update()
            assert(not LockController.GetLockedTarget() and LockController.GetDropReason():find("team_unknown:",1,true))
        end)
    end)
    test("Final camera output rechecks teams and does not steer toward a new ally",function(f)
        selectionFixture(f,function()
            LockController.SetActive(true);AimController.SetTarget(Vector3.new(10,0,-100),f.char)
            local before=Camera.CFrame
            f.other.Team=f.a;bindings._SwaXCamAim(1/60)
            assert(Camera.CFrame==before and LockController.GetLockedTarget()==nil)
        end)
    end)
    test("Final mouse output also rejects targets that became unknown",function(f)
        selectionFixture(f,function()
            local mode=ConfigService.Get("AimMode");ConfigService.Set("AimMode","Mouse")
            LockController.SetActive(true);AimController.SetTarget(Vector3.new(10,0,-100),f.char)
            f.other.Neutral=true;bindings._SwaXCamAim(1/60)
            assert(LockController.GetLockedTarget()==nil)
            ConfigService.Set("AimMode",mode)
        end)
    end)
    test("NPCs with no team data are Unknown, while explicit faction IDs can resolve",function(f)
        f:custom()
        local npc=Instance.new("Model");npc.Parent=workspace
        assert(CharacterRegistry.GetRelationship(npc)=="Unknown")
        player:SetAttribute("FactionID",9);npc:SetAttribute("FactionID",9)
        assert(CharacterRegistry.GetRelationship(npc)=="Ally")
        npc:SetAttribute("FactionID",10);assert(CharacterRegistry.GetRelationship(npc)=="Enemy")
        npc:Destroy()
    end)
    test("Enabling Team Check immediately drops an unknown existing lock",function(f)
        selectionFixture(f,function()
            ConfigService.Set("TeamCheck",false);f.other.Neutral=true
            LockController.SetActive(true);assert(LockController.GetLockedTarget())
            ConfigService.Set("TeamCheck",true);assert(LockController.GetLockedTarget()==nil)
        end)
    end)
end

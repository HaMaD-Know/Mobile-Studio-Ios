// Generated from the Android PlaceFactory: template script sources, verbatim.
enum TemplateScripts {
    static let swordScript = """
    -- Click (tap) to swing; hitting someone on the other team (or anyone, with no teams) does damage.
    local tool = script.Parent
    local handle = tool:WaitForChild("Handle")
    local swinging = false
    tool.Activated:Connect(function()
        if swinging then return end
        swinging = true
        task.wait(0.4)
        swinging = false
    end)
    handle.Touched:Connect(function(hit)
        if not swinging then return end
        local humanoid = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
        local owner = game.Players:GetPlayerFromCharacter(tool.Parent)
        local victim = game.Players:GetPlayerFromCharacter(hit.Parent)
        if humanoid and owner and victim ~= owner and (not victim or victim.Team ~= owner.Team or owner.Neutral) then
            humanoid:TakeDamage(25)
        end
    end)
    """
    static let leaderboard = """
    -- Kills and Deaths on the leaderboard.
    game.Players.PlayerAdded:Connect(function(player)
        local stats = Instance.new("Folder")
        stats.Name = "leaderstats"
        local kills = Instance.new("IntValue"); kills.Name = "Kills"; kills.Parent = stats
        local deaths = Instance.new("IntValue"); deaths.Name = "Deaths"; deaths.Parent = stats
        stats.Parent = player
        player.CharacterAdded:Connect(function(character)
            character:WaitForChild("Humanoid").Died:Connect(function()
                deaths.Value = deaths.Value + 1
            end)
        end)
    end)
    """
    static let move = """
    -- Moves the platform back and forth forever.
    local TweenService = game:GetService("TweenService")
    local part = script.Parent
    local startCF = part.CFrame
    local info = TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    TweenService:Create(part, info, { CFrame = startCF + Vector3.new(0, 0, 24) }):Play()
    """
    static let spin = """
    -- Spins the bar around its center.
    local RunService = game:GetService("RunService")
    local bar = script.Parent
    local center = bar.CFrame
    local angle = 0
    RunService.Heartbeat:Connect(function(dt)
        angle = angle + dt * 2
        bar.CFrame = center * CFrame.Angles(0, angle, 0)
    end)
    """
    static let win = """
    -- Tells the player they won (once per life).
    local finish = script.Parent
    local won = {}
    finish.Touched:Connect(function(hit)
        local player = game.Players:GetPlayerFromCharacter(hit.Parent)
        if player and not won[player] then
            won[player] = true
            print(player.Name .. " finished the obby!")
            local gui = Instance.new("ScreenGui")
            gui.Name = "WinGui"
            local label = Instance.new("TextLabel")
            label.Size = UDim2.new(1, 0, 0, 60)
            label.Position = UDim2.new(0, 0, 0.2, 0)
            label.BackgroundTransparency = 1
            label.Text = "You beat the obby!"
            label.TextScaled = true
            label.TextColor3 = Color3.fromRGB(255, 255, 255)
            label.TextStrokeTransparency = 0
            label.Font = Enum.Font.FredokaOne
            label.Parent = gui
            gui.Parent = player.PlayerGui
            task.delay(4, function() gui:Destroy() end)
        end
    end)
    """
    static let obbyScript = """
    -- Checkpoints: touching CheckpointN makes it your respawn point and sets your Stage.
    -- Kill parts: anything with a "KillPart" value inside resets your character.
    local Players = game:GetService("Players")
    local course = workspace:WaitForChild("Obby")

    Players.PlayerAdded:Connect(function(player)
        local stats = Instance.new("Folder")
        stats.Name = "leaderstats"
        local stage = Instance.new("IntValue")
        stage.Name = "Stage"
        stage.Value = 0
        stage.Parent = stats
        stats.Parent = player
    end)

    for _, part in ipairs(course:GetDescendants()) do
        if part:IsA("SpawnLocation") and part.Name:match("^Checkpoint") then
            local number = tonumber(part.Name:match("%d+")) or 0
            part.Touched:Connect(function(hit)
                local player = Players:GetPlayerFromCharacter(hit.Parent)
                if player and player:FindFirstChild("leaderstats") then
                    local stage = player.leaderstats.Stage
                    if number > stage.Value then
                        stage.Value = number
                        player.RespawnLocation = part
                    end
                end
            end)
        elseif part:IsA("BasePart") and part:FindFirstChild("KillPart") then
            part.Touched:Connect(function(hit)
                local humanoid = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid.Health = 0 end
            end)
        end
    end
    """
}

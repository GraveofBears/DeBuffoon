--------------------------------------------------------------------------------
-- DeBuffoon - Lightweight target debuff overlay
-- Shows a marker texture per tracked entry whenever its debuff is found on
-- your target. Each entry is an independent (debuff -> attach) pair, so the
-- SAME debuff can be tracked multiple times and overlay multiple spell
-- buttons. Icons can also float anywhere on screen.
-- Slash command: /mx   ( /mx debug for diagnostics )
--------------------------------------------------------------------------------

local ADDON_NAME = "Debuffoon"
local SCAN_INTERVAL = 0.2          -- OnUpdate throttle (seconds)
local DEFAULT_SIZE = 48

-- Runtime tables
local icons = {}                   -- [entryId] = iconFrame
local anchorButtons = {}           -- [entryId] = action button frame (or nil)
local listRows = {}                -- recycled rows for the config list

--------------------------------------------------------------------------------
-- Icon style choices
-- All textures below ship with the 2.5.x client. Raid markers share one
-- texture sheet and are cut out with texcoords.
--------------------------------------------------------------------------------
local RAID_ICONS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

local ICON_CHOICES = {
    { key = "xloot",    label = "Red X (loot pass)",  tex = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" },
    { key = "notready", label = "Red Cross (ready check)", tex = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
    { key = "ready",    label = "Green Check",        tex = "Interface\\RaidFrame\\ReadyCheck-Ready" },
    { key = "waiting",  label = "Hourglass",          tex = "Interface\\RaidFrame\\ReadyCheck-Waiting" },
    { key = "skull",    label = "Skull",              tex = RAID_ICONS, coords = { 0.75, 1.00, 0.25, 0.50 } },
    { key = "cross",    label = "Cross (red)",        tex = RAID_ICONS, coords = { 0.50, 0.75, 0.25, 0.50 } },
    { key = "circle",   label = "Circle (orange)",    tex = RAID_ICONS, coords = { 0.25, 0.50, 0.00, 0.25 } },
    { key = "diamond",  label = "Diamond (purple)",   tex = RAID_ICONS, coords = { 0.50, 0.75, 0.00, 0.25 } },
    { key = "triangle", label = "Triangle (green)",   tex = RAID_ICONS, coords = { 0.75, 1.00, 0.00, 0.25 } },
    { key = "moon",     label = "Moon (white)",       tex = RAID_ICONS, coords = { 0.00, 0.25, 0.25, 0.50 } },
    { key = "square",   label = "Square (blue)",      tex = RAID_ICONS, coords = { 0.25, 0.50, 0.25, 0.50 } },
    { key = "star",     label = "Star (yellow)",      tex = RAID_ICONS, coords = { 0.00, 0.25, 0.00, 0.25 } },
    { key = "alert",    label = "Exclamation (!)",    tex = "Interface\\GossipFrame\\AvailableQuestIcon" },
}

local ICON_INDEX = {}              -- [key] = position in ICON_CHOICES
for i, choice in ipairs(ICON_CHOICES) do
    ICON_INDEX[choice.key] = i
end

local function GetIconChoice(entry)
    return ICON_CHOICES[ICON_INDEX[entry and entry.icon or nil] or 1]
end

-- Apply a choice's texture + texcoords to any texture region
local function ApplyChoiceToTexture(texture, choice)
    texture:SetTexture(choice.tex)
    if choice.coords then
        texture:SetTexCoord(choice.coords[1], choice.coords[2],
                            choice.coords[3], choice.coords[4])
    else
        texture:SetTexCoord(0, 1, 0, 1)
    end
end

--------------------------------------------------------------------------------
-- SavedVariables / defaults / migration
--------------------------------------------------------------------------------
-- New format:
--   DeBuffoonDB.entries[id] = { name = "Faerie Fire",   -- debuff to look for
--                           icon = "skull",          -- ICON_CHOICES key
--                           attach = "Mangle",       -- spell button ("" = float)
--                           point="CENTER", x=0, y=0, scale=1 }
-- The numeric id is unique per entry, so the same debuff name can exist on
-- any number of entries, each attached to a different spell.
local function InitDB()
    DeBuffoonDB = DeBuffoonDB or {}
    if DeBuffoonDB.locked == nil then DeBuffoonDB.locked = true end
    DeBuffoonDB.entries = DeBuffoonDB.entries or {}
    DeBuffoonDB.nextId = DeBuffoonDB.nextId or 1

    -- Migrate the old name-keyed format (DeBuffoonDB.spells) in place
    if DeBuffoonDB.spells then
        for _, old in pairs(DeBuffoonDB.spells) do
            local id = DeBuffoonDB.nextId
            DeBuffoonDB.nextId = id + 1
            DeBuffoonDB.entries[id] = {
                name   = old.name or "?",
                icon   = old.icon or "xloot",
                attach = old.attach or "",
                point  = old.point or "CENTER",
                x      = old.x or 0,
                y      = old.y or 0,
                scale  = old.scale or 1,
            }
        end
        DeBuffoonDB.spells = nil
        print("|cff00ff00DeBuffoon:|r Settings migrated to the new multi-attach format.")
    end
end

--------------------------------------------------------------------------------
-- Action bar scanning (for "attach to spell icon")
--------------------------------------------------------------------------------
-- Blizzard bars + common bar addons (missing globals are skipped harmlessly)
local BAR_BUTTONS = {
    { prefix = "ActionButton",              count = 12  }, -- Blizzard main bar
    { prefix = "MultiBarBottomLeftButton",  count = 12  },
    { prefix = "MultiBarBottomRightButton", count = 12  },
    { prefix = "MultiBarRightButton",       count = 12  },
    { prefix = "MultiBarLeftButton",        count = 12  },
    { prefix = "BT4Button",                 count = 120 }, -- Bartender4
    { prefix = "DominosActionButton",       count = 120 }, -- Dominos extra bars
    { prefix = "ElvUI_Bar1Button",          count = 12  }, -- ElvUI bars 1-6
    { prefix = "ElvUI_Bar2Button",          count = 12  },
    { prefix = "ElvUI_Bar3Button",          count = 12  },
    { prefix = "ElvUI_Bar4Button",          count = 12  },
    { prefix = "ElvUI_Bar5Button",          count = 12  },
    { prefix = "ElvUI_Bar6Button",          count = 12  },
}

-- Best-effort action slot for a button (handles paging + LibActionButton bars)
local function GetButtonActionSlot(button)
    local slot
    if button.GetAttribute then
        slot = button:GetAttribute("action")
    end
    if not slot or slot == 0 then
        slot = button.action
    end
    if not slot or slot == 0 then return nil end
    return slot
end

-- Resolve the spell name sitting on an action button, if any
local function GetButtonSpellName(button)
    local slot = GetButtonActionSlot(button)
    if not slot or not HasAction(slot) then return nil end

    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" and id and id ~= 0 then
        return GetSpellInfo(id)
    elseif actionType == "macro" and id then
        local spell = GetMacroSpell(id)
        if type(spell) == "number" then
            return GetSpellInfo(spell)
        end
        return spell -- some clients return the name directly
    end
    return nil
end

-- Find the action button whose action matches spellName.
-- Prefers a VISIBLE button (important when bar addons hide Blizzard's bars).
local function FindActionButtonForSpell(spellName)
    local wanted = string.lower(spellName)
    local hiddenMatch
    for _, bar in ipairs(BAR_BUTTONS) do
        for i = 1, bar.count do
            local button = _G[bar.prefix .. i]
            if button then
                local name = GetButtonSpellName(button)
                if name and string.lower(name) == wanted then
                    if button:IsVisible() then
                        return button
                    elseif not hiddenMatch then
                        hiddenMatch = button
                    end
                end
            end
        end
    end
    return hiddenMatch
end

--------------------------------------------------------------------------------
-- Icon frames (one marker per tracked entry)
--------------------------------------------------------------------------------
local function SaveIconPosition(icon)
    if icon.anchored then return end   -- anchored icons have no free position
    local entry = DeBuffoonDB.entries[icon.entryId]
    if not entry then return end
    local point, _, _, x, y = icon:GetPoint(1)
    entry.point = point or "CENTER"
    entry.x = x or 0
    entry.y = y or 0
    entry.scale = icon:GetScale()
end

-- Re-apply the chosen marker texture to a live icon
local function ApplyIconStyle(id)
    local icon = icons[id]
    local entry = DeBuffoonDB.entries[id]
    if not icon or not entry then return end
    ApplyChoiceToTexture(icon.tex, GetIconChoice(entry))
    icon.label:SetText(entry.name or "?")
end

local function ApplyLockState(icon)
    local locked = DeBuffoonDB.locked
    if locked or icon.anchored then
        -- Anchored icons are ALWAYS click-through so the spell stays clickable
        icon:EnableMouse(false)
        icon:EnableMouseWheel(false)
        icon:SetMovable(false)
    else
        icon:EnableMouse(true)
        icon:EnableMouseWheel(true)
        icon:SetMovable(true)
    end

    if locked then
        icon.bg:Hide()
        icon.label:Hide()
    else
        icon.bg:Show()
        icon.label:Show()
        icon:Show()                        -- always visible while arranging
    end
end

-- Place an icon either over its action button anchor or at its saved position.
-- NOTE: we anchor by POINTS only and stay parented to UIParent. Re-parenting
-- to the button would make the marker invisible whenever that button is hidden
-- (e.g. bar addons hide the stock Blizzard buttons).
local function UpdateAnchor(id)
    local icon = icons[id]
    local entry = DeBuffoonDB.entries[id]
    if not icon or not entry then return end

    local button
    if entry.attach and entry.attach ~= "" then
        button = FindActionButtonForSpell(entry.attach)
    end
    anchorButtons[id] = button

    icon:ClearAllPoints()

    if button then
        -- Button found: Position the icon as an overlay
        icon.anchored = true
        icon:SetScale(1)
        icon:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
        icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -4)
        -- We do NOT call Show() here; let ScanTarget handle visibility
    else
        -- Button NOT found: Hide it and unset anchored status
        icon.anchored = false
        icon:Hide() 
    end
    
    ApplyLockState(icon)
end

local function RefreshAllAnchors()
    for id in pairs(icons) do
        UpdateAnchor(id)
    end
end

-- Bars update their own state on these events too; wait a moment so
-- button.action / attributes are current before we re-resolve anchors.
local function QueueAnchorRefresh()
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, RefreshAllAnchors)
    else
        RefreshAllAnchors()
    end
end

local function CreateIcon(id)
    local entry = DeBuffoonDB.entries[id]
    if not entry then return end

    local icon = CreateFrame("Frame", "DeBuffoonIcon" .. id, UIParent)
    icon.entryId = id
    icon:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
    icon:SetFrameStrata("HIGH")            -- above action bars (MEDIUM)

    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints(icon)
    ApplyChoiceToTexture(icon.tex, GetIconChoice(entry))

    -- Faint backdrop + label shown only while unlocked, so icons are findable
    icon.bg = icon:CreateTexture(nil, "BACKGROUND")
    icon.bg:SetAllPoints(icon)
    icon.bg:SetColorTexture(0, 1, 0, 0.25)
    icon.bg:Hide()

    icon.label = icon:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    icon.label:SetPoint("BOTTOM", icon, "TOP", 0, 2)
    icon.label:SetText(entry.name or "?")
    icon.label:Hide()

    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnDragStart", function(self)
        if not DeBuffoonDB.locked and not self.anchored then self:StartMoving() end
    end)
    icon:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveIconPosition(self)
    end)
    -- Mouse wheel resizes (persists as scale) while unlocked and floating
    icon:SetScript("OnMouseWheel", function(self, delta)
        if self.anchored then return end
        local s = self:GetScale() + (delta * 0.1)
        if s < 0.3 then s = 0.3 elseif s > 3 then s = 3 end
        self:SetScale(s)
        SaveIconPosition(self)
    end)

    icon:Hide()
    icons[id] = icon
    UpdateAnchor(id)
    return icon
end

local function RemoveIcon(id)
    local icon = icons[id]
    if icon then
        icon:Hide()
        icon:ClearAllPoints()
        icon:SetScript("OnDragStart", nil)
        icon:SetScript("OnDragStop", nil)
        icon:SetScript("OnMouseWheel", nil)
        icons[id] = nil
        anchorButtons[id] = nil
    end
end

local function BuildAllIcons()
    for id in pairs(DeBuffoonDB.entries) do
        if not icons[id] then CreateIcon(id) end
    end
end

local function SetLocked(locked)
    DeBuffoonDB.locked = locked
    for _, icon in pairs(icons) do
        ApplyLockState(icon)
        if locked then icon:Hide() end -- scanner re-shows active ones
    end
end

--------------------------------------------------------------------------------
-- Debuff scanning (throttled OnUpdate, manual 1-40 UnitDebuff iteration)
--------------------------------------------------------------------------------
local scanner = CreateFrame("Frame")
local elapsedSince = 0
local activeNames = {}             -- [lowercase debuff name] = true

-- Does the tracked name match anything currently on the target?
-- Exact match, OR variant match: tracking "faerie fire" also matches
-- "faerie fire (feral)" so spell variants light up too.
local function IsTrackedActive(lname)
    if activeNames[lname] then return true end
    local variant = lname .. " ("
    for name in pairs(activeNames) do
        if string.sub(name, 1, #variant) == variant then
            return true
        end
    end
    return false
end

local function ScanTarget()
    if not DeBuffoonDB then return end
    wipe(activeNames)

    if UnitExists("target") then
        for i = 1, 40 do
            local name = UnitDebuff("target", i)
            if not name then break end
            activeNames[string.lower(name)] = true
        end
    end

    local unlocked = not DeBuffoonDB.locked
    for id, icon in pairs(icons) do
        local entry = DeBuffoonDB.entries[id]
        
        -- NEW LOGIC:
        -- 1. If unlocked, show for positioning.
        -- 2. If locked, show ONLY if debuff is active AND (it's floating OR button is found)
        if unlocked then
            icon:Show()
        elseif entry and IsTrackedActive(string.lower(entry.name or "")) then
            -- If it requires a button, check if that button exists
            if entry.attach and entry.attach ~= "" and not anchorButtons[id] then
                icon:Hide()
            else
                icon:Show()
            end
        else
            icon:Hide()
        end
    end
end

scanner:SetScript("OnUpdate", function(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < SCAN_INTERVAL then return end
    elapsedSince = 0
    ScanTarget()
end)

--------------------------------------------------------------------------------
-- Diagnostics: /dbf debug
--------------------------------------------------------------------------------
local function PrintDebug()
    print("|cff00ff00DeBuffoon debug|r ----------------------------")
    if UnitExists("target") then
        print("Target: " .. (UnitName("target") or "?") .. " | debuffs found:")
        local found = 0
        for i = 1, 40 do
            local name = UnitDebuff("target", i)
            if not name then break end
            found = found + 1
            print("  " .. i .. ". " .. name)
        end
        if found == 0 then print("  (none)") end
    else
        print("Target: none")
    end
    print("Tracked entries:")
    local any = false
    for id, entry in pairs(DeBuffoonDB.entries) do
        any = true
        local icon = icons[id]
        local btn = anchorButtons[id]
        local parts = "  #" .. id .. " '" .. (entry.name or "?") .. "' [" ..
                      GetIconChoice(entry).label .. "]"
        if entry.attach and entry.attach ~= "" then
            if btn then
                parts = parts .. " -> " .. (btn:GetName() or "unnamed button")
                    .. (btn:IsVisible() and " (visible)" or " (HIDDEN button!)")
            else
                parts = parts .. " -> attach '" .. entry.attach .. "' NOT FOUND on bars"
            end
        else
            parts = parts .. " (floating)"
        end
        parts = parts .. " | active=" ..
            tostring(IsTrackedActive(string.lower(entry.name or "")))
            .. " shown=" .. tostring(icon and icon:IsShown() or false)
        print(parts)
    end
    if not any then print("  (none)") end
    print("Locked: " .. tostring(DeBuffoonDB.locked))
end

--------------------------------------------------------------------------------
-- Configuration window (/dbf)
--------------------------------------------------------------------------------
local config

local function RefreshSpellList()
    if not config then return end

    for _, row in ipairs(listRows) do row:Hide() end

    -- Sort by debuff name, then id, for a stable list
    local ids = {}
    for id in pairs(DeBuffoonDB.entries) do table.insert(ids, id) end
    table.sort(ids, function(a, b)
        local na = string.lower(DeBuffoonDB.entries[a].name or "")
        local nb = string.lower(DeBuffoonDB.entries[b].name or "")
        if na ~= nb then return na < nb end
        return a < b
    end)

    local rowHeight = 26
    for i, id in ipairs(ids) do
        local row = listRows[i]
        if not row then
            row = CreateFrame("Frame", nil, config.listChild)
            row:SetHeight(rowHeight)
            row:SetPoint("LEFT", config.listChild, "LEFT", 0, 0)
            row:SetPoint("RIGHT", config.listChild, "RIGHT", 0, 0)

            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetWidth(100)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)

            -- Icon style picker: shows the current marker.
            -- Left-click = next style, right-click = previous style.
            row.iconBtn = CreateFrame("Button", nil, row)
            row.iconBtn:SetSize(22, 22)
            row.iconBtn:SetPoint("LEFT", row.text, "RIGHT", 6, 0)
            row.iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row.iconBtn.tex = row.iconBtn:CreateTexture(nil, "ARTWORK")
            row.iconBtn.tex:SetAllPoints(row.iconBtn)
            row.iconBtn:SetHighlightTexture(
                "Interface\\Buttons\\ButtonHilight-Square", "ADD")

            row.attach = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.attach:SetSize(120, 20)
            row.attach:SetPoint("LEFT", row.iconBtn, "RIGHT", 12, 0)
            row.attach:SetAutoFocus(false)
            row.attach:SetMaxLetters(60)

            -- Duplicate this entry (same debuff, blank attach) for another button
            row.dup = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.dup:SetSize(24, 20)
            row.dup:SetPoint("LEFT", row.attach, "RIGHT", 6, 0)
            row.dup:SetText("+")

            row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.remove:SetSize(60, 20)
            row.remove:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.remove:SetText("Remove")

            listRows[i] = row
        end
        row:SetPoint("TOPLEFT", config.listChild, "TOPLEFT", 0, -((i - 1) * rowHeight))

        local entry = DeBuffoonDB.entries[id]
        row.text:SetText(entry.name or "?")
        row.attach:SetText(entry.attach or "")
        ApplyChoiceToTexture(row.iconBtn.tex, GetIconChoice(entry))

        -- Icon picker behavior --------------------------------------------------
        row.iconBtn:SetScript("OnClick", function(self, mouseButton)
            local e = DeBuffoonDB.entries[id]
            if not e then return end
            local idx = ICON_INDEX[e.icon] or 1
            local step = (mouseButton == "RightButton") and -1 or 1
            idx = idx + step
            if idx > #ICON_CHOICES then idx = 1 end
            if idx < 1 then idx = #ICON_CHOICES end
            e.icon = ICON_CHOICES[idx].key
            ApplyChoiceToTexture(self.tex, ICON_CHOICES[idx])
            ApplyIconStyle(id)
            -- Refresh tooltip text if the cursor is still on the button
            if GameTooltip:IsOwned(self) then
                GameTooltip:SetText("Marker: " .. ICON_CHOICES[idx].label)
                GameTooltip:AddLine("Left-click: next  |  Right-click: previous",
                                    0.8, 0.8, 0.8)
                GameTooltip:Show()
            end
        end)
        row.iconBtn:SetScript("OnEnter", function(self)
            local e = DeBuffoonDB.entries[id]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Marker: " .. GetIconChoice(e).label)
            GameTooltip:AddLine("Left-click: next  |  Right-click: previous",
                                0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        row.iconBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Save the "attach to" spell on Enter or focus loss ---------------------
        local function CommitAttach(box)
            local e = DeBuffoonDB.entries[id]
            if not e then return end
            local value = strtrim(box:GetText() or "")
            if (e.attach or "") == value then return end
            e.attach = value
            UpdateAnchor(id)
            if value ~= "" then
                local btn = anchorButtons[id]
                if btn then
                    print("|cff00ff00DeBuffoon:|r '" .. (e.name or "?") ..
                          "' attached to your '" .. value .. "' button (" ..
                          (btn:GetName() or "?") .. ").")
                else
                    print("|cff00ff00DeBuffoon:|r Couldn't find '" .. value ..
                          "' on your bars. Icon stays floating until it appears.")
                end
            end
        end
        row.attach:SetScript("OnEnterPressed", function(self)
            CommitAttach(self)
            self:ClearFocus()
        end)
        row.attach:SetScript("OnEditFocusLost", CommitAttach)
        row.attach:SetScript("OnEscapePressed", function(self)
            self:SetText(DeBuffoonDB.entries[id] and DeBuffoonDB.entries[id].attach or "")
            self:ClearFocus()
        end)

        -- Duplicate: new entry for the same debuff, ready for another attach ----
        row.dup:SetScript("OnClick", function()
            local e = DeBuffoonDB.entries[id]
            if not e then return end
            local newId = DeBuffoonDB.nextId
            DeBuffoonDB.nextId = newId + 1
            DeBuffoonDB.entries[newId] = {
                name = e.name, icon = e.icon, attach = "",
                point = "CENTER", x = 0, y = 0, scale = 1,
            }
            CreateIcon(newId)
            RefreshSpellList()
            print("|cff00ff00DeBuffoon:|r Added another '" .. (e.name or "?") ..
                  "' entry. Set its 'Attach to' spell or position it while unlocked.")
        end)
        row.dup:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Add another marker for this same debuff")
            GameTooltip:Show()
        end)
        row.dup:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.remove:SetScript("OnClick", function()
            DeBuffoonDB.entries[id] = nil
            RemoveIcon(id)
            RefreshSpellList()
        end)
        row:Show()
    end

    config.listChild:SetHeight(math.max(#ids * rowHeight, 1))
end

local function AddSpell(rawName)
    local name = strtrim(rawName or "")
    if name == "" then return end
    local id = DeBuffoonDB.nextId
    DeBuffoonDB.nextId = id + 1
    DeBuffoonDB.entries[id] = { name = name, icon = "xloot", attach = "",
                            point = "CENTER", x = 0, y = 0, scale = 1 }
    CreateIcon(id)
    RefreshSpellList()
    print("|cff00ff00DeBuffoon:|r Now tracking '" .. name ..
          "'. Unlock to position its marker, or set an 'Attach to' spell.")
end

local function UpdateLockButton()
    if not config then return end
    config.lockBtn:SetText(DeBuffoonDB.locked and "Unlock Icons" or "Lock Icons")
end

local function CreateConfig()
    config = CreateFrame("Frame", "DeBuffoonConfigFrame", UIParent,
                         "BasicFrameTemplateWithInset")
    config:SetSize(460, 380)
    config:SetPoint("CENTER")
    config:SetMovable(true)
    config:EnableMouse(true)
    config:RegisterForDrag("LeftButton")
    config:SetScript("OnDragStart", config.StartMoving)
    config:SetScript("OnDragStop", config.StopMovingOrSizing)
    config:SetFrameStrata("DIALOG")
    config:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "DeBuffoonConfigFrame")   -- close on Escape

    config.title = config:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    config.title:SetPoint("TOP", config.TitleBg, "TOP", 0, -5)
    config.title:SetText("DeBuffoon - Debuff Tracker")

    -- Input row -------------------------------------------------------------
    local inputLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    inputLabel:SetPoint("TOPLEFT", config, "TOPLEFT", 14, -34)
    inputLabel:SetText("Debuff name to track:")

    local editBox = CreateFrame("EditBox", nil, config, "InputBoxTemplate")
    editBox:SetSize(250, 22)
    editBox:SetPoint("TOPLEFT", inputLabel, "BOTTOMLEFT", 4, -6)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(60)

    local addBtn = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    addBtn:SetSize(70, 22)
    addBtn:SetPoint("LEFT", editBox, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    local function SubmitEdit()
        AddSpell(editBox:GetText())
        editBox:SetText("")
        editBox:ClearFocus()
    end
    addBtn:SetScript("OnClick", SubmitEdit)
    editBox:SetScript("OnEnterPressed", SubmitEdit)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Lock/Unlock -------------------------------------------------------------
    config.lockBtn = CreateFrame("Button", nil, config, "UIPanelButtonTemplate")
    config.lockBtn:SetSize(120, 24)
    config.lockBtn:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", -4, -10)
    config.lockBtn:SetScript("OnClick", function()
        SetLocked(not DeBuffoonDB.locked)
        UpdateLockButton()
        if DeBuffoonDB.locked then
            print("|cff00ff00DeBuffoon:|r Icons locked (click-through).")
        else
            print("|cff00ff00DeBuffoon:|r Icons unlocked. Drag to move, mouse wheel to resize.")
        end
    end)

    local hint = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", config.lockBtn, "RIGHT", 8, 0)
    hint:SetText("Drag = move, wheel = scale (floating icons)")

    -- Tracked list -------------------------------------------------------------
    local listLabel = config:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", config.lockBtn, "BOTTOMLEFT", 0, -12)
    listLabel:SetText("Tracked debuffs (same debuff can have multiple entries):")

    local colDebuff = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    colDebuff:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 4, -6)
    colDebuff:SetText("Debuff")

    local colIcon = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    colIcon:SetPoint("LEFT", colDebuff, "LEFT", 106, 0)
    colIcon:SetText("Icon")

    local colAttach = config:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    colAttach:SetPoint("LEFT", colDebuff, "LEFT", 146, 0)
    colAttach:SetText("Attach to spell   |   + = extra entry")

    local scroll = CreateFrame("ScrollFrame", "DeBuffoonConfigScroll", config,
                               "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", colDebuff, "BOTTOMLEFT", -4, -4)
    scroll:SetPoint("BOTTOMRIGHT", config, "BOTTOMRIGHT", -30, 12)

    config.listChild = CreateFrame("Frame", nil, scroll)
    config.listChild:SetWidth(scroll:GetWidth() or 400)
    config.listChild:SetHeight(1)
    scroll:SetScrollChild(config.listChild)
    scroll:SetScript("OnSizeChanged", function(self, w)
        config.listChild:SetWidth(w)
    end)

    config:Hide()
end

local function ToggleConfig()
    if not DeBuffoonDB then return end -- Added safety
    if not config then CreateConfig() end
    if config:IsShown() then
        config:Hide()
    else
        UpdateLockButton()
        RefreshSpellList()
        config:Show()
    end
end

--------------------------------------------------------------------------------
-- Slash command + load / action-bar event handling
--------------------------------------------------------------------------------
SLASH_DeBuffoon1 = "/dbf"
SlashCmdList["DeBuffoon"] = function(msg)
    -- GUARD: Ensure DB is loaded before processing commands
    if not DeBuffoonDB then
        print("|cffff0000DeBuffoon:|r Still loading... please wait a moment.")
        return
    end

    msg = strtrim(string.lower(msg or ""))
    if msg == "lock" then
        SetLocked(true)
        UpdateLockButton()
        print("|cff00ff00DeBuffoon:|r Icons locked.")
    elseif msg == "unlock" then
        SetLocked(false)
        UpdateLockButton()
        print("|cff00ff00DeBuffoon:|r Icons unlocked.")
    elseif msg == "debug" then
        PrintDebug()
    else
        ToggleConfig()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
loader:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
loader:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildAllIcons()
        print("|cff00ff00DeBuffoon|r loaded. Type |cffffff00/dbf|r to configure.")
    elseif event == "PLAYER_ENTERING_WORLD"
        or event == "ACTIONBAR_SLOT_CHANGED"
        or event == "ACTIONBAR_PAGE_CHANGED"
        or event == "UPDATE_BONUS_ACTIONBAR" then
        -- Bars changed: re-resolve anchors AFTER the bars finish updating
        QueueAnchorRefresh()
    elseif event == "PLAYER_LOGOUT" then
        for _, icon in pairs(icons) do
            SaveIconPosition(icon)
        end
    end
end)
-- Best Value: highlights the quest reward that sells for the most at a vendor,
-- both when turning in the quest and in the quest log.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local marks = {}                         -- button -> mark-frame
local pending = { reward = false, log = false } -- waiting for item data from the server
local announced = false                  -- already printed to chat for this turn-in
local rewardChoices = {}                 -- choice index -> { link, count, price } for the turn-in window

local db                                 -- BestValueDB, set on ADDON_LOADED
local defaults = {
	showCoin = true,
	showValue = true,
	announce = true,
	autoSell = true,
	autoSellDefault = false,
	lootMode = "off", -- dungeon/raid loot: "off", "ask" or "auto"
	lootPoor = true,
	lootCommon = true,
	lootUncommon = true,
	lootRare = true,  -- rare and epic
}

local function Opt(key)
	if db then return db[key] end
	return defaults[key]
end

-- Settings widgets register a refresh function here.
local refreshers = {}
local function RefreshOptions()
	if not db then return end
	for _, fn in ipairs(refreshers) do fn() end
end

local function CoinString(copper)
	if GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	return string.format("%dg %ds %dc", copper / 10000, (copper / 100) % 100, copper % 100)
end

-- Data sources: the turn-in window and the quest log use different APIs.
local sources = {
	reward = {
		num = function()
			return GetNumQuestChoices and GetNumQuestChoices() or 0
		end,
		link = function(i)
			return GetQuestItemLink("choice", i)
		end,
		count = function(i)
			local _, _, count = GetQuestItemInfo("choice", i)
			return count
		end,
	},
	log = {
		num = function()
			if not GetNumQuestLogChoices then return 0 end
			local questID = C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
			return GetNumQuestLogChoices(questID, true) or 0
		end,
		link = function(i)
			return GetQuestLogItemLink("choice", i)
		end,
		count = function(i)
			local _, _, count = GetQuestLogChoiceInfo(i)
			return count
		end,
	},
}

-- Find the button for choice reward number i (different clients name them differently).
local function FindInRewardFrame(rf, i)
	if rf and rf.RewardButtons and rf:IsVisible() then
		for _, b in ipairs(rf.RewardButtons) do
			if b.type == "choice" and b:GetID() == i and b:IsShown() then
				return b
			end
		end
	end
end

local function Visible(b)
	if b and b:IsVisible() then return b end
end

local function GetChoiceButton(ctx, i)
	if ctx == "reward" then
		return FindInRewardFrame(QuestInfoRewardsFrame, i)
			or Visible(_G["QuestInfoRewardsFrameQuestInfoItem" .. i])
			or Visible(_G["QuestRewardItem" .. i])
	end
	return FindInRewardFrame(QuestInfoRewardsFrame, i)
		or FindInRewardFrame(MapQuestInfoRewardsFrame, i)
		or Visible(_G["QuestLogItem" .. i])
end

local function GetMark(b)
	if marks[b] then return marks[b] end

	local m = CreateFrame("Frame", nil, b)
	m:SetAllPoints(b)
	m:SetFrameLevel(b:GetFrameLevel() + 5)

	local icon = b.Icon or (b:GetName() and _G[b:GetName() .. "IconTexture"]) or b

	-- Gold coin in the icon's corner
	m.coin = m:CreateTexture(nil, "OVERLAY", nil, 7)
	m.coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
	m.coin:SetSize(16, 16)
	m.coin:SetPoint("TOPLEFT", icon, "TOPLEFT", -6, 6)

	-- Sell value for each choice
	m.value = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	m.value:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 2)

	marks[b] = m
	return m
end

local function HideAll(ctx)
	for _, m in pairs(marks) do
		if not ctx or m.ctx == ctx then
			m:Hide()
		end
	end
end

local function Update(ctx)
	local src = sources[ctx]
	HideAll(ctx)
	pending[ctx] = false

	local n = src.num()
	if ctx == "reward" then
		wipe(rewardChoices)
		for i = 1, n do
			local link = src.link(i)
			rewardChoices[i] = link and {
				link = link,
				count = math.max(src.count(i) or 1, 1),
				price = select(11, GetItemInfo(link)),
			}
		end
	end
	if n < 2 then return end

	local values, best = {}, 0
	for i = 1, n do
		local link = src.link(i)
		local price = link and select(11, GetItemInfo(link))
		if price == nil then
			pending[ctx] = true -- item not cached yet, we'll retry
		else
			local v = price * math.max(src.count(i) or 1, 1)
			values[i] = v
			if v > best then best = v end
		end
	end

	for i = 1, n do
		local b = GetChoiceButton(ctx, i)
		if b then
			local m = GetMark(b)
			m.ctx = ctx
			local v = values[i]
			if v == nil then
				m.value:SetText("...")
			elseif v == 0 then
				m.value:SetText("|cff808080Not sellable|r")
			else
				m.value:SetText(CoinString(v))
			end
			m.value:SetShown(Opt("showValue"))
			local isBest = Opt("showCoin") and not pending[ctx] and best > 0 and v == best
			m.coin:SetShown(isBest)
			m:Show()
		end
	end

	if ctx == "reward" and Opt("announce") and not pending.reward and best > 0 and not announced then
		announced = true
		for i = 1, n do
			if values[i] == best then
				print("|cffffd100Best Value:|r " .. (src.link(i) or "?") .. " - " .. CoinString(best))
			end
		end
	end
end

local function RewardPanelShown()
	return QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown()
end

-- Update the log one frame later so Blizzard's UI has had time to position the buttons.
local logQueued = false
local function QueueLogUpdate()
	if logQueued then return end
	logQueued = true
	C_Timer.After(0, function()
		logQueued = false
		Update("log")
	end)
end

-- Auto-sell: a checkbox on the turn-in window queues the chosen reward,
-- which is then sold the next time a merchant window opens.

local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local sellCheck
local function CreateSellCheckbox()
	if sellCheck or not QuestFrameRewardPanel then return end
	-- Sit right below the rewards, inside the scrolling quest text, so it scrolls with them.
	local rf = QuestInfoRewardsFrame
	if rf then
		sellCheck = CreateFrame("CheckButton", nil, rf, "UICheckButtonTemplate")
		sellCheck:SetPoint("TOPLEFT", rf, "BOTTOMLEFT", -4, -2)
	else
		sellCheck = CreateFrame("CheckButton", nil, QuestFrameRewardPanel, "UICheckButtonTemplate")
		sellCheck:SetPoint("BOTTOMLEFT", QuestFrameCompleteQuestButton or QuestFrameRewardPanel, "TOPLEFT", -2, 2)
	end
	sellCheck:SetSize(28, 28)
	sellCheck:SetFrameLevel(sellCheck:GetParent():GetFrameLevel() + 10)
	sellCheck.label = sellCheck:CreateFontString(nil, "OVERLAY", "QuestFont")
	sellCheck.label:SetPoint("LEFT", sellCheck, "RIGHT", 2, 0)
	sellCheck.label:SetText("Sell chosen reward at next vendor")
	sellCheck:Hide()
end

-- Use the same font and color as the quest text ("Choose your reward"), so it reads
-- well both on the classic parchment and on darker quest frame skins.
local function StyleSellLabel()
	local ref = (QuestInfoRewardsFrame and QuestInfoRewardsFrame.ItemChooseText) or QuestInfoItemChooseText
	local label = sellCheck.label
	if ref and ref.GetFontObject and ref:GetFontObject() then
		label:SetFontObject(ref:GetFontObject())
		label:SetTextColor(ref:GetTextColor())
	end
	sellCheck:SetHitRectInsets(0, -label:GetStringWidth() - 6, 0, 0)
end

local function UpdateSellCheckbox()
	if not sellCheck then return end
	local n = GetNumQuestChoices and GetNumQuestChoices() or 0
	local show = db and db.autoSell and n > 0 and RewardPanelShown()
	if show then StyleSellLabel() end
	sellCheck:SetShown(show)
end

local function QueueSale(entry)
	table.insert(db.toSell, entry)
	print("|cffffd100Best Value:|r " .. entry.link .. " will be sold at the next vendor.")
	RefreshOptions()
end

-- Remember the chosen reward when the quest is completed with the box checked.
local function OnQuestReward(choice)
	if not (db and db.autoSell and sellCheck and sellCheck:IsShown() and sellCheck:GetChecked()) then return end
	if not choice or choice < 1 then return end
	-- Use data captured while the window was open; the quest may already be gone here.
	local info = rewardChoices[choice]
	local id = info and ItemID(info.link)
	if not id then return end
	local price = info.price or select(11, GetItemInfo(info.link)) or 0
	if price == 0 then
		print("|cffffd100Best Value:|r " .. info.link .. " can't be sold to a vendor.")
		return
	end
	QueueSale({ id = id, count = info.count, link = info.link, price = price })
end
if GetQuestReward then
	hooksecurefunc("GetQuestReward", OnQuestReward)
end

local Container = C_Container
local GetBagNumSlots = (Container and Container.GetContainerNumSlots) or GetContainerNumSlots
local GetBagItemID = (Container and Container.GetContainerItemID) or GetContainerItemID
local UseBagItem = (Container and Container.UseContainerItem) or UseContainerItem

local function SlotInfo(bag, slot)
	if Container and Container.GetContainerItemInfo then
		local info = Container.GetContainerItemInfo(bag, slot)
		if info then return info.stackCount, info.isLocked end
		return
	end
	local _, count, locked = GetContainerItemInfo(bag, slot)
	return count, locked
end

local function SellQueued()
	if not db or #db.toSell == 0 then return end
	if db.autoSell then
		local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
		for _, entry in ipairs(db.toSell) do
			local left = entry.count
			for bag = 0, lastBag do
				for slot = 1, GetBagNumSlots(bag) or 0 do
					if left > 0 and GetBagItemID(bag, slot) == entry.id then
						local count, locked = SlotInfo(bag, slot)
						-- Never sell a stack bigger than what the quest gave us.
						if count and not locked and count <= left then
							UseBagItem(bag, slot)
							left = left - count
						end
					end
				end
			end
			local sold = entry.count - left
			if sold > 0 then
				print("|cffffd100Best Value:|r Sold " .. entry.link .. (sold > 1 and (" x" .. sold) or "")
					.. " for " .. CoinString(entry.price * sold))
			end
		end
	end
	-- Only ever try once, so nothing is sold by accident later on.
	wipe(db.toSell)
	RefreshOptions()
end

-- Settings window (/bv) and the same page under Options -> AddOns -> Best Value.
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local LOGO = "Interface\\AddOns\\BestValue\\logo.png"
local QUEUE_ROWS = 4
local LOOT_MODES = { off = "|cff808080Off|r", ask = "Ask per item", auto = "Automatic" }

local function ApplyDisplay()
	if RewardPanelShown() then Update("reward") end
	QueueLogUpdate()
	UpdateSellCheckbox()
end

local function PlayCheckSound(checked)
	if SOUNDKIT then
		PlaySound(checked and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end

local function Header(parent)
	local band = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
	band:SetPoint("TOPLEFT", 4, -4)
	band:SetPoint("TOPRIGHT", -4, -4)
	band:SetHeight(68)
	band:SetColorTexture(1, 0.82, 0, 0.06)

	local logo = parent:CreateTexture(nil, "ARTWORK")
	logo:SetTexture(LOGO)
	logo:SetSize(48, 48)
	logo:SetPoint("TOPLEFT", 16, -14)

	local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -4)
	title:SetText("Best Value")

	local version = GetMetadata and GetMetadata("BestValue", "Version")
	local sub = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	sub:SetText("Quest reward vendor value" .. (version and ("  ·  v" .. version) or ""))

	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
	line:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
	line:SetHeight(1)
	line:SetColorTexture(1, 0.82, 0, 0.45)
	return -88
end

local function Section(parent, y, text)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", 20, y)
	fs:SetText(text:upper())
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
	line:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
	line:SetHeight(1)
	line:SetColorTexture(1, 0.82, 0, 0.2)
	return y - 20
end

-- A clickable row: checkbox, label and a muted description underneath.
local function Toggle(parent, y, key, label, desc, isEnabled)
	local row = CreateFrame("Frame", nil, parent)
	row:SetPoint("TOPLEFT", 14, y)
	row:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
	row:SetHeight(42)
	row:EnableMouse(true)

	local hl = row:CreateTexture(nil, "BACKGROUND")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.05)
	hl:Hide()

	local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	cb:SetSize(26, 26)
	cb:SetPoint("TOPLEFT", 4, -4)

	local title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOPLEFT", cb, "TOPRIGHT", 4, -5)
	title:SetText(label)

	local sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
	sub:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	sub:SetJustifyH("LEFT")
	sub:SetText(desc)

	local function Enter() hl:Show() end
	local function Leave() hl:Hide() end
	row:SetScript("OnEnter", Enter)
	row:SetScript("OnLeave", Leave)
	cb:HookScript("OnEnter", Enter)
	cb:HookScript("OnLeave", Leave)
	row:SetScript("OnMouseUp", function()
		if cb:IsEnabled() then cb:Click() end
	end)
	cb:SetScript("OnClick", function(self)
		local checked = self:GetChecked() and true or false
		db[key] = checked
		PlayCheckSound(checked)
		ApplyDisplay()
		RefreshOptions()
	end)

	table.insert(refreshers, function()
		cb:SetChecked(db[key])
		local enabled = not isEnabled or isEnabled()
		if enabled then
			cb:Enable()
			title:SetTextColor(1, 1, 1)
		else
			cb:Disable()
			title:SetTextColor(0.5, 0.5, 0.5)
		end
	end)
	return y - 46
end

-- A label followed by small checkboxes on one line. items = { { text, get, set } }.
local function InlineRow(parent, y, label, items, isEnabled)
	local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOPLEFT", 20, y - 6)
	title:SetText(label)

	local widgets, prev = {}, nil
	for i, item in ipairs(items) do
		local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		cb:SetSize(24, 24)
		if prev then
			cb:SetPoint("LEFT", prev, "RIGHT", 12, 0)
		else
			cb:SetPoint("TOPLEFT", 100, y)
		end
		local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", cb, "RIGHT", 1, 0)
		text:SetText(item.text)
		cb:SetScript("OnClick", function(self)
			local checked = self:GetChecked() and true or false
			item.set(checked)
			PlayCheckSound(checked)
			RefreshOptions()
		end)
		widgets[i] = { cb = cb, text = text, item = item }
		prev = text
	end

	table.insert(refreshers, function()
		local enabled = not isEnabled or isEnabled()
		local c = enabled and 1 or 0.5
		title:SetTextColor(c, c, c)
		for _, w in ipairs(widgets) do
			w.cb:SetChecked(w.item.get())
			w.cb:SetHitRectInsets(0, -w.text:GetStringWidth() - 4, 0, 0)
			if enabled then w.cb:Enable() else w.cb:Disable() end
			w.cb:SetAlpha(enabled and 1 or 0.5)
		end
	end)
	return y - 28
end

local function ModeItem(text, mode)
	return {
		text = text,
		get = function() return db.lootMode == mode end,
		set = function() db.lootMode = mode end,
	}
end

local function QualityItem(key, ...)
	local names = {}
	for _, q in ipairs({ ... }) do
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
		local name = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q)
		table.insert(names, (color and color.hex or "|cffffffff") .. name .. "|r")
	end
	return {
		text = table.concat(names, "/"),
		get = function() return db[key] end,
		set = function(checked) db[key] = checked end,
	}
end

local function QueueList(parent, y)
	local box = CreateFrame("Frame", nil, parent)
	box:SetPoint("TOPLEFT", 20, y)
	box:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
	box:SetHeight(QUEUE_ROWS * 22 + 8)
	local bg = box:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.35)

	local empty = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty:SetPoint("CENTER")
	empty:SetWidth(300)
	empty:SetText("Nothing queued. Check the box on the quest turn-in window, or sell dungeon and raid loot, to sell items at the next vendor.")

	local rows = {}
	for i = 1, QUEUE_ROWS do
		local r = CreateFrame("Button", nil, box)
		r:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
		r:SetPoint("RIGHT", box, "RIGHT", -4, 0)
		r:SetHeight(22)
		r:RegisterForClicks("RightButtonUp")
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.06)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(18, 18)
		r.icon:SetPoint("LEFT", 4, 0)
		r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.value:SetPoint("RIGHT", -6, 0)
		r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.name:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
		r.name:SetJustifyH("LEFT")
		r.name:SetWordWrap(false)
		r:SetScript("OnEnter", function(self)
			if not self.entry then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(self.entry.link)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Right-click to remove from the queue", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r:SetScript("OnClick", function(self)
			for idx, e in ipairs(db.toSell) do
				if e == self.entry then
					table.remove(db.toSell, idx)
					break
				end
			end
			GameTooltip:Hide()
			RefreshOptions()
		end)
		rows[i] = r
	end

	local footer = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	footer:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -8)

	local more = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	more:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)

	local clear = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	clear:SetSize(110, 22)
	clear:SetPoint("TOPRIGHT", footer, "BOTTOMRIGHT", 0, -6)
	clear:SetText("Clear queue")
	clear:SetScript("OnClick", function()
		wipe(db.toSell)
		RefreshOptions()
	end)

	table.insert(refreshers, function()
		local total = 0
		for _, e in ipairs(db.toSell) do total = total + e.price * e.count end
		for i, r in ipairs(rows) do
			local e = db.toSell[i]
			r.entry = e
			if e then
				r.icon:SetTexture(GetIcon and GetIcon(e.id))
				r.name:SetText(e.link .. (e.count > 1 and ("  x" .. e.count) or ""))
				r.value:SetText(CoinString(e.price * e.count))
				r:Show()
			else
				r:Hide()
			end
		end
		local n = #db.toSell
		empty:SetShown(n == 0)
		more:SetText(n > QUEUE_ROWS and ("+" .. (n - QUEUE_ROWS) .. " more") or "")
		footer:SetText(n > 0 and ("Total:  " .. CoinString(total)) or "")
		if n > 0 then clear:Enable() else clear:Disable() end
	end)
	return y - box:GetHeight() - 66
end

local function BuildOptions(parent)
	local y = Header(parent)
	y = Section(parent, y, "Quest rewards")
	y = Toggle(parent, y, "showCoin", "Highlight best reward",
		"Places a gold coin on the reward that sells for the most.")
	y = Toggle(parent, y, "showValue", "Show sell values",
		"Shows price × quantity on every reward choice.")
	y = Toggle(parent, y, "announce", "Announce in chat",
		"Prints the best reward to chat when turning in a quest.")
	y = Section(parent, y - 6, "Auto-sell")
	y = Toggle(parent, y, "autoSell", "Enable auto-sell",
		"Adds a checkbox to the turn-in window. Checked rewards are sold at the next vendor.")
	y = Toggle(parent, y, "autoSellDefault", "Check the box by default",
		"The sell checkbox starts checked on every quest turn-in.",
		function() return db.autoSell end)
	y = Section(parent, y - 6, "Dungeon & raid loot")
	y = InlineRow(parent, y, "Sell loot", {
		ModeItem("Off", "off"),
		ModeItem("Ask per item", "ask"),
		ModeItem("Automatic", "auto"),
	})
	local note = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 20, y)
	note:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
	note:SetJustifyH("LEFT")
	note:SetText("Loot is queued for the next vendor. Ask: a popup lets you choose per item. Automatic: every matching item is queued.")
	y = y - 30
	y = InlineRow(parent, y, "Qualities", {
		QualityItem("lootPoor", 0),
		QualityItem("lootCommon", 1),
		QualityItem("lootUncommon", 2),
		QualityItem("lootRare", 3, 4),
	}, function() return db.lootMode ~= "off" end)
	y = Section(parent, y - 6, "Sell queue")
	return QueueList(parent, y)
end

local settingsCategory, settingsPanel, window

local function SetDarkBackdrop(frame)
	if not frame.SetBackdrop then return end
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
	frame:SetBackdropBorderColor(0.65, 0.53, 0.2, 1)
end

local function CreateWindow()
	local w = CreateFrame("Frame", "BestValueOptionsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
	w:SetSize(460, 1)
	w:SetPoint("CENTER")
	w:SetFrameStrata("DIALOG")
	w:SetClampedToScreen(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:RegisterForDrag("LeftButton")
	w:SetScript("OnDragStart", w.StartMoving)
	w:SetScript("OnDragStop", w.StopMovingOrSizing)
	SetDarkBackdrop(w)

	local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)

	local y = BuildOptions(w)

	local hint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 20, 16)
	hint:SetText("/bv  open settings     /bv autosell  toggle auto-sell")

	w:SetHeight(-y + 40)
	w:SetScript("OnShow", function()
		PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN or 839)
		RefreshOptions()
	end)
	w:SetScript("OnHide", function()
		PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE or 840)
	end)
	tinsert(UISpecialFrames, "BestValueOptionsFrame") -- close with Escape
	w:Hide()
	return w
end

local function CreateSettings()
	window = CreateWindow()

	local panel = CreateFrame("Frame")
	panel.name = "Best Value"
	BuildOptions(panel)
	panel:SetScript("OnShow", RefreshOptions)

	-- No-op handlers expected by the various options frameworks.
	local noop = function() end
	panel.OnCommit, panel.OnDefault, panel.OnRefresh = noop, noop, noop
	panel.okay, panel.cancel, panel.default, panel.refresh = noop, noop, noop, noop

	if Settings and Settings.RegisterCanvasLayoutCategory then
		settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "Best Value")
		Settings.RegisterAddOnCategory(settingsCategory)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
	settingsPanel = panel
end

local function ToggleWindow()
	if window then window:SetShown(not window:IsShown()) end
end

-- Called from Retail's AddOn Compartment menu (see AddonCompartmentFunc in the Retail .toc).
function BestValue_OnAddonCompartmentClick()
	ToggleWindow()
end

SLASH_BESTVALUE1 = "/bestvalue"
SLASH_BESTVALUE2 = "/bv"
SlashCmdList.BESTVALUE = function(msg)
	if not db then return end
	if strtrim(msg or ""):lower() == "autosell" then
		db.autoSell = not db.autoSell
		UpdateSellCheckbox()
		RefreshOptions()
		print("|cffffd100Best Value:|r Auto-sell " .. (db.autoSell and "enabled" or "disabled") .. ".")
	else
		ToggleWindow()
	end
end

-- LibDataBroker launcher for Titan Panel, ChocolateBar, Bazooka, ElvUI etc.
-- The library ships with those addons, so nothing happens without one installed.
local broker
local function UpdateBroker()
	if not broker then return end
	local n, total = #db.toSell, 0
	for _, e in ipairs(db.toSell) do total = total + e.price * e.count end
	if n > 0 then
		broker.text = "|cffffd100" .. n .. "|r  " .. CoinString(total)
	else
		broker.text = db.autoSell and "On" or "|cff808080Off|r"
	end
end

local function CreateBroker()
	local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
	if not LDB or broker then return end
	broker = LDB:NewDataObject("Best Value", {
		type = "data source",
		label = "Best Value",
		text = "",
		icon = LOGO,
		OnClick = function(_, button)
			if button == "RightButton" or IsShiftKeyDown() then
				SlashCmdList.BESTVALUE("autosell")
			else
				ToggleWindow()
			end
		end,
		OnTooltipShow = function(tt)
			tt:AddLine("Best Value")
			tt:AddDoubleLine("Auto-sell", db.autoSell and "|cff20ff20On|r" or "|cff808080Off|r", 1, 1, 1)
		tt:AddDoubleLine("Dungeon & raid loot", LOOT_MODES[db.lootMode] or "", 1, 1, 1, 1, 1, 1)
			local total = 0
			if #db.toSell > 0 then
				tt:AddLine(" ")
				tt:AddLine("Sell queue", 1, 0.82, 0)
				for _, e in ipairs(db.toSell) do
					local value = e.price * e.count
					total = total + value
					tt:AddDoubleLine(e.link .. (e.count > 1 and ("  x" .. e.count) or ""), CoinString(value), 1, 1, 1, 1, 1, 1)
				end
				tt:AddDoubleLine("Total", CoinString(total), 1, 0.82, 0, 1, 1, 1)
			end
			tt:AddLine(" ")
			tt:AddLine("Click: open settings", 0.6, 0.6, 0.6)
			tt:AddLine("Shift-click or right-click: toggle auto-sell", 0.6, 0.6, 0.6)
		end,
	})
	table.insert(refreshers, UpdateBroker)
	UpdateBroker()
end

-- Dungeon and raid loot: items you loot inside an instance are queued for the next
-- vendor, either right away ("auto") or after a Sell/Keep answer in a popup ("ask").

-- Turn a chat format like "You receive loot: %sx%d." into a Lua pattern.
local function LootPattern(fmt)
	fmt = fmt:gsub("%%%d%$", "%%") -- "%1$s" -> "%s"
	fmt = fmt:gsub("[%(%)%.%[%]%*%+%-%?%^%$]", "%%%0")
	fmt = fmt:gsub("%%s", "(.+)")
	fmt = fmt:gsub("%%d", "(%%d+)")
	return "^" .. fmt .. "$"
end

-- The "multiple" variants come first, otherwise "x2" would end up in the link.
local lootPatterns = {}
for _, name in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF" }) do
	if _G[name] then table.insert(lootPatterns, LootPattern(_G[name])) end
end

local QUALITY_KEYS = { [0] = "lootPoor", [1] = "lootCommon", [2] = "lootUncommon", [3] = "lootRare", [4] = "lootRare" }
local QUEST_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local askList = {}     -- looted items waiting for a Sell/Keep answer
local waitingLoot = {} -- looted items whose data hasn't arrived from the server yet
local askFrame, ShowNextAsk

local function CreateAskFrame()
	local a = CreateFrame("Frame", "BestValueLootFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
	a:SetSize(320, 104)
	a:SetPoint("TOP", 0, -160)
	a:SetFrameStrata("DIALOG")
	a:SetClampedToScreen(true)
	a:SetMovable(true)
	a:EnableMouse(true)
	a:RegisterForDrag("LeftButton")
	a:SetScript("OnDragStart", a.StartMoving)
	a:SetScript("OnDragStop", a.StopMovingOrSizing)
	SetDarkBackdrop(a)

	local title = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("Best Value - sell this loot?")

	-- Closing keeps everything that hasn't been answered yet.
	local close = CreateFrame("Button", nil, a, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function()
		wipe(askList)
		a:Hide()
	end)

	a.item = CreateFrame("Button", nil, a)
	a.item:SetSize(36, 36)
	a.item:SetPoint("TOPLEFT", 14, -32)
	a.icon = a.item:CreateTexture(nil, "ARTWORK")
	a.icon:SetAllPoints()
	a.item:SetScript("OnEnter", function(self)
		if not askList[1] then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(askList[1].link)
		GameTooltip:Show()
	end)
	a.item:SetScript("OnLeave", function() GameTooltip:Hide() end)

	a.name = a:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	a.name:SetPoint("TOPLEFT", a.item, "TOPRIGHT", 10, -2)
	a.name:SetPoint("RIGHT", -12, 0)
	a.name:SetJustifyH("LEFT")
	a.name:SetWordWrap(false)
	a.value = a:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	a.value:SetPoint("TOPLEFT", a.name, "BOTTOMLEFT", 0, -4)
	a.more = a:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	a.more:SetPoint("BOTTOMLEFT", 14, 16)

	local function Answer(sell)
		local e = table.remove(askList, 1)
		if e and sell then QueueSale(e) end
		ShowNextAsk()
	end

	local keep = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
	keep:SetSize(80, 22)
	keep:SetPoint("BOTTOMRIGHT", -12, 10)
	keep:SetText("Keep")
	keep:SetScript("OnClick", function() Answer(false) end)

	local sell = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
	sell:SetSize(110, 22)
	sell:SetPoint("RIGHT", keep, "LEFT", -6, 0)
	sell:SetText("Sell at vendor")
	sell:SetScript("OnClick", function() Answer(true) end)
	return a
end

ShowNextAsk = function()
	local e = askList[1]
	if not e then
		if askFrame then askFrame:Hide() end
		return
	end
	askFrame = askFrame or CreateAskFrame()
	askFrame.icon:SetTexture(GetIcon and GetIcon(e.id))
	askFrame.name:SetText(e.link .. (e.count > 1 and ("  x" .. e.count) or ""))
	askFrame.value:SetText(CoinString(e.price * e.count))
	askFrame.more:SetText(#askList > 1 and ("+" .. (#askList - 1) .. " more") or "")
	askFrame:Show()
end

local function HandleLoot(link, count)
	if db.lootMode == "off" then return end
	local _, _, quality, _, _, _, _, _, _, _, price, classID = GetItemInfo(link)
	if quality == nil then
		table.insert(waitingLoot, { link = link, count = count })
		return
	end
	local key = QUALITY_KEYS[quality]
	local id = ItemID(link)
	if not (id and key and db[key]) or not price or price == 0 or classID == QUEST_ITEM_CLASS then return end
	local entry = { id = id, count = count, link = link, price = price }
	if db.lootMode == "auto" then
		QueueSale(entry)
	else
		table.insert(askList, entry)
		ShowNextAsk()
	end
end

local function RetryLoot()
	if #waitingLoot == 0 then return end
	local list = waitingLoot
	waitingLoot = {}
	for _, l in ipairs(list) do HandleLoot(l.link, l.count) end
end

local function OnLootMessage(msg)
	if not db or db.lootMode == "off" or type(msg) ~= "string" then return end
	-- Retail can hide chat contents from addons inside instances ("secret" values).
	if issecretvalue and issecretvalue(msg) then return end
	local inInstance, kind = IsInInstance()
	if not inInstance or (kind ~= "party" and kind ~= "raid") then return end
	for _, pattern in ipairs(lootPatterns) do
		local link, count = msg:match(pattern)
		if link then
			HandleLoot(link, tonumber(count) or 1)
			return
		end
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_FINISHED")
f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
f:RegisterEvent("CHAT_MSG_LOOT")
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "BestValue" then return end
		BestValueDB = BestValueDB or {}
		db = BestValueDB
		for k, v in pairs(defaults) do
			if db[k] == nil then db[k] = v end
		end
		db.toSell = db.toSell or {}
		CreateSellCheckbox()
		CreateSettings()
	elseif event == "PLAYER_LOGIN" then
		-- All addons are loaded by now, so the broker library is available if any panel ships it.
		CreateBroker()
	elseif event == "MERCHANT_SHOW" then
		SellQueued()
	elseif event == "QUEST_COMPLETE" then
		announced = false
		wipe(rewardChoices)
		if sellCheck then sellCheck:SetChecked(Opt("autoSellDefault")) end
		UpdateSellCheckbox()
		C_Timer.After(0, function()
			if RewardPanelShown() then Update("reward") end
			UpdateSellCheckbox()
		end)
	elseif event == "QUEST_FINISHED" then
		pending.reward = false
		HideAll("reward")
		if sellCheck then sellCheck:Hide() end
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if pending.reward and RewardPanelShown() then Update("reward") end
		if pending.log then QueueLogUpdate() end
		RetryLoot()
	elseif event == "CHAT_MSG_LOOT" then
		OnLootMessage(arg1)
	end
end)

-- QuestInfo is used by the turn-in window and (in some clients) by the quest log/map.
if QuestInfo_Display then
	hooksecurefunc("QuestInfo_Display", function()
		if RewardPanelShown() then
			Update("reward")
		else
			HideAll("reward")
			QueueLogUpdate()
		end
		UpdateSellCheckbox()
	end)
end

-- Classic quest log (QuestLogFrame).
if QuestLog_UpdateQuestDetails then
	hooksecurefunc("QuestLog_UpdateQuestDetails", QueueLogUpdate)
end
if QuestLog_SetSelection then
	hooksecurefunc("QuestLog_SetSelection", QueueLogUpdate)
end
if QuestLogFrame then
	QuestLogFrame:HookScript("OnShow", QueueLogUpdate)
end

-- PoB Agent Edition: Options rows for the AI chat (Stage 10), added by Modules/Main.lua.
-- Row 1: backend (Claude Code / Codex / Anthropic API key) + Sign in (opens the CLI's own
-- sign-in in a console window). Row 2: the API key. The key is written to AgentEdition.json
-- and never shown again: the box stays empty and says whether one is stored.

main.agentChat = main.agentChat or LoadModule("Agent/Chat")
local Chat = main.agentChat
local t_insert = table.insert

local ChatOptions = { }

local function backendList()
	local list = { }
	for _, e in ipairs(Chat.BACKENDS) do t_insert(list, { label = e.label, value = e.value }) end
	return list
end

function ChatOptions.addBackendRow(controls, anchor, x, y, labelSpacing)
	local current = Chat.settings().backend
	controls.agentChatBackend = new("DropDownControl", { "TOPLEFT", anchor, "TOPLEFT" }, { x, y, 170, 18 }, backendList(), nil)
	controls.agentChatBackend:SelByValue(current, "value")
	controls.agentChatBackendLabel = new("LabelControl", { "RIGHT", controls.agentChatBackend, "LEFT" }, { labelSpacing, 0, 0, 16 }, "^7AI chat backend:")
	local tip = { "The AI chat panel (right edge of the build screen) runs one of these.", "Every backend uses the same PoB tools and rules as your AI apps." }
	for _, e in ipairs(Chat.BACKENDS) do t_insert(tip, e.label .. ": " .. e.desc) end
	controls.agentChatBackend.tooltipText = table.concat(tip, "\n")
	controls.agentChatLogin = new("ButtonControl", { "LEFT", controls.agentChatBackend, "RIGHT" }, { 8, 0, 70, 18 }, "Sign in", function()
		local b = controls.agentChatBackend:GetSelValueByKey("value")
		if b == "claude" or b == "codex" then
			Chat.login(b)
			controls.agentChatLogin.label = "Opened"
		end
	end)
	controls.agentChatLogin.enabled = function()
		local b = controls.agentChatBackend:GetSelValueByKey("value")
		return b == "claude" or b == "codex"
	end
	controls.agentChatLogin.tooltipText = "Opens a window that runs the CLI's own sign-in\n(claude auth login / codex login) with your subscription account.\nPoB never sees your password or tokens."
end

function ChatOptions.addKeyRow(controls, anchor, x, y, labelSpacing)
	controls.agentChatKey = new("EditControl", { "TOPLEFT", anchor, "TOPLEFT" }, { x, y, 290, 18 }, "", nil, "%s", 200)
	controls.agentChatKey:SetPlaceholder(Chat.hasApiKey() and "stored (hidden)" or "not set")
	controls.agentChatKey:SetProtected(true)
	controls.agentChatKeyLabel = new("LabelControl", { "RIGHT", controls.agentChatKey, "LEFT" }, { labelSpacing, 0, 0, 16 }, "^7Anthropic API key (optional):")
	controls.agentChatKey.tooltipText = "Only for the 'Anthropic API key' backend (billed per token by Anthropic).\nKept in AgentEdition.json on this PC only, never shown again or sent anywhere\nexcept api.anthropic.com. Type a new key to replace it; Remove deletes it."
	controls.agentChatKeyRemove = new("ButtonControl", { "LEFT", controls.agentChatKey, "RIGHT" }, { 8, 0, 70, 18 }, "Remove", function()
		Chat.setApiKey("")
		controls.agentChatKey:SetText("")
		controls.agentChatKey:SetPlaceholder("not set")
	end)
	controls.agentChatKeyRemove.enabled = function() return Chat.hasApiKey() end
	-- Called by the Options Save button.
	return function()
		Chat.setSetting("backend", controls.agentChatBackend:GetSelValueByKey("value") or "claude")
		local key = controls.agentChatKey.buf
		if key:match("%S") then Chat.setApiKey(key) end
		Chat.check = nil
	end
end

return ChatOptions

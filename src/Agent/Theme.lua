-- Agent Edition: UI theme.
-- Core controls (buttons, dropdowns, edit boxes, lists) and the build screen
-- frame take their colours from here instead of hard-coded greys.
-- Set POB_THEME=classic to get the original PoB look back.

local classic = os.getenv("POB_THEME") == "classic"

local T = {
	name = classic and "classic" or "agent",

	-- Frame
	clear        = { 0.045, 0.051, 0.068 },  -- window background behind every tab
	bar          = { 0.075, 0.085, 0.110 },  -- top bar
	panel        = { 0.062, 0.070, 0.092 },  -- side bar
	divider      = { 0.190, 0.210, 0.270 },
	accent       = { 0.310, 0.820, 0.760 },

	-- Buttons
	btnBorder    = { 0.240, 0.270, 0.340 },
	btnBorderHi  = { 0.310, 0.820, 0.760 },
	btnBorderOff = { 0.150, 0.160, 0.200 },
	btnFill      = { 0.105, 0.118, 0.155 },
	btnFillHover = { 0.150, 0.172, 0.220 },
	btnFillOn    = { 0.115, 0.250, 0.250 },
	btnFillClick = { 0.200, 0.230, 0.290 },
	btnFillOff   = { 0.070, 0.076, 0.094 },

	-- Inputs (dropdowns, edit boxes, lists)
	inBorder     = { 0.240, 0.270, 0.340 },
	inBorderHi   = { 0.520, 0.580, 0.700 },
	inBorderOff  = { 0.150, 0.160, 0.200 },
	inFill       = { 0.060, 0.068, 0.088 },
	inFillHover  = { 0.110, 0.125, 0.160 },
	listBorder   = { 0.200, 0.225, 0.285 },
	listFill     = { 0.050, 0.057, 0.075 },
	arrow        = { 0.600, 0.650, 0.740 },
}

if classic then
	T.clear = { 0, 0, 0 }
	T.bar, T.panel, T.divider = { 0.2, 0.2, 0.2 }, { 0.1, 0.1, 0.1 }, { 0.85, 0.85, 0.85 }
	T.btnBorder, T.btnBorderHi, T.btnBorderOff = { 0.5, 0.5, 0.5 }, { 1, 1, 1 }, { 0.33, 0.33, 0.33 }
	T.btnFill, T.btnFillHover, T.btnFillOn, T.btnFillClick, T.btnFillOff = { 0, 0, 0 }, { 0.33, 0.33, 0.33 }, { 0.33, 0.33, 0.33 }, { 0.5, 0.5, 0.5 }, { 0, 0, 0 }
	T.inBorder, T.inBorderHi, T.inBorderOff = { 0.5, 0.5, 0.5 }, { 1, 1, 1 }, { 0.33, 0.33, 0.33 }
	T.inFill, T.inFillHover = { 0, 0, 0 }, { 0.33, 0.33, 0.33 }
	T.listBorder, T.listFill, T.arrow = { 0.66, 0.66, 0.66 }, { 0.05, 0.05, 0.05 }, { 0.5, 0.5, 0.5 }
end

-- SetDrawColor from a theme entry, e.g. UITheme.set("btnBorder")
function T.set(key, alpha)
	local c = T[key]
	SetDrawColor(c[1], c[2], c[3], alpha or 1)
end

UITheme = T
SetClearColor(T.clear[1], T.clear[2], T.clear[3])
return T

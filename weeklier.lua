require('common')
local bit = require('bit')
local imgui = require('imgui')

addon.name    = 'weeklier'
addon.author  = 'Pathead'
addon.version = '1.2'
addon.desc    = 'Tracks weekly quest completion across characters.'
addon.link    = 'https://github.com/patheed-ffxi/weeklier'

local json = require('json')

-- Load key item data (name -> numeric ID mapping).
-- Uses pcall so the addon still loads if the file is missing or malformed.
local KEY_ITEMS = nil
do
    local ok, result = pcall(require, 'data.key_item')
    if ok and type(result) == 'table' then
        KEY_ITEMS = result
    else
        print(string.format('\30\02[weeklier]\30\01 \30\68ERROR: Failed to load data/key_item.lua: %s\30\01',
            tostring(result)))
        print('\30\02[weeklier]\30\01 Key item verification will be unavailable.')
        KEY_ITEMS = {}
    end
end

-- ============================================================================
-- Config - QUEST DEFINITIONS
-- ============================================================================
-- Each quest has:
--   name               : display name
--
-- Non-ENM weekly quest status is derived from packet data and/or chat detection:
--   quest_log_id        : numeric log ID (0=San d'Oria, 1=Bastok, 2=Windurst,
--                         3=Jeuno, 4=Other, 5=Outlands, 6=Aht Urhgan,
--                         7=Crystal War, 8=Abyssea, 9=Adoulin, 10=Coalition)
--   quest_id            : numeric quest ID within that log (0-255 bit index)
--                         Used with is_quest_active() from packet 0x056 data.
--
-- Key-item verification (from key_item.lua names, checked via packet 0x055):
--   ki_quest_active     : KI name that the player receives when the quest is accepted.
--                         Having this KI = quest needs to be completed (NEED TO COMPLETE).
--                         KI removal is detected via 0x055 packet updates and triggers
--                         READY TO TURN IN status (the KI is consumed when the objective
--                         is completed, meaning the player needs to go turn in the quest).
--   ki_active_is_completion : boolean. If true, ki_quest_active removal goes straight
--                         to COMPLETED instead of READY TO TURN IN. Use for quests
--                         where consuming the KI IS the completion (no turn-in step).
--   ki_quest_incomplete : KI name that the player holds while the quest is in progress.
--                         Having this KI = ready to turn in (READY TO TURN IN).
--                         KI removal is detected via 0x055 packet updates and triggers
--                         COMPLETED status (the KI is consumed on turn-in).
--
-- Status derivation for non-ENM quests (current character only):
--   COMPLETED        : ki_quest_incomplete KI removed (turn-in), OR
--                      ki_quest_active KI removed with ki_active_is_completion, OR
--                      complete_phrase detected in chat, OR stored as completed
--   READY TO TURN IN : player has ki_quest_incomplete KI, OR
--                      ki_quest_active KI removed (objective done, needs turn-in)
--   NEED TO COMPLETE : quest is active (0x056), has ki_quest_active KI, OR
--                      flag_phrase detected in chat
--   NOT STARTED      : no active indicators and no stored progress
--
-- Chat-based flag detection (alternative to quest_log_id/quest_id):
--   flag_phrase       : if present, the addon will watch for this phrase in chat.
--                       When seen, the quest is advanced to NEED TO COMPLETE.
--                       Useful for quests that don't appear in the quest log
--                       (e.g. bugged quests) but still have a chat message
--                       when flagged. The phrase is matched after normalizing
--                       (lowercase, stripped control chars).
--                       Can be a single string or a table of strings to match
--                       multiple phrases (e.g. different text for first-time
--                       vs repeat completions).
--
-- Chat-based completion detection:
--   complete_phrase   : if present, the addon will watch for this phrase in chat.
--                       When seen, the quest is advanced to COMPLETED.
--                       Useful for quests that are bugged (e.g. always show as
--                       active in the quest log) and don't have a ki_quest_incomplete
--                       KI removal to detect turn-in.
--
-- Status is derived from live packet data for the current character and
-- persisted to JSON so it can be viewed when logged into a different character.
--
-- For ENM / Limbus / other cooldown-based rewards (type = 'enm'):
--   ki_quest_active     : KI name (from key_item.lua) used to verify possession via packet.
--   ki_display_name     : The human-readable KI name as it appears in the chat message
--                         "Obtained key item: <ki_display_name>."  Used to detect when the
--                         KI was obtained and start the cooldown timer.
--   obtain_phrase       : Alternative to ki_quest_active/ki_display_name for cooldown
--                         rewards that are regular items rather than key items (e.g.
--                         HAAP pages). Full chat phrase that marks the reward being
--                         received, matched after normalizing
--                         (e.g. "Obtained: Page from the Dragon Chronicles").
--   enm_cooldown_days   : Number of real days for the cooldown (default 5 for ENMs,
--                         3 for Limbus, 1 for HAAP pages).
--   These are displayed in their own cooldown section in the UI, separate from
--   weekly quests. Cooldown data is NOT reset on weekly rollover - it uses its
--   own timer.
--
-- For kill-based quests (type = 'kill_mob'):
--   kill_mob            : name of the mob whose death should complete the quest
--   No flag/complete phrases needed - killing the mob IS the quest.
--
--   Chat-based detection uses two signals within a short time window:
--     1. death line: "defeats the <kill_mob>" or
--        "<kill_mob> falls to the ground"
--     2. "<your character> gains <x> experience points." for the kill
--        ("limit points" also counts, for kills made in limit mode)
--   The two signals may arrive in EITHER order (message order is not
--   guaranteed under server load, e.g. when many players hit the same NM);
--   they confirm as long as both occur within KILL_CONFIRM_WINDOW seconds.
--   Known limitations: the death line can come from any nearby player's
--   kill, so an unrelated XP gain inside the window can confirm a kill you
--   didn't make; a death line hidden by chat filters or happening out of
--   range is only covered by the kill_xp_zones path below.
--
--   kill_xp_zones       : optional set of zone ids ({ [zone_id] = true }).
--   kill_xp_amount      : optional exact XP amount. When both are set, an XP
--                         gain of exactly that amount while in one of those
--                         zones confirms the kill BY ITSELF. Used when the
--                         mob can die out of message range entirely (e.g.
--                         Highwind dying at the far end of the airship shows
--                         no defeat line at all), so the uniquely-identifying
--                         XP award is the only signal that reliably reaches
--                         the player.
-- ============================================================================

-- How many seconds after a "defeats the X" message to wait for the XP message
local KILL_CONFIRM_WINDOW = 5.0

-- Airship travel zone ids (used by kill_xp_zones for Highwind).
-- 223 = San d'Oria-Jeuno, 224 = Bastok-Jeuno, 225 = Windurst-Jeuno,
-- 226 = Kazham-Jeuno
local AIRSHIP_ZONES = {
    [223] = true,
    [224] = true,
    [225] = true,
    [226] = true,
}

-- Debug mode: when true, logs detailed diagnostic info about status changes,
-- packet processing, KI checks, quest active checks, etc.
local debug_mode = false


local QUESTS = {
    {
        name                = 'Secrets of Ovens Lost',
        -- quest is bugged and always shows as active
        ki_quest_incomplete = 'TAVNAZIAN_COOKBOOK',
        flag_phrase = 'if you happen to find any more, the children would be so delighted'
    },
    {
        name                = 'Uninvited Guests',
        -- No quest_log_id/quest_id: quest is bugged and always shows as active.
        ki_quest_active     = 'MONARCH_LINN_PATROL_PERMIT',
        complete_phrase     = 'You deserve something for putting your neck on the line',
    },
    {
        name                = 'Spice Gals',
        -- No quest_log_id/quest_id: quest is bugged and doesn't appear in active quests.
        ki_quest_incomplete = 'RIVERNEWORT',
        flag_phrase         = {
            'you find yourself in possession of a sprig of Rivernewort, then I should dearly love to prepare',
            'it would be much appreciated if you might stop and collect another sprig of Rivernewort'
        }
    },
    {
        name                    = 'Requiem of Sin',
        ki_quest_active         = 'LETTER_FROM_THE_MITHRAN_TRACKERS',
        ki_active_is_completion = true,
    },
    {
        name                = 'Limbus - Cosmo Cleanse',
        type                = 'enm',
        ki_quest_active     = 'COSMO_CLEANSE',
        ki_display_name     = 'Cosmo-Cleanse',
        enm_cooldown_days   = 3,
    },
    {
        name                = 'Monarch Linn ENM',
        type                = 'enm',
        ki_quest_active     = 'MONARCH_BEARD',
        ki_display_name     = 'Monarch beard',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Test Your Mite',
        type                = 'enm',
        ki_quest_active     = 'ASTRAL_COVENANT',
        ki_display_name     = 'Astral Covenant',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Mine Shaft #2716 ENM',
        type                = 'enm',
        ki_quest_active     = 'SHAFT_GATE_OPERATING_DIAL',
        ki_display_name     = 'Shaft Gate Operating Dial',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Boneyard Gully ENM',
        type                = 'enm',
        ki_quest_active     = 'MIASMA_FILTER',
        ki_display_name     = 'Miasma Filter',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Bearclaw Pinnacle ENM',
        type                = 'enm',
        ki_quest_active     = 'ZEPHYR_FAN',
        ki_display_name     = 'Zephyr Fan',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Dem: You Are What You Eat',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ANTIPATHY',
        ki_display_name     = 'Censer of Antipathy',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Mea: Playing Host',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ANIMUS',
        ki_display_name     = 'Censer of Animus',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Holla: Simulant',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ABANDONMENT',
        ki_display_name     = 'Censer of Abandonment',
        enm_cooldown_days   = 5,
    },
    {
        name                = 'Vahzl: Pulling the Plug',
        type                = 'enm',
        ki_quest_active     = 'CENSER_OF_ACRIMONY',
        ki_display_name     = 'Censer of Acrimony',
        enm_cooldown_days   = 5,
    },
    -- -----------------------------------------------------------------------
    -- HAAP point exchanges: EXP pages are regular items (not key items)
    -- handed out by the HAAP NPC, each on its own independent 24h cooldown.
    -- Detected via the "Obtained: <item>" chat line when the exchange happens.
    -- -----------------------------------------------------------------------
    {
        name                = "HAAP - Miratete's Memoirs",
        type                = 'enm',
        obtain_phrase       = "Obtained: Page from Miratete's Memoirs",
        enm_cooldown_days   = 1,
    },
    {
        name                = 'HAAP - Dragon Chronicles',
        type                = 'enm',
        obtain_phrase       = 'Obtained: Page from the Dragon Chronicles',
        enm_cooldown_days   = 1,
    },
    -- -----------------------------------------------------------------------
    -- Kill-based quest: no flag or turn-in, just kill the mob and get XP.
    -- "defeats the <kill_mob>" + "<you> gains X experience points" = COMPLETED.
    -- -----------------------------------------------------------------------
    {
         name     = 'Kill Highwind',
         type     = 'kill_mob',
         kill_mob = 'Highwind',
         -- Highwind can die out of message range (players spread out across
         -- the airship), in which case no defeat line ever reaches the
         -- client. Nothing else on an airship awards exactly 3000 XP, so
         -- that alone confirms the kill in these zones.
         kill_xp_amount = 3000,
         kill_xp_zones  = AIRSHIP_ZONES,
    },
}

-- ============================================================================
-- Eco Warrior Config
-- ============================================================================
-- Eco Warriors are a special round-robin set: three quests (one per nation),
-- only one can be completed per week, and each must be completed before it can
-- be repeated. e.g. if you do Sandy week 1, you must do Bastok or Windy week 2
-- before you can do Sandy again.
--
-- Fields:
--   nation              : display name
--   key                 : unique key for storage/lookup
--   quest_log_id        : numeric log ID for is_quest_active() (may be bugged)
--   quest_id            : numeric quest ID for is_quest_active() (may be bugged)
--   ki_quest_incomplete : KI name indicating quest is in progress (ready to turn in)
--   flag_phrase         : chat phrase to detect quest being flagged (alternative to
--                         quest_log_id/quest_id for bugged quests that don't always
--                         appear in the quest log). Matched after normalizing.
--                         Can be a single string or a table of strings to match
--                         multiple phrases (e.g. first-time vs repeat text).
--   verify_phrase       : chat phrase to detect the in-zone verification step.
--                         After obtaining the KI, the player must talk to an NPC in
--                         the zone to verify it before returning to the quest giver.
--                         When detected, status changes from 'Return to NPC' to
--                         'Need To Complete'. Matched after normalizing.
--                         Can be a single string or a table of strings.
--
-- Status per nation:
--   'Available'        - can be flagged this week
--   'Flagged'          - quest is currently active but KI not yet obtained
--   'Return to NPC'    - player has the KI but hasn't verified it in the zone yet
--   'Need To Complete' - player has verified the KI, needs to return to quest giver
--   'Completed'        - completed this week
--   'Not Available'    - another nation was flagged/completed this week, OR
--                        this nation has already been completed in the current
--                        round-robin cycle (must do other nations first)
--
-- Stored per character in data[char].eco[nation_key] = {
--   completed_week  = "2026-W10" or nil  (the week key when last completed)
--   stored_status   = "Available" etc.   (persisted for cross-char viewing)
--   stored_flagged  = true/nil           (set by flag_phrase, cleared on completion)
--   stored_verified = true/nil           (set by verify_phrase, cleared on completion)
-- }
--
-- Round-robin cycle tracking: data[char].eco_cycle = { [nation_key] = true }
-- Tracks which nations have been completed in the current cycle. When all
-- nations are completed, eco_cycle is cleared (all become available again).
-- ============================================================================
local ECO_WARRIORS = {
    {
        nation              = "San d'Oria",
        key                 = 'sandoria',
        quest_log_id        = 0,
        quest_id            = 97,
        ki_quest_incomplete = 'INDIGESTED_STALAGMITE',
        flag_phrase         = 'Rojaireaut, our V.E.R.M.I.N. agent in the field, will be waiting for you in the caves',
        verify_phrase       = "What's that you have there? An indigested stalagmite from the fiend",
    },
    {
        nation              = 'Bastok',
        key                 = 'bastok',
        quest_log_id        = 1,
        quest_id            = 65,
        ki_quest_incomplete = 'INDIGESTED_ORE',
        flag_phrase         = 'Degga, one of our V.E.R.M.I.N. field agents, will give you further instructions',
        verify_phrase       = 'Lemme see that... Huh, an indigested ore. Take it on back to Raifa',
    },
    {
        nation              = 'Windurst',
        key                 = 'windurst',
        quest_log_id        = 2,
        quest_id            = 84,
        ki_quest_incomplete = 'INDIGESTED_MEAT',
        flag_phrase         = 'Our V.E.R.M.I.N. field agent, Ahko Mhalijikhari, will be waiting in the maze',
        verify_phrase       = 'How...lovely. A chunk of indigested meat',
    },
}

-- ============================================================================
-- Dynamis Config
-- ============================================================================
-- Characters can enter Dynamis twice per week (same weekly reset).
-- Tracked by detecting zone-in via packet 0x00A. Active session time is
-- tracked via system chat messages ("expelled from Dynamis in X minutes"
-- and "stay in Dynamis has been extended by X minutes") so that leaving
-- and re-entering the same zone does not count as a second weekly entry.
-- Stored per character in data[char].dynamis = {
--   { zone = "Dynamis - Xarcabard", zone_id = 135, time = <unix timestamp> },
--   { zone = "Dynamis - Jeuno",     zone_id = 188, time = <unix timestamp> },
-- }
-- Max 2 entries per week. Reset on weekly rollover.
local DYNAMIS_ZONES = {
    [39]  = 'Dynamis - Valkurm',
    [40]  = 'Dynamis - Buburimu',
    [41]  = 'Dynamis - Qufim',
    [42]  = 'Dynamis - Tavnazia',
    [134] = 'Dynamis - Beaucedine',
    [135] = 'Dynamis - Xarcabard',
    [185] = "Dynamis - San d'Oria",
    [186] = 'Dynamis - Bastok',
    [187] = 'Dynamis - Windurst',
    [188] = 'Dynamis - Jeuno'
}

local DYNAMIS_MAX_ENTRIES = 2

-- ============================================================================
-- EXP Band Config
-- ============================================================================
-- Three EXP bands exist (Chariot/Empress/Emperor), but a player can only
-- hold one at a time. On zone-in, the player's Inventory, Wardrobe, and
-- Wardrobe2 are scanned for any of these item IDs. If found (and at least 1
-- charge remains), the next-use timestamp is read from item.Extra and stored.
-- A chat notification fires when the cooldown expires (similar to ENM alerts).
-- Stored per character in data[char].exp_band = {
--   item_id      = numeric item id
--   name         = display name (e.g. "Chariot Band")
--   expiry_time  = unix timestamp when the band's use cooldown ends
--   charges      = remaining charges (>= 1 when stored)
--   notified_ready = true after the READY alert has fired (cleared on rescan)
-- }
local EXP_BANDS = {
    [15761] = 'Chariot Band',
    [15762] = 'Empress Band',
    [15763] = 'Emperor Band',
}

-- Vana'diel epoch in real-world unix time (used to convert item.Extra
-- timestamps for use-cooldown items such as EXP bands).
local VANA_OFFSET = 1009810800

-- Bags scanned for EXP bands (bands cannot be used from other storage).
-- Slot counts are upper bounds: scanning a few empty slots is cheap, while
-- under-scanning an expanded bag (e.g. Gobbiebag inventory upgrades) makes
-- the scan miss a real band and falsely clear it.
local EXP_BAND_CONTAINER_MAXES = {
    Inventory = 80,
    Satchel   = 80,
    Wardrobe  = 80,
    Wardrobe2 = 80,
}
local EXP_BAND_BAG_NAMES = {
    [0]  = 'Inventory',
    [5]  = 'Satchel',
    [8]  = 'Wardrobe',
    [10] = 'Wardrobe2',
}

-- ============================================================================
-- State
-- ============================================================================
local save_path                             -- set in load_cb (addon.path available then)
local show_window = { false }               -- imgui bool wrapper
local select_current_tab = false            -- when true, auto-select current char tab on next frame
local data = {}                             -- { [char_name] = { week, quests, enms, eco, eco_cycle, dynamis }, _hidden = { [name] = true } }
local current_char                          -- detected from party info
local last_packet_char                      -- tracks which char the packet-derived bitmaps belong to

-- Active Dynamis session tracking.
-- When the player is inside a Dynamis zone, this holds the session details
-- so that zoning out and back in doesn't count as a second weekly entry.
-- Session time is derived from system chat messages:
--   "You will be expelled from Dynamis in X minutes (Earth time)." -> sets expiry
--   "Your stay in Dynamis has been extended by X minutes."         -> extends expiry
-- Fields:
--   zone_id     : the Dynamis zone ID the player entered
--   zone_name   : human-readable zone name
--   expiry_time : UTC unix timestamp when the Dynamis timer runs out
--   last_update : os.time() when we last updated this session
local dynamis_active_session = nil
local override_selected_char = nil          -- selected character for manual status override in Config tab

-- Hidden quests (global UI preference, not per-character).
-- Stored as data._hidden = { [quest_name] = true, ... }
-- Loaded/saved alongside all other data in the same JSON file.
local hidden_quests = {}

local function is_quest_hidden(quest_name)
    return hidden_quests[quest_name] == true
end

local function set_quest_hidden(quest_name, hide)
    if hide then
        hidden_quests[quest_name] = true
    else
        hidden_quests[quest_name] = nil
    end
    data._hidden = hidden_quests
end

-- Kill-mob tracking: when we see "defeats the X", we store the quest indices
-- and a timestamp. If an XP message arrives within KILL_CONFIRM_WINDOW we
-- advance those quests to COMPLETED.
-- { [quest_index] = os.clock() timestamp of the "defeats" message }
local pending_kills = {}

-- os.clock() timestamp of the player's most recent XP/limit gain message.
-- Message order is not guaranteed under load - the XP line can render before
-- the defeat line - so XP gains are remembered and checked when a death is
-- detected shortly afterwards (see queue_or_confirm_kill).
local last_xp_gain_time = nil

-- ============================================================================
-- ENM / Limbus Alert System
-- ============================================================================
-- Periodically checks ENM cooldowns and sends a chat notification when a
-- key item becomes ready to obtain (cooldown expired).
-- Tracked per-character via enm_data.notified_ready = true/false.
-- Cleared when a new KI is obtained (cooldown starts), so the next expiry
-- triggers a fresh alert.
local ENM_ALERT_CHECK_INTERVAL = 60      -- seconds between periodic checks
local enm_alert_last_check = 0           -- os.time() of last periodic check
local enm_alert_login_done = {}          -- { [char_name] = true } login alert fired this session

-- ============================================================================
-- EXP Band Alert / Settings
-- ============================================================================
-- Tracked per character via cd.exp_band.notified_ready.
-- Settings (global, persisted in data._settings):
--   exp_band_tracking_enabled : when false, scanning, alerts and the UI
--                               section are all disabled.
local DEFAULT_SETTINGS = {
    exp_band_tracking_enabled = true,
}
local settings = {}
for k, v in pairs(DEFAULT_SETTINGS) do settings[k] = v end

local exp_band_alert_login_done = {}     -- { [char_name] = true }

-- os.time() deadline for the deferred full inventory scan, scheduled by the
-- 0x01D Inventory Finish handler. The scan must not run at packet time: the
-- client hasn't processed the inventory burst into memory yet, so an
-- immediate scan would see empty bags and wrongly clear the stored band.
-- Zone loads can also take far longer than the initial delay, so an empty
-- scan while a band is stored is retried (see d3d_present) rather than
-- trusted immediately - only the final retry is allowed to clear.
local EXP_BAND_SCAN_DELAY = 2            -- seconds after 0x01D before scanning
local EXP_BAND_SCAN_MAX_RETRIES = 10     -- empty re-scans tolerated before clearing
local exp_band_scan_at = nil
local exp_band_scan_retries = 0

-- ============================================================================
-- Key Item Tracking (packet 0x055)
-- ============================================================================
-- Bitmap of obtained key items.  Indexed [table_index][dword_index] = uint32.
-- table_index 0-6, each table has 16 uint32s = 512 bits = 512 key items.
local ki_bitmap = {}

-- Previous snapshot of ki_bitmap, used to detect KI removals between packets.
-- When a tracked KI transitions from "has" to "doesn't have", the addon
-- updates the quest status accordingly (see process_ki_removals).
local prev_ki_bitmap = {}

-- Reverse lookup: uppercase key item name -> numeric ID
-- Built once from KEY_ITEMS at load time.
local ki_name_to_id = {}

-- keyed by log_id, value = { [0]=u32, ... [7]=u32 }
local active_quest_blocks = {}

local QUEST_OFFER_PORT_TO_LOG_ID = {
    [0x0050] = 0,   -- San d'Oria
    [0x0058] = 1,   -- Bastok
    [0x0060] = 2,   -- Windurst
    [0x0068] = 3,   -- Jeuno
    [0x0070] = 4,   -- Other Areas
    [0x0078] = 5,   -- Outlands
    [0x0080] = 6,   -- Aht Urhgan
    [0x0088] = 7,   -- Crystal War
    [0x00E0] = 8,   -- Abyssea
    [0x00F0] = 9,   -- Adoulin
    [0x0100] = 10,  -- Coalition
}


-- ============================================================================
-- Logging
-- ============================================================================
local function log(msg)
    print(string.format('\30\02[weeklier]\30\01 %s', msg))
end

local function dlog(msg)
    if not debug_mode then return end
    print(string.format('\30\02[weeklier:DBG]\30\01 %s', msg))
end

local function build_ki_lookup()
    if not KEY_ITEMS or next(KEY_ITEMS) == nil then
        log('WARNING: Key item data is empty - KI-based quest detection will not work.')
        return
    end
    local count = 0
    for name, id in pairs(KEY_ITEMS) do
        ki_name_to_id[string.upper(name)] = id
        count = count + 1
    end
    dlog(string.format('Built KI lookup: %d entries.', count))
end

-- Read a little-endian uint32 from a binary string at 1-based offset.
local function u32le(s, offset)
    local b1, b2, b3, b4 = string.byte(s, offset, offset + 3)
    if not b1 or not b2 or not b3 or not b4 then return 0 end
    return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

-- Read a little-endian uint16 from a binary string at 1-based offset.
local function u16le(s, offset)
    local b1, b2 = string.byte(s, offset, offset + 1)
    if not b1 or not b2 then return 0 end
    return b1 + bit.lshift(b2, 8)
end

local function read_u32x8(pkt)
    local t = {}
    for i = 0, 7 do
        t[i] = u32le(pkt, 0x04 + 1 + (i * 4))
    end
    return t
end

-- Returns true if there is an active Dynamis session that has not yet expired.
local function is_dynamis_session_active()
    if not dynamis_active_session then return false end
    return dynamis_active_session.expiry_time > os.time()
end

-- Check whether the player currently holds a key item by numeric ID.
local function has_key_item(ki_id)
    local table_index = math.floor(ki_id / 512)
    local bit_index   = ki_id % 512
    local dword_index = math.floor(bit_index / 32)
    local bit_offset  = bit_index % 32

    local tbl = ki_bitmap[table_index]
    if not tbl then return false end
    local dword = tbl[dword_index] or 0
    return bit.band(dword, bit.lshift(1, bit_offset)) ~= 0
end

-- Check whether the player previously held a key item (before the latest 0x055 update).
local function had_key_item(ki_id)
    local table_index = math.floor(ki_id / 512)
    local bit_index   = ki_id % 512
    local dword_index = math.floor(bit_index / 32)
    local bit_offset  = bit_index % 32

    local tbl = prev_ki_bitmap[table_index]
    if not tbl then return false end
    local dword = tbl[dword_index] or 0
    return bit.band(dword, bit.lshift(1, bit_offset)) ~= 0
end

-- Resolve a quest's key_item config string to a numeric ID (cached per quest).
local ki_id_cache = {}
local function resolve_ki_id(ki_name)
    if not ki_name or ki_name == '' then return nil end
    local upper = string.upper(ki_name)
    if ki_id_cache[upper] ~= nil then return ki_id_cache[upper] end
    local id = ki_name_to_id[upper]
    ki_id_cache[upper] = id or false
    return id or nil
end

local function is_bit_set_in_block(block, bit_index)
    if not block or bit_index < 0 or bit_index > 255 then
        return false
    end

    local dword_index = math.floor(bit_index / 32)
    local bit_in_dword = bit_index % 32
    local value = block[dword_index] or 0

    return bit.band(value, bit.lshift(1, bit_in_dword)) ~= 0
end

local function is_quest_active(log_id, quest_id)
    local block = active_quest_blocks[log_id]
    return is_bit_set_in_block(block, quest_id)
end

local function get_active_quest_ids(log_id)
    local out = {}
    local block = active_quest_blocks[log_id]
    if not block then
        return out
    end

    for quest_id = 0, 255 do
        if is_bit_set_in_block(block, quest_id) then
            out[#out + 1] = quest_id
        end
    end

    return out
end


-- ============================================================================
-- Week Key - used to auto-reset when a new week starts
-- ============================================================================
-- Returns a string like "2026-W11" representing ISO week.
-- Weekly reset: midnight Monday JST (Japan Standard Time, UTC+9).
-- This is a fixed point in time: Sunday 15:00 UTC.
-- All calculations use UTC so the reset is correct for every timezone.

-- Returns the current time as a UTC unix timestamp.
-- os.time() returns seconds since Unix epoch (Jan 1 1970 00:00 UTC),
-- which is already a UTC-based value on all standard platforms.
local function now_utc()
    return os.time()
end

-- Returns the UTC unix timestamp of the next weekly reset.
-- Reset = midnight Monday JST = Sunday 15:00 UTC.
-- If we are currently past that moment, returns next week's reset.
local function get_next_reset_time()
    local utc = now_utc()
    local t = os.date('!*t', utc)

    -- Lua wday: Sunday=1 .. Saturday=7
    -- We want next Sunday 15:00 UTC (which is Monday 00:00 JST).
    local days_until_sunday = (1 - t.wday) % 7  -- 0 if today is Sunday

    -- Compute Sunday 15:00 UTC from today's UTC midnight
    local today_midnight_utc = utc - (t.hour * 3600 + t.min * 60 + t.sec)
    local reset = today_midnight_utc + days_until_sunday * 86400 + 15 * 3600

    -- If we're already past that reset (or it's exactly now), jump to next week
    if utc >= reset then
        reset = reset + 7 * 86400
    end

    return reset
end

-- Format a duration in seconds as "Xd Xh Xm Xs"
local function format_countdown(seconds)
    if seconds <= 0 then return 'NOW!' end
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if d > 0 then
        return string.format('%dd %dh %dm %ds', d, h, m, s)
    elseif h > 0 then
        return string.format('%dh %dm %ds', h, m, s)
    else
        return string.format('%dm %ds', m, s)
    end
end

local function get_week_key()
    -- The week key is based on when the last reset occurred (Sunday 15:00 UTC).
    -- We find the most recent reset and derive the ISO week from that moment.
    local next_reset = get_next_reset_time()
    local last_reset = next_reset - 7 * 86400
    local t = os.date('!*t', last_reset)
    -- ISO weekday: Monday=1 .. Sunday=7
    local iso_wday = t.wday == 1 and 7 or (t.wday - 1)
    local thursday = last_reset + (4 - iso_wday) * 86400
    local thu_t = os.date('!*t', thursday)
    -- Compute Jan 1 00:00 UTC of that year using yday (day of year) from thursday.
    -- thursday is a UTC epoch timestamp, so subtracting (yday-1) days + time-of-day
    -- gives us Jan 1 00:00 UTC as an epoch timestamp without any local time conversion.
    local jan1 = thursday - (thu_t.yday - 1) * 86400 - thu_t.hour * 3600 - thu_t.min * 60 - thu_t.sec
    local week_num = math.floor((thursday - jan1) / 604800) + 1
    return string.format('%d-W%02d', thu_t.year, week_num)
end

-- ============================================================================
-- Persistence
-- ============================================================================
local function save_data()
    if not save_path then return end
    -- Write to a temp file first, then swap it in, so a crash mid-write
    -- can't truncate the existing save.
    local tmp_path = save_path .. '.tmp'
    local f = io.open(tmp_path, 'w+')
    if not f then
        log('Failed to open save file for writing.')
        return
    end
    f:write(json.encode(data))
    f:close()
    os.remove(save_path)
    local ok, err = os.rename(tmp_path, save_path)
    if not ok then
        log(string.format('Failed to finalize save file: %s', tostring(err)))
    end
end

local function load_data()
    if not save_path then return end
    local f = io.open(save_path, 'r')
    if not f then
        data = {}
        data._settings = settings
        return
    end
    local raw = f:read('*a')
    f:close()

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        -- Keep the corrupt file around instead of silently overwriting it on
        -- the next save, so the data can be recovered by hand if needed.
        os.remove(save_path .. '.bad')
        os.rename(save_path, save_path .. '.bad')
        log('Failed to parse save file; starting fresh. (old file kept as char_data.json.bad)')
        data = {}
        data._settings = settings
        return
    end
    data = decoded

    -- Restore hidden quests from saved data
    if type(data._hidden) == 'table' then
        hidden_quests = data._hidden
    else
        hidden_quests = {}
        data._hidden = hidden_quests
    end

    -- Restore settings (merge over defaults so new settings get defaults).
    if type(data._settings) == 'table' then
        for k, _ in pairs(DEFAULT_SETTINGS) do
            if data._settings[k] ~= nil then
                settings[k] = data._settings[k]
            end
        end
    end
    data._settings = settings
end

local function normalize_string(s)
    if not s or s == '' then return nil end

    -- Strip FFXI color/control codes:
    -- 0x1E, 0x1F, 0x7F, NULL, and all ASCII control chars
    s = s:gsub('[%z\1-\31\127]', '')

    -- Trim whitespace
    s = s:gsub('^%s+', ''):gsub('%s+$', '')

    -- Normalize case
    s = s:lower()

    return (s ~= '' and s or nil)
end

-- Check a flag_phrase value against a normalized message.
-- flag_phrase can be a single string or a table of strings.
-- Returns the matched phrase (original, unnormalized) or nil.
local function match_flag_phrase(flag_phrase, normalized_msg)
    if not flag_phrase then return nil end

    local phrases
    if type(flag_phrase) == 'string' then
        if flag_phrase == '' then return nil end
        phrases = { flag_phrase }
    elseif type(flag_phrase) == 'table' then
        phrases = flag_phrase
    else
        return nil
    end

    for _, fp in ipairs(phrases) do
        if fp and fp ~= '' then
            local norm = normalize_string(fp)
            if norm and string.find(normalized_msg, norm, 1, true) then
                return fp
            end
        end
    end
    return nil
end

-- ============================================================================
-- Character Data Helpers
-- ============================================================================
-- Forward declaration (defined in the Eco Warrior Status Derivation section);
-- needed by ensure_char's weekly rollover to refresh stale eco statuses.
local derive_eco_statuses

-- Ensures the character entry exists and is for the current week.
-- On week rollover, only COMPLETED quests are reset (flagged/in-progress
-- quests persist in-game and don't need to be re-accepted).
local function ensure_char(name)
    if not name or name == '' then return nil end
    local week = get_week_key()

    if not data[name] then
        dlog(string.format('ensure_char: creating new entry for "%s" week=%s', name, week))
        data[name] = { week = week, quests = {}, enms = {} }
    end

    -- Ensure enms table exists (for saves from before ENM support)
    if not data[name].enms then
        data[name].enms = {}
    end

    -- Week rollover - only reset COMPLETED quests (flagged/in-progress quests
    -- persist across the weekly boundary in-game and don't need to be re-flagged)
    local week_rolled_over = false
    if data[name].week ~= week then
        week_rolled_over = true
        log(string.format('New week detected for %s - resetting completed quests. (old=%s, new=%s)',
            name, data[name].week, week))
        data[name].week = week
        for _, q in ipairs(QUESTS) do
            if q.type ~= 'enm' then
                local cur = data[name].quests[q.name]
                if cur == 'COMPLETED' then
                    if q.type == 'kill_mob' then
                        data[name].quests[q.name] = 'NEED TO COMPLETE'
                    else
                        data[name].quests[q.name] = 'NOT STARTED'
                    end
                    log(string.format('  Reset %s: COMPLETED -> %s', q.name, data[name].quests[q.name]))
                end
            end
        end
        -- Reset dynamis entries for the new week
        if data[name].dynamis and #data[name].dynamis > 0 then
            log(string.format('  Reset Dynamis entries: %d -> 0', #data[name].dynamis))
            data[name].dynamis = {}
        end
    end

    -- Ensure every non-ENM quest from QUESTS list has an entry
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' then
            if not data[name].quests[q.name] then
                -- Kill quests are always available, so default to NEED TO COMPLETE
                if q.type == 'kill_mob' then
                    data[name].quests[q.name] = 'NEED TO COMPLETE'
                else
                    data[name].quests[q.name] = 'NOT STARTED'
                end
            end
        end
    end

    -- Ensure every ENM has an entry in enms table
    for _, q in ipairs(QUESTS) do
        if q.type == 'enm' then
            if not data[name].enms[q.name] then
                data[name].enms[q.name] = {}   -- ki_obtained_time = nil initially
            end
        end
    end

    -- Ensure eco warrior data exists (never auto-reset - tracks round-robin cycle)
    if not data[name].eco then
        data[name].eco = {}
    end
    for _, ew in ipairs(ECO_WARRIORS) do
        if not data[name].eco[ew.key] then
            data[name].eco[ew.key] = {}  -- completed_week = nil initially
        end
    end

    -- Ensure eco_cycle tracking exists (tracks which nations have been completed in
    -- the current round-robin cycle; resets when all nations are done)
    if not data[name].eco_cycle then
        data[name].eco_cycle = {}
        -- Migration: infer cycle state from existing completed_week data.
        -- If all nations have a completed_week, the last full cycle is done -> empty cycle.
        -- If only some have completed_week, those nations are "done" in the current cycle.
        local all_have_week = true
        for _, ew in ipairs(ECO_WARRIORS) do
            if not (data[name].eco[ew.key] and data[name].eco[ew.key].completed_week) then
                all_have_week = false
                break
            end
        end
        if not all_have_week then
            for _, ew in ipairs(ECO_WARRIORS) do
                if data[name].eco[ew.key] and data[name].eco[ew.key].completed_week then
                    data[name].eco_cycle[ew.key] = true
                end
            end
        end
        -- If all_have_week, eco_cycle stays empty (full cycle complete, all available)
    end

    -- On week rollover, refresh week-scoped eco warrior statuses. Without
    -- this, a character that hasn't logged in since the reset keeps
    -- displaying last week's 'Completed'/'Not Available' (the UI prefers
    -- stored_status for non-current characters). Other statuses (Flagged
    -- etc.) legitimately persist across the weekly boundary and are left
    -- alone. Runs after the eco/eco_cycle blocks above so the derivation
    -- sees fully migrated data.
    if week_rolled_over then
        local eco_statuses = derive_eco_statuses(data[name], false)
        for _, ew in ipairs(ECO_WARRIORS) do
            local eco = data[name].eco[ew.key]
            if eco and (eco.stored_status == 'Completed' or eco.stored_status == 'Not Available') then
                local r = eco_statuses[ew.key]
                if r and eco.stored_status ~= r.status then
                    log(string.format('  Reset Eco %s: %s -> %s', ew.nation, eco.stored_status, r.status))
                    eco.stored_status = r.status
                end
            end
        end
    end

    -- Ensure dynamis tracking table exists
    if not data[name].dynamis then
        data[name].dynamis = {}
    end

    return data[name]
end

local function get_current_char_name()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return nil end
    local name = party:GetMemberName(0)
    if not name or name == '' then return nil end
    return name
end

-- Current zone id for the player (party member 0), or nil if unavailable.
local function get_current_zone_id()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return nil end
    local zone = party:GetMemberZone(0)
    if not zone or zone == 0 then return nil end
    return zone
end

-- Cache of last derived status per quest name, to avoid spamming debug logs every frame.
-- Declared here (before clear_packet_state) so it can be cleared on character change.
local last_derived_status = {}

-- Clear all packet-derived state (KI bitmaps, quest blocks, derived status cache,
-- active Dynamis session). Must be called whenever the logged-in character changes
-- so that stale data from the previous character is not mistakenly compared against
-- the new character's incoming packets (which would cause false KI "removal" detections).
local function clear_packet_state()
    ki_bitmap = {}
    prev_ki_bitmap = {}
    active_quest_blocks = {}
    last_derived_status = {}
    dynamis_active_session = nil
    dlog('Cleared packet-derived state (character change).')
end

-- Checks if the character has changed since the last packet processing and, if so,
-- clears stale packet state. Call this at the top of packet handlers.
-- Returns true if a character change was detected (callers may want to skip
-- processing the current packet to avoid acting on stale data).
-- KNOWN LIMITATION: this relies on party memory updating before the new
-- character's packets arrive. If an early packet is processed while memory
-- still returns the previous character's name, the change is undetectable
-- here and that packet's effects may be attributed to the previous character.
local function check_packet_char_change()
    local name = get_current_char_name()
    if not name then return false end
    if last_packet_char and last_packet_char ~= name then
        dlog(string.format('Character change detected (%s -> %s) - clearing packet state.',
            last_packet_char, name))
        clear_packet_state()
        last_packet_char = name
        return true
    end
    last_packet_char = name
    return false
end

-- Persist the in-memory Dynamis session to the current character's record so
-- it survives a crash/relog inside Dynamis. Without this, re-entering after a
-- client restart would be counted as a second weekly entrance (the 0x00A
-- handler restores the session from cd.dynamis_session before counting).
local function persist_dynamis_session()
    local name = get_current_char_name()
    if not name then return end
    local cd = ensure_char(name)
    if not cd then return end
    if dynamis_active_session then
        cd.dynamis_session = {
            zone_id     = dynamis_active_session.zone_id,
            zone_name   = dynamis_active_session.zone_name,
            expiry_time = dynamis_active_session.expiry_time,
        }
    else
        cd.dynamis_session = nil
    end
    save_data()
end

-- ============================================================================
-- State Management
-- ============================================================================
-- Advance state forward (never go backwards).
-- Order: NOT STARTED -> NEED TO COMPLETE -> READY TO TURN IN -> COMPLETED
local function try_advance(char_name, quest_name, new_status)
    local cd = ensure_char(char_name)
    if not cd then
        dlog(string.format('try_advance: ensure_char failed for "%s"', tostring(char_name)))
        return
    end

    local cur = cd.quests[quest_name] or 'NOT STARTED'

    local order = {
        ['NOT STARTED']      = 1,
        ['NEED TO COMPLETE'] = 2,
        ['READY TO TURN IN'] = 3,
        ['COMPLETED']        = 4,
    }

    local cur_order = order[cur] or 0
    local new_order = order[new_status] or 0

    if new_order > cur_order then
        cd.quests[quest_name] = new_status
        log(string.format('%s - %s -> %s', quest_name, cur, new_status))
        save_data()
    else
        dlog(string.format('try_advance BLOCKED: %s - %s (ord %d) -> %s (ord %d)',
            quest_name, cur, cur_order, new_status, new_order))
    end
end

-- Called when a tracked kill mob's death line is seen in chat. Message order
-- is not guaranteed under load: if the player's XP gain already arrived
-- within the confirm window, complete immediately; otherwise queue the kill
-- and wait for the XP message. Skips quests already completed (e.g. by the
-- exact-XP zone confirmation).
local function queue_or_confirm_kill(qi, q)
    local kname = get_current_char_name()
    local already_completed = kname and data[kname] and data[kname].quests
        and data[kname].quests[q.name] == 'COMPLETED'
    if already_completed then return end

    local now = os.clock()

    -- Already queued (multiple chat lines can match the same death)?
    -- Don't re-log or reset the timer.
    if pending_kills[qi] and (now - pending_kills[qi]) <= KILL_CONFIRM_WINDOW then
        return
    end

    if kname and last_xp_gain_time and (now - last_xp_gain_time) <= KILL_CONFIRM_WINDOW then
        log(string.format('Kill confirmed: %s (XP received %.1fs earlier)',
            q.name, now - last_xp_gain_time))
        try_advance(kname, q.name, 'COMPLETED')
    else
        pending_kills[qi] = now
        log(string.format('Mob defeated: %s - waiting for XP confirm...', q.kill_mob))
    end
end

-- ============================================================================
-- Packet-Based Status Derivation (non-ENM, non-kill_mob quests)
-- ============================================================================
-- Derives the current status from 0x055 (KI) and 0x056 (quest) packet data,
-- combined with stored status (which may have been set by chat detection,
-- KI removal events, or flag_phrase/complete_phrase).
-- Only runs for the currently logged-in character.
--
-- Status strings:
--   'NOT STARTED'      - no active indicators, no stored progress
--   'NEED TO COMPLETE' - quest active (0x056), has ki_quest_active, or stored
--                         (e.g. from flag_phrase)
--   'READY TO TURN IN' - has ki_quest_incomplete, or stored (e.g. from
--                         ki_quest_active removal)
--   'COMPLETED'        - stored as completed (from KI removal, complete_phrase,
--                         or ki_active_is_completion)
--

local function derive_quest_status(q, stored_status)
    local result

    -- If stored status is already COMPLETED this week, keep it
    if stored_status == 'COMPLETED' then
        result = 'COMPLETED'
    else
        -- Quest active check (packet 0x056)
        local quest_active = false
        if q.quest_log_id and q.quest_id then
            quest_active = is_quest_active(q.quest_log_id, q.quest_id)
        end

        -- KI checks (packet 0x055)
        local has_ki_active = false
        if q.ki_quest_active and q.ki_quest_active ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_active)
            if ki_id then
                has_ki_active = has_key_item(ki_id)
            end
        end

        local has_ki_incomplete = false
        if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_incomplete)
            if ki_id then
                has_ki_incomplete = has_key_item(ki_id)
            end
        end

        -- ki_quest_incomplete: having it means you need to turn in
        if has_ki_incomplete then
            result = 'READY TO TURN IN'
        -- ki_quest_active: having it means quest accepted, need to go complete it
        elseif has_ki_active then
            result = 'NEED TO COMPLETE'
        -- Quest is active but no specific KI -> need to complete
        -- UNLESS: quest has ki_quest_active configured and the KI is absent,
        -- meaning the objective was completed (KI consumed). In that case,
        -- respect the stored status (likely READY TO TURN IN from KI removal).
        elseif quest_active then
            local ki_active_consumed = (q.ki_quest_active and q.ki_quest_active ~= '' and not has_ki_active)
            if ki_active_consumed and stored_status == 'READY TO TURN IN' then
                result = 'READY TO TURN IN'
            else
                result = 'NEED TO COMPLETE'
            end
        else
            -- Quest is not active and no KIs present - use stored status
            result = stored_status or 'NOT STARTED'
        end

        -- Debug: only log when the derived result changes from last time
        if debug_mode and last_derived_status[q.name] ~= result then
            local qa_str = 'n/a'
            if q.quest_log_id and q.quest_id then
                qa_str = tostring(quest_active)
            end
            local ki_a_str = 'n/a'
            if q.ki_quest_active and q.ki_quest_active ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                ki_a_str = ki_id and tostring(has_ki_active) or 'UNRESOLVED'
            end
            local ki_i_str = 'n/a'
            if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_incomplete)
                ki_i_str = ki_id and tostring(has_ki_incomplete) or 'UNRESOLVED'
            end
            dlog(string.format('derive [%s]: %s -> %s (quest_active=%s, ki_active=%s, ki_incomplete=%s, stored=%s)',
                q.name, tostring(last_derived_status[q.name]), result,
                qa_str, ki_a_str, ki_i_str, tostring(stored_status)))
        end
    end

    last_derived_status[q.name] = result
    return result
end

-- ============================================================================
-- KI Removal Detection (called after 0x055 packet updates ki_bitmap)
-- ============================================================================
-- Compares prev_ki_bitmap vs ki_bitmap for each quest's KI fields.
-- ki_quest_incomplete: "has" -> "doesn't have" = turned in -> COMPLETED
-- ki_quest_active:     "has" -> "doesn't have" = objective done -> READY TO TURN IN
local function process_ki_removals(table_index)
    local name = get_current_char_name()
    if not name then return end

    -- Standard quests: ki_quest_incomplete removal = COMPLETED (turned in)
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' and q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_incomplete)
            if ki_id then
                local ki_table = math.floor(ki_id / 512)
                if ki_table == table_index then
                    local previously_had = had_key_item(ki_id)
                    local currently_has  = has_key_item(ki_id)

                    if previously_had and not currently_has then
                        log(string.format('KI removed: %s - marking %s as COMPLETED.',
                            q.ki_quest_incomplete, q.name))
                        try_advance(name, q.name, 'COMPLETED')
                    end
                end
            else
                dlog(string.format('process_ki_removals [%s]: %s UNRESOLVED, skipping.',
                    q.name, q.ki_quest_incomplete))
            end
        end
    end

    -- Standard quests: ki_quest_active removal
    -- If ki_active_is_completion = true: KI removal = COMPLETED (no turn-in needed)
    -- Otherwise: KI removal = READY TO TURN IN (objective done, go turn in)
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' and q.ki_quest_active and q.ki_quest_active ~= '' then
            local ki_id = resolve_ki_id(q.ki_quest_active)
            if ki_id then
                local ki_table = math.floor(ki_id / 512)
                if ki_table == table_index then
                    local previously_had = had_key_item(ki_id)
                    local currently_has  = has_key_item(ki_id)

                    if previously_had and not currently_has then
                        if q.ki_active_is_completion then
                            log(string.format('KI removed: %s - marking %s as COMPLETED.',
                                q.ki_quest_active, q.name))
                            try_advance(name, q.name, 'COMPLETED')
                        else
                            log(string.format('KI removed: %s - marking %s as READY TO TURN IN.',
                                q.ki_quest_active, q.name))
                            try_advance(name, q.name, 'READY TO TURN IN')
                        end
                    end
                end
            end
        end
    end

    -- Eco warriors
    local cd = ensure_char(name)
    if cd then
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id then
                    local ki_table = math.floor(ki_id / 512)
                    if ki_table == table_index then
                        local previously_had = had_key_item(ki_id)
                        local currently_has  = has_key_item(ki_id)

                        if previously_had and not currently_has then
                            local week = get_week_key()
                            log(string.format('Eco Warrior KI removed: %s - marking %s as completed for %s.',
                                ew.ki_quest_incomplete, ew.nation, week))
                            cd.eco[ew.key].completed_week = week
                            cd.eco[ew.key].stored_flagged = nil
                            cd.eco[ew.key].stored_verified = nil

                            -- Track round-robin cycle completion
                            if not cd.eco_cycle then cd.eco_cycle = {} end
                            cd.eco_cycle[ew.key] = true
                            -- Check if all nations are done in this cycle
                            local cycle_complete = true
                            for _, check_ew in ipairs(ECO_WARRIORS) do
                                if not cd.eco_cycle[check_ew.key] then
                                    cycle_complete = false
                                    break
                                end
                            end
                            if cycle_complete then
                                log('Eco Warrior: full round-robin cycle complete - all nations will be available next.')
                                cd.eco_cycle = {}
                            end

                            save_data()
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- ImGui Rendering
-- ============================================================================
local STATUS_COLORS = {
    ['NOT STARTED']      = { 0.6, 0.6, 0.6, 1.0 },     -- grey
    ['NEED TO COMPLETE'] = { 1.0, 0.85, 0.0, 1.0 },     -- yellow
    ['READY TO TURN IN'] = { 0.4, 0.8, 1.0, 1.0 },      -- light blue
    ['COMPLETED']        = { 0.0, 1.0, 0.4, 1.0 },       -- green
}

local KI_COLOR_YES = { 0.0, 1.0, 0.4, 1.0 }        -- green
local KI_COLOR_NO  = { 1.0, 0.3, 0.3, 1.0 }        -- red
local KI_COLOR_DIM = { 0.5, 0.5, 0.5, 1.0 }        -- grey


-- Format a unix timestamp as a short date/time string
local function format_time(ts)
    if not ts then return '-' end
    return os.date('%m/%d %H:%M', ts)
end

-- ============================================================================
-- Eco Warrior Status Derivation
-- ============================================================================
-- Determines the display status for each eco warrior nation.
-- Returns a table: { [nation_key] = { status = '...', completed_week = '...' | nil } }
--
-- Logic:
--   1. If this nation has the KI (ki_quest_incomplete) and verified -> 'Need To Complete'
--   2. If this nation has the KI but not verified -> 'Return to NPC'
--   3. If this nation is flagged (quest active, flag_phrase, or stored_flagged,
--      but no KI yet) -> 'Flagged'
--   4. If this nation was completed THIS week -> 'Completed'
--   5. If another nation is flagged or completed this week -> 'Not Available'
--   6. Round-robin check using eco_cycle: a nation is 'Available' only if it has
--      NOT been completed in the current round-robin cycle (eco_cycle[key] is nil).
--      When all nations are completed, eco_cycle is cleared and all become available.
--   7. Otherwise -> 'Available'
--
function derive_eco_statuses(cd, is_current_char)
    local week = get_week_key()
    local results = {}
    local any_flagged_this_week = false
    local any_completed_this_week = false

    -- First pass: detect flagged, has_ki, verified, and completed-this-week
    for _, ew in ipairs(ECO_WARRIORS) do
        local eco_data = cd.eco and cd.eco[ew.key] or {}
        local flagged = false
        local has_ki = false
        local verified = false

        -- Check stored_flagged (set by flag_phrase chat detection, persists across sessions)
        if eco_data.stored_flagged then
            flagged = true
        end

        -- Check stored_verified (set by verify_phrase chat detection, persists across sessions)
        if eco_data.stored_verified then
            verified = true
        end

        -- Live packet check for current char
        if is_current_char then
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id and has_key_item(ki_id) then
                    has_ki = true
                    flagged = true
                end
            end
            if not has_ki and not flagged and ew.quest_log_id and ew.quest_id then
                if is_quest_active(ew.quest_log_id, ew.quest_id) then
                    flagged = true
                end
            end
        end

        local completed_this_week = (eco_data.completed_week == week)

        results[ew.key] = {
            flagged = flagged,
            has_ki = has_ki,
            verified = verified,
            completed_this_week = completed_this_week,
            completed_week = eco_data.completed_week,
        }

        if flagged then any_flagged_this_week = true end
        if completed_this_week then any_completed_this_week = true end
    end

    -- Second pass: determine display status using eco_cycle for round-robin tracking.
    -- eco_cycle contains the keys of nations completed in the current round-robin cycle.
    -- When all nations are done, eco_cycle is cleared (all become available again).
    local eco_cycle = cd.eco_cycle or {}

    for _, ew in ipairs(ECO_WARRIORS) do
        local r = results[ew.key]

        if r.has_ki and r.verified then
            r.status = 'Need To Complete'
        elseif r.has_ki then
            r.status = 'Return to NPC'
        elseif r.flagged then
            r.status = 'Flagged'
        elseif r.completed_this_week then
            r.status = 'Completed'
        elseif any_flagged_this_week or any_completed_this_week then
            -- Another nation is active/completed this week
            r.status = 'Not Available'
        else
            -- Round-robin check: this nation is available only if it has NOT been
            -- completed in the current cycle. When all nations are completed,
            -- eco_cycle is cleared and all become available again.
            if eco_cycle[ew.key] then
                r.status = 'Not Available'
            else
                r.status = 'Available'
            end
        end
    end

    return results
end


-- ============================================================================
-- Background Status Update (runs from packet handlers, independent of UI)
-- ============================================================================
-- Derives statuses from live packet data and persists them for the current
-- character. This ensures log messages fire and JSON is saved immediately
-- when packet data changes, even if the UI is not open.
local function update_current_char_statuses()
    local name = get_current_char_name()
    if not name then return end
    local cd = ensure_char(name)
    if not cd then return end

    -- Derive and persist weekly quest statuses
    for _, q in ipairs(QUESTS) do
        if q.type ~= 'enm' and q.type ~= 'kill_mob' then
            local stored_status = cd.quests[q.name] or 'NOT STARTED'
            local status = derive_quest_status(q, stored_status)
            if status ~= stored_status then
                log(string.format('%s: %s -> %s', q.name, stored_status, status))
                cd.quests[q.name] = status
                save_data()
            end
        end
    end

    -- Derive and persist eco warrior statuses
    local eco_statuses = derive_eco_statuses(cd, true)
    local eco_changed = false
    for _, ew in ipairs(ECO_WARRIORS) do
        local r = eco_statuses[ew.key]
        if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
        if cd.eco[ew.key].stored_status ~= r.status then
            log(string.format('Eco %s: %s -> %s',
                ew.nation,
                cd.eco[ew.key].stored_status or 'nil',
                r.status))
            cd.eco[ew.key].stored_status = r.status
            eco_changed = true
        end
    end
    if eco_changed then save_data() end
end

local ECO_STATUS_COLORS = {
    ['Available']        = { 0.0, 1.0, 0.4, 1.0 },    -- green
    ['Flagged']          = { 1.0, 0.85, 0.0, 1.0 },    -- yellow
    ['Return to NPC']    = { 1.0, 0.5, 0.0, 1.0 },     -- orange-red (in-zone verify needed)
    ['Need To Complete'] = { 1.0, 0.6, 0.0, 1.0 },     -- orange
    ['Completed']        = { 0.4, 0.8, 1.0, 1.0 },     -- light blue
    ['Not Available']    = { 0.6, 0.6, 0.6, 1.0 },     -- grey
}

-- ENM cooldown status helper
-- Returns: status_text, color, ready_time_text
local function get_enm_status(enm_data, q)
    local cooldown_secs = (q.enm_cooldown_days or 5) * 86400
    local obtained = enm_data and enm_data.ki_obtained_time or nil

    if not obtained then
        return 'READY', KI_COLOR_YES, '-'
    end

    local ready_at = obtained + cooldown_secs
    local now = os.time()
    local ready_str = format_time(ready_at)

    if now >= ready_at then
        return 'READY', KI_COLOR_YES, ready_str
    else
        local remaining = ready_at - now
        local days = math.floor(remaining / 86400)
        local hours = math.floor((remaining % 86400) / 3600)
        local mins = math.floor((remaining % 3600) / 60)
        local countdown = string.format('%dd %dh %dm', days, hours, mins)
        return countdown, STATUS_COLORS['NEED TO COMPLETE'], ready_str
    end
end

-- ============================================================================
-- EXP Band Inventory Scan
-- ============================================================================
-- Scans Inventory / Wardrobe / Wardrobe2 for any of the EXP band item IDs.
-- For the first one found with at least 1 charge remaining, reads the
-- next-use timestamp from item.Extra (bytes 5..8 = LE uint32 vana-relative)
-- and stores it on the character record.
-- If allow_clear is true and none are found, the stored band is cleared.
-- Clearing scans run only from the retry-gated deferred scan in d3d_present
-- (final attempt) and directly from the config-tab toggle.
-- If allow_clear is false (set-only mode), a missing band is ignored: this
-- is used for the one-time login scan and the deferred scan's retry
-- attempts, because bags may not be populated in memory yet and a
-- partial-load scan would falsely "lose" a band that's actually still in an
-- unloaded bag.
-- Returns 'found' when a band was stored/updated, 'cleared' when the stored
-- band was removed, 'none'/nil otherwise.
local function scan_exp_band_for_char(char_name, allow_clear)
    if allow_clear == nil then allow_clear = true end
    if not char_name then return end
    if not settings.exp_band_tracking_enabled then return end

    local cd = ensure_char(char_name)
    if not cd then return end

    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if not inventory then return end

    local found
    for bag_id, bag_name in pairs(EXP_BAND_BAG_NAMES) do
        local max_slots = EXP_BAND_CONTAINER_MAXES[bag_name] or 0
        for slot = 1, max_slots do
            local item = inventory:GetContainerItem(bag_id, slot)
            if item and item.Id and EXP_BANDS[item.Id] and item.Extra and #item.Extra >= 8 then
                local charges = string.byte(item.Extra, 2) or 0
                if charges >= 1 then
                    local extra_ts  = u32le(item.Extra, 5)
                    local expiry    = extra_ts + VANA_OFFSET
                    found = {
                        item_id     = item.Id,
                        name        = EXP_BANDS[item.Id],
                        expiry_time = expiry,
                        charges     = charges,
                    }
                    break
                end
            end
        end
        if found then break end
    end

    local prev = cd.exp_band
    if found then
        -- Preserve notified_ready state if same band & same expiry, else reset.
        local same_as_prev = prev
            and prev.item_id     == found.item_id
            and prev.expiry_time == found.expiry_time
            and prev.charges     == found.charges
        if prev and prev.item_id == found.item_id and prev.expiry_time == found.expiry_time then
            found.notified_ready = prev.notified_ready
        end
        cd.exp_band = found
        if not same_as_prev then
            local now = os.time()
            if found.expiry_time <= now then
                -- This log line already announces READY - mark it notified so
                -- the alert checker doesn't announce it a second time.
                found.notified_ready = true
                log(string.format('EXP Band found: %s (%d charge%s) - READY now.',
                    found.name, found.charges, found.charges == 1 and '' or 's'))
            else
                log(string.format('EXP Band found: %s (%d charge%s) - ready in %s.',
                    found.name, found.charges, found.charges == 1 and '' or 's',
                    format_countdown(found.expiry_time - now)))
            end
            save_data()
        end
        return 'found'
    end

    if prev and allow_clear then
        log('EXP Band no longer in inventory (or out of charges) - clearing.')
        cd.exp_band = nil
        save_data()
        return 'cleared'
    end
    return 'none'
end


-- ============================================================================
-- EXP Band Alert Check
-- ============================================================================
-- Fires a chat notification when the stored band's cooldown expires.
local function check_exp_band_alerts(char_name, is_login_check)
    if not char_name then return end
    if not settings.exp_band_tracking_enabled then return end
    local cd = data[char_name]
    if not cd or not cd.exp_band then return end

    local band = cd.exp_band
    if not band.expiry_time then return end

    if os.time() >= band.expiry_time then
        if not band.notified_ready then
            band.notified_ready = true
            save_data()
            if is_login_check then
                log(string.format('\30\08EXP Band READY:\30\01 %s can be used now.', band.name))
            else
                log(string.format('\30\08%s\30\01 is now READY to use!', band.name))
            end
        end
    end
end

-- ============================================================================
-- ENM / Limbus Alert Check
-- ============================================================================
-- Checks all ENM quests for the given character. If a cooldown has expired
-- and the player hasn't been notified yet, sends a chat notification and
-- sets the notified_ready flag. Called on login and periodically.
-- is_login_check: if true, groups all ready ENMs into a single summary message.
local function check_enm_alerts(char_name, is_login_check)
    if not char_name then return end
    local cd = data[char_name]
    if not cd or not cd.enms then return end

    local ready_names = {}

    for _, q in ipairs(QUESTS) do
        if q.type == 'enm' then
            local enm_data = cd.enms[q.name]
            if enm_data then
                local cooldown_secs = (q.enm_cooldown_days or 5) * 86400
                local obtained = enm_data.ki_obtained_time

                -- Determine if the ENM is ready
                local is_ready = false
                if not obtained then
                    is_ready = true   -- never obtained = always ready
                elseif os.time() >= (obtained + cooldown_secs) then
                    is_ready = true   -- cooldown expired
                end

                if is_ready and not enm_data.notified_ready then
                    enm_data.notified_ready = true
                    ready_names[#ready_names + 1] = q.name
                    dlog(string.format('ENM alert: %s is READY for %s', q.name, char_name))
                end
            end
        end
    end

    if #ready_names > 0 then
        save_data()
        if is_login_check then
            -- Single summary message on login
            log(string.format('\30\08%d cooldown reward(s) READY:\30\01 %s',
                #ready_names, table.concat(ready_names, ', ')))
        else
            -- Individual alert per newly-ready reward during play
            for _, rn in ipairs(ready_names) do
                log(string.format('\30\08%s\30\01 is now READY!', rn))
            end
        end
    end
end

local function render_ui()
    if not show_window[1] then return end

    imgui.SetNextWindowSize({ 720, 480 }, ImGuiCond_FirstUseEver)

    if imgui.Begin('Weeklier - Weekly Quest Tracker', show_window, ImGuiWindowFlags_None) then

        -- Current week label + countdown to next reset
        local next_reset = get_next_reset_time()
        local remaining = next_reset - now_utc()
        imgui.Text('Week: ' .. get_week_key())
        imgui.SameLine()
        imgui.Text('   ')
        imgui.SameLine()
        if remaining <= 3600 then
            imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        elseif remaining <= 86400 then
            imgui.TextColored({ 1.0, 0.85, 0.0, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        else
            imgui.TextColored({ 0.6, 0.8, 1.0, 1.0 }, 'Reset in: ' .. format_countdown(remaining))
        end
        imgui.Separator()

        -- Collect character names sorted alphabetically, current char first
        -- Filter out the _hidden / _settings keys which are not characters
        local char_names = {}
        for name, _ in pairs(data) do
            if name ~= '_hidden' and name ~= '_settings' then
                char_names[#char_names + 1] = name
            end
        end
        table.sort(char_names, function(a, b)
            if a == current_char then return true end
            if b == current_char then return false end
            return a < b
        end)

        -- Build visible quest lists (excluding hidden)
        local weekly_quests = {}
        local enm_quests = {}
        for _, q in ipairs(QUESTS) do
            if not is_quest_hidden(q.name) then
                if q.type == 'enm' then
                    enm_quests[#enm_quests + 1] = q
                else
                    weekly_quests[#weekly_quests + 1] = q
                end
            end
        end

        if #char_names == 0 then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'No character data yet. Log in and play!')
        elseif imgui.BeginTabBar('##mainTabs') then

            -- ==========================================================
            -- Character tabs
            -- ==========================================================
            for _, char_name in ipairs(char_names) do
                -- ensure_char (not a raw data read) so weekly rollover resets
                -- apply to characters that haven't logged in since the reset.
                local cd = ensure_char(char_name)
                local tab_flags = 0
                if select_current_tab and char_name == current_char then
                    tab_flags = ImGuiTabItemFlags_SetSelected
                    select_current_tab = false
                end
                if cd and imgui.BeginTabItem(char_name, nil, tab_flags) then
                    local is_current_tab = (char_name == current_char)

                    -- ==================================================
                    -- WEEKLY QUESTS SECTION (collapsible)
                    -- ==================================================
                    if #weekly_quests > 0 then
                        if imgui.CollapsingHeader('Weekly Quests', ImGuiTreeNodeFlags_DefaultOpen) then

                            imgui.Columns(3, '##questCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 220)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Quest')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, q in ipairs(weekly_quests) do
                                local stored_status = cd.quests[q.name] or 'NOT STARTED'
                                local status

                                -- For the current character, derive status from live packet data.
                                -- Logging and persistence is handled by update_current_char_statuses()
                                -- which runs from packet handlers.
                                if is_current_tab and q.type ~= 'kill_mob' then
                                    status = derive_quest_status(q, stored_status)
                                    -- Persist silently (no log) in case UI opens before a packet triggers the update
                                    if status ~= stored_status then
                                        cd.quests[q.name] = status
                                        save_data()
                                    end
                                else
                                    status = stored_status
                                end

                                local color = STATUS_COLORS[status] or STATUS_COLORS['NOT STARTED']

                                -- Hide button
                                imgui.PushID('hide_wq_' .. q.name)
                                if imgui.SmallButton('x') then
                                    set_quest_hidden(q.name, true)
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.NextColumn()

                                imgui.Text(q.name)
                                imgui.NextColumn()
                                imgui.TextColored(color, status)
                                imgui.NextColumn()
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- ECO WARRIORS SECTION (collapsible)
                    -- ==================================================
                    if not is_quest_hidden('Eco Warriors') then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Eco Warriors', ImGuiTreeNodeFlags_DefaultOpen) then
                            local eco_statuses = derive_eco_statuses(cd, is_current_tab)

                            -- Persist eco status for current char (no log - handled by
                            -- update_current_char_statuses() from packet handlers)
                            if is_current_tab then
                                local eco_changed = false
                                for _, ew in ipairs(ECO_WARRIORS) do
                                    local r = eco_statuses[ew.key]
                                    if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
                                    if cd.eco[ew.key].stored_status ~= r.status then
                                        cd.eco[ew.key].stored_status = r.status
                                        eco_changed = true
                                    end
                                end
                                if eco_changed then save_data() end
                            else
                                -- For non-current chars, use stored status if live data unavailable
                                for _, ew in ipairs(ECO_WARRIORS) do
                                    local r = eco_statuses[ew.key]
                                    local stored = cd.eco and cd.eco[ew.key] and cd.eco[ew.key].stored_status
                                    if stored and r.status ~= 'Completed' and not r.flagged then
                                        r.status = stored
                                    end
                                end
                            end

                            imgui.Columns(4, '##ecoCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 140)
                            imgui.SetColumnWidth(2, 120)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Nation')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Text('Last Completed')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, ew in ipairs(ECO_WARRIORS) do
                                if not is_quest_hidden('Eco_' .. ew.key) then
                                    local r = eco_statuses[ew.key]
                                    local color = ECO_STATUS_COLORS[r.status] or KI_COLOR_DIM

                                    -- Hide button
                                    imgui.PushID('hide_eco_' .. ew.key)
                                    if imgui.SmallButton('x') then
                                        set_quest_hidden('Eco_' .. ew.key, true)
                                        save_data()
                                    end
                                    imgui.PopID()
                                    imgui.NextColumn()

                                    imgui.Text(ew.nation)
                                    imgui.NextColumn()

                                    imgui.TextColored(color, r.status)
                                    imgui.NextColumn()

                                    -- Last completed week
                                    local cw = r.completed_week
                                    if cw then
                                        imgui.Text(cw)
                                    else
                                        imgui.TextColored(KI_COLOR_DIM, 'Never')
                                    end
                                    imgui.NextColumn()
                                end
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- ENM / LIMBUS SECTION (collapsible)
                    -- ==================================================
                    if #enm_quests > 0 then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Cooldowns (ENM / Limbus / HAAP)', ImGuiTreeNodeFlags_DefaultOpen) then

                            imgui.Columns(6, '##enmCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 180)
                            imgui.SetColumnWidth(2, 70)
                            imgui.SetColumnWidth(3, 100)
                            imgui.SetColumnWidth(4, 100)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Name')
                            imgui.NextColumn()
                            imgui.Text('Has KI')
                            imgui.NextColumn()
                            imgui.Text('Obtained')
                            imgui.NextColumn()
                            imgui.Text('Ready At')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Separator()

                            for _, q in ipairs(enm_quests) do
                                local enm_data = cd.enms and cd.enms[q.name] or {}

                                -- Hide button
                                imgui.PushID('hide_enm_' .. q.name)
                                if imgui.SmallButton('x') then
                                    set_quest_hidden(q.name, true)
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.NextColumn()

                                -- ENM Name
                                imgui.Text(q.name)
                                imgui.NextColumn()

                                -- Has KI (live packet data for current char, stored for others)
                                if is_current_tab then
                                    if q.ki_quest_active and q.ki_quest_active ~= '' then
                                        local ki_id = resolve_ki_id(q.ki_quest_active)
                                        if ki_id then
                                            if has_key_item(ki_id) then
                                                imgui.TextColored(KI_COLOR_YES, 'Yes')
                                            else
                                                imgui.TextColored(KI_COLOR_NO, 'No')
                                            end
                                        else
                                            imgui.TextColored(KI_COLOR_DIM, '??')
                                        end
                                    else
                                        imgui.Text('-')
                                    end
                                else
                                    -- Use stored has_ki from JSON ('-' for
                                    -- item-based rewards with no KI to track)
                                    local stored_ki = enm_data.has_ki
                                    if not (q.ki_quest_active and q.ki_quest_active ~= '') then
                                        imgui.Text('-')
                                    elseif stored_ki == true then
                                        imgui.TextColored(KI_COLOR_YES, 'Yes')
                                    elseif stored_ki == false then
                                        imgui.TextColored(KI_COLOR_NO, 'No')
                                    else
                                        imgui.TextColored(KI_COLOR_DIM, '??')
                                    end
                                end
                                imgui.NextColumn()

                                -- Obtained timestamp
                                local obtained_ts = enm_data.ki_obtained_time
                                imgui.Text(format_time(obtained_ts))
                                imgui.NextColumn()

                                -- Ready At / Status
                                local status_text, status_color, ready_str = get_enm_status(enm_data, q)
                                imgui.Text(ready_str)
                                imgui.NextColumn()
                                imgui.TextColored(status_color, status_text)
                                imgui.NextColumn()
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- EXP BAND SECTION (collapsible)
                    -- ==================================================
                    if settings.exp_band_tracking_enabled and not is_quest_hidden('EXP Band') then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('EXP Band', ImGuiTreeNodeFlags_DefaultOpen) then
                            local band = cd.exp_band

                            imgui.Columns(4, '##expBandCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 140)
                            imgui.SetColumnWidth(2, 80)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Band')
                            imgui.NextColumn()
                            imgui.Text('Charges')
                            imgui.NextColumn()
                            imgui.Text('Status')
                            imgui.NextColumn()
                            imgui.Separator()

                            -- Hide button
                            imgui.PushID('hide_expband')
                            if imgui.SmallButton('x') then
                                set_quest_hidden('EXP Band', true)
                                save_data()
                            end
                            imgui.PopID()
                            imgui.NextColumn()

                            if band then
                                imgui.Text(band.name or '?')
                                imgui.NextColumn()
                                imgui.Text(tostring(band.charges or 0))
                                imgui.NextColumn()
                                local now_ts = os.time()
                                if not band.expiry_time or band.expiry_time <= now_ts then
                                    imgui.TextColored(KI_COLOR_YES, 'READY')
                                else
                                    imgui.TextColored(STATUS_COLORS['NEED TO COMPLETE'],
                                        format_countdown(band.expiry_time - now_ts))
                                end
                                imgui.NextColumn()
                            else
                                imgui.TextColored(KI_COLOR_DIM, 'None')
                                imgui.NextColumn()
                                imgui.TextColored(KI_COLOR_DIM, '-')
                                imgui.NextColumn()
                                imgui.TextColored(KI_COLOR_DIM, '-')
                                imgui.NextColumn()
                            end

                            imgui.Columns(1)
                        end
                    end

                    -- ==================================================
                    -- DYNAMIS SECTION (collapsible)
                    -- ==================================================
                    if not is_quest_hidden('Dynamis') then
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Dynamis (2 per week)', ImGuiTreeNodeFlags_DefaultOpen) then
                            local dyn = cd.dynamis or {}
                            local used = #dyn

                            imgui.Columns(4, '##dynCols', true)
                            imgui.SetColumnWidth(0, 30)
                            imgui.SetColumnWidth(1, 100)
                            imgui.SetColumnWidth(2, 200)
                            imgui.Text('')
                            imgui.NextColumn()
                            imgui.Text('Entrance')
                            imgui.NextColumn()
                            imgui.Text('Zone')
                            imgui.NextColumn()
                            imgui.Text('Date')
                            imgui.NextColumn()
                            imgui.Separator()

                            for i = 1, DYNAMIS_MAX_ENTRIES do
                                local entry = dyn[i]

                                -- Hide button (only on first row)
                                if i == 1 then
                                    imgui.PushID('hide_dynamis')
                                    if imgui.SmallButton('x') then
                                        set_quest_hidden('Dynamis', true)
                                        save_data()
                                    end
                                    imgui.PopID()
                                else
                                    imgui.Text('')
                                end
                                imgui.NextColumn()

                                imgui.Text(string.format('Entrance %d', i))
                                imgui.NextColumn()

                                if entry then
                                    imgui.Text(entry.zone or '??')
                                    imgui.NextColumn()
                                    imgui.Text(format_time(entry.time))
                                else
                                    imgui.TextColored(KI_COLOR_DIM, '-')
                                    imgui.NextColumn()
                                    imgui.TextColored(KI_COLOR_DIM, '-')
                                end
                                imgui.NextColumn()
                            end

                            -- Show remaining count
                            local dyn_remaining = DYNAMIS_MAX_ENTRIES - used
                            imgui.Columns(1)
                            if dyn_remaining > 0 then
                                imgui.TextColored(KI_COLOR_YES, string.format('%d entrance(s) remaining', dyn_remaining))
                            else
                                imgui.TextColored(STATUS_COLORS['COMPLETED'], 'All entrances used this week')
                            end
                        end
                    end

                    imgui.EndTabItem()
                end
            end

            -- ==========================================================
            -- Config tab
            -- ==========================================================
            if imgui.BeginTabItem('Config') then

                -- ----------------------------------------------------------
                -- Feature toggles
                -- ----------------------------------------------------------
                imgui.TextColored({ 1.0, 1.0, 0.6, 1.0 }, 'Features')
                imgui.Separator()

                local exp_band_toggle = { settings.exp_band_tracking_enabled and true or false }
                if imgui.Checkbox('Track EXP Bands (Chariot/Empress/Emperor)', exp_band_toggle) then
                    settings.exp_band_tracking_enabled = exp_band_toggle[1]
                    log(string.format('EXP Band tracking: %s',
                        settings.exp_band_tracking_enabled and 'ENABLED' or 'DISABLED'))
                    save_data()
                    -- Re-scan immediately if just enabled
                    if settings.exp_band_tracking_enabled then
                        local cur = get_current_char_name()
                        if cur then scan_exp_band_for_char(cur) end
                    end
                end
                imgui.Spacing()

                -- ----------------------------------------------------------
                -- Hidden Quests
                -- ----------------------------------------------------------
                imgui.TextColored({ 1.0, 1.0, 0.6, 1.0 }, 'Hidden Quests')
                imgui.Separator()
                imgui.TextWrapped('Quests hidden from the tracker. Click Show to restore them.')
                imgui.Spacing()

                local any_hidden = false

                -- Eco Warriors section header
                if is_quest_hidden('Eco Warriors') then
                    any_hidden = true
                    imgui.PushID('show_eco_section')
                    if imgui.SmallButton('Show') then
                        set_quest_hidden('Eco Warriors', false)
                        save_data()
                    end
                    imgui.PopID()
                    imgui.SameLine()
                    imgui.Text('[Eco] Eco Warriors (entire section)')
                end

                -- Individual eco nations
                for _, ew in ipairs(ECO_WARRIORS) do
                    local hide_key = 'Eco_' .. ew.key
                    if is_quest_hidden(hide_key) then
                        any_hidden = true
                        imgui.PushID('show_' .. hide_key)
                        if imgui.SmallButton('Show') then
                            set_quest_hidden(hide_key, false)
                            save_data()
                        end
                        imgui.PopID()
                        imgui.SameLine()
                        imgui.Text(string.format('[Eco] %s', ew.nation))
                    end
                end

                -- Regular quests
                for _, q in ipairs(QUESTS) do
                    if is_quest_hidden(q.name) then
                        any_hidden = true
                        local type_label = q.type == 'enm' and 'ENM/Limbus' or (q.type == 'kill_mob' and 'Kill' or 'Quest')
                        imgui.PushID('show_' .. q.name)
                        if imgui.SmallButton('Show') then
                            set_quest_hidden(q.name, false)
                            save_data()
                        end
                        imgui.PopID()
                        imgui.SameLine()
                        imgui.Text(string.format('[%s] %s', type_label, q.name))
                    end
                end

                -- Dynamis section
                if is_quest_hidden('Dynamis') then
                    any_hidden = true
                    imgui.PushID('show_dynamis_section')
                    if imgui.SmallButton('Show') then
                        set_quest_hidden('Dynamis', false)
                        save_data()
                    end
                    imgui.PopID()
                    imgui.SameLine()
                    imgui.Text('[Dynamis] Dynamis (entire section)')
                end

                -- EXP Band section
                if is_quest_hidden('EXP Band') then
                    any_hidden = true
                    imgui.PushID('show_expband_section')
                    if imgui.SmallButton('Show') then
                        set_quest_hidden('EXP Band', false)
                        save_data()
                    end
                    imgui.PopID()
                    imgui.SameLine()
                    imgui.Text('[EXP Band] EXP Band (entire section)')
                end

                if not any_hidden then
                    imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, 'No hidden quests.')
                end


                -- ----------------------------------------------------------
                -- Manual Status Override (All Quests & Dynamis)
                -- ----------------------------------------------------------
                imgui.Spacing()
                imgui.Spacing()
                imgui.TextColored({ 1.0, 0.6, 0.4, 1.0 }, 'Manual Status Override')
                imgui.Separator()
                imgui.TextWrapped('Manually set the status for any quest, ENM / Limbus, or Dynamis entry. Select a character, then change values. For the current character, live packet data may re-derive some statuses automatically.')
                imgui.Spacing()

                -- Build character list
                local override_chars = {}
                for cname, cdata in pairs(data) do
                    if cname ~= '_hidden' and cname ~= '_settings' and type(cdata) == 'table' then
                        override_chars[#override_chars + 1] = cname
                    end
                end
                table.sort(override_chars)

                -- Character selector
                imgui.Text('Character:')
                for _, cname in ipairs(override_chars) do
                    imgui.SameLine()
                    imgui.PushID('ovrsel_' .. cname)
                    if cname == override_selected_char then
                        imgui.TextColored({ 0.0, 1.0, 0.4, 1.0 }, '> ' .. cname)
                    else
                        if imgui.SmallButton(cname) then
                            override_selected_char = cname
                        end
                    end
                    imgui.PopID()
                end

                if override_selected_char and data[override_selected_char] then
                    local ocd = ensure_char(override_selected_char)
                    if ocd then

                        -- ---- Weekly Quests & Kill Quests ----
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Override: Weekly Quests##ovr_wq') then
                            for _, q in ipairs(QUESTS) do
                                if q.type ~= 'enm' then
                                    local cur = ocd.quests[q.name] or 'NOT STARTED'
                                    local valid_statuses
                                    if q.type == 'kill_mob' then
                                        valid_statuses = { 'NEED TO COMPLETE', 'COMPLETED' }
                                    else
                                        valid_statuses = { 'NOT STARTED', 'NEED TO COMPLETE', 'READY TO TURN IN', 'COMPLETED' }
                                    end

                                    local color = STATUS_COLORS[cur] or STATUS_COLORS['NOT STARTED']
                                    imgui.Text(q.name .. ':')
                                    imgui.SameLine()
                                    imgui.TextColored(color, cur)
                                    for _, s in ipairs(valid_statuses) do
                                        if s ~= cur then
                                            imgui.SameLine()
                                            imgui.PushID('ovr_wq_' .. q.name .. '_' .. s)
                                            if imgui.SmallButton(s) then
                                                ocd.quests[q.name] = s
                                                log(string.format('Manual override: %s [%s] %s -> %s',
                                                    q.name, override_selected_char, cur, s))
                                                save_data()
                                            end
                                            imgui.PopID()
                                        end
                                    end
                                end
                            end
                        end

                        -- ---- ENMs / Limbus ----
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Override: Cooldowns (ENM / Limbus / HAAP)##ovr_enm') then
                            for _, q in ipairs(QUESTS) do
                                if q.type == 'enm' then
                                    if not ocd.enms then ocd.enms = {} end
                                    if not ocd.enms[q.name] then ocd.enms[q.name] = {} end
                                    local enm = ocd.enms[q.name]

                                    -- Item-based rewards (obtain_phrase) have no KI to toggle
                                    local has_ki_field = q.ki_quest_active and q.ki_quest_active ~= ''
                                    local ki_str = has_ki_field and (enm.has_ki and 'Yes' or 'No') or '-'
                                    local obt_str = enm.ki_obtained_time and format_time(enm.ki_obtained_time) or 'Never'
                                    local _, _, ready_str = get_enm_status(enm, q)

                                    imgui.Text(string.format('%s  KI:%s  CD:%s  Ready:%s',
                                        q.name, ki_str, obt_str, ready_str))
                                    imgui.SameLine()

                                    if has_ki_field then
                                        imgui.PushID('ovr_enm_ki_' .. q.name)
                                        if imgui.SmallButton(enm.has_ki and 'Remove KI' or 'Give KI') then
                                            enm.has_ki = not enm.has_ki
                                            log(string.format('Manual override: %s [%s] has_ki -> %s',
                                                q.name, override_selected_char, tostring(enm.has_ki)))
                                            save_data()
                                        end
                                        imgui.PopID()
                                        imgui.SameLine()
                                    end

                                    imgui.PushID('ovr_enm_cdn_' .. q.name)
                                    if imgui.SmallButton('Start CD') then
                                        enm.ki_obtained_time = os.time()
                                        enm.notified_ready = nil  -- reset alert flag
                                        log(string.format('Manual override: %s [%s] cooldown started now',
                                            q.name, override_selected_char))
                                        save_data()
                                    end
                                    imgui.PopID()
                                    imgui.SameLine()

                                    imgui.PushID('ovr_enm_cdc_' .. q.name)
                                    if imgui.SmallButton('Clear CD') then
                                        enm.ki_obtained_time = nil
                                        enm.notified_ready = nil  -- reset alert flag so READY alert fires
                                        log(string.format('Manual override: %s [%s] cooldown cleared',
                                            q.name, override_selected_char))
                                        save_data()
                                    end
                                    imgui.PopID()
                                end
                            end
                        end

                        -- ---- Eco Warriors ----
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Override: Eco Warriors##ovr_eco') then
                            local ovr_week = get_week_key()
                            for _, ew in ipairs(ECO_WARRIORS) do
                                if not ocd.eco then ocd.eco = {} end
                                if not ocd.eco[ew.key] then ocd.eco[ew.key] = {} end
                                local eco = ocd.eco[ew.key]

                                local cw = eco.completed_week or 'Never'
                                local flags = {}
                                if eco.stored_flagged then flags[#flags + 1] = 'Flagged' end
                                if eco.stored_verified then flags[#flags + 1] = 'Verified' end
                                local flag_str = #flags > 0 and table.concat(flags, ', ') or 'None'

                                imgui.Text(string.format('%s  Last:%s  Flags:%s', ew.nation, cw, flag_str))
                                imgui.SameLine()

                                imgui.PushID('ovr_eco_f_' .. ew.key)
                                if imgui.SmallButton(eco.stored_flagged and 'Unflag' or 'Flag') then
                                    if eco.stored_flagged then
                                        eco.stored_flagged = nil
                                    else
                                        eco.stored_flagged = true
                                    end
                                    log(string.format('Manual override: Eco %s [%s] flagged -> %s',
                                        ew.nation, override_selected_char, tostring(eco.stored_flagged)))
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.SameLine()

                                imgui.PushID('ovr_eco_v_' .. ew.key)
                                if imgui.SmallButton(eco.stored_verified and 'Unverify' or 'Verify') then
                                    if eco.stored_verified then
                                        eco.stored_verified = nil
                                    else
                                        eco.stored_verified = true
                                    end
                                    log(string.format('Manual override: Eco %s [%s] verified -> %s',
                                        ew.nation, override_selected_char, tostring(eco.stored_verified)))
                                    save_data()
                                end
                                imgui.PopID()
                                imgui.SameLine()

                                imgui.PushID('ovr_eco_c_' .. ew.key)
                                if eco.completed_week == ovr_week then
                                    if imgui.SmallButton('Clear Cmpl') then
                                        eco.completed_week = nil
                                        eco.stored_flagged = nil
                                        eco.stored_verified = nil
                                        -- Remove from round-robin cycle tracking
                                        if ocd.eco_cycle then
                                            ocd.eco_cycle[ew.key] = nil
                                        end
                                        log(string.format('Manual override: Eco %s [%s] completion cleared',
                                            ew.nation, override_selected_char))
                                        save_data()
                                    end
                                else
                                    if imgui.SmallButton('Mark Cmpl') then
                                        eco.completed_week = ovr_week
                                        eco.stored_flagged = nil
                                        eco.stored_verified = nil
                                        -- Track round-robin cycle completion
                                        if not ocd.eco_cycle then ocd.eco_cycle = {} end
                                        ocd.eco_cycle[ew.key] = true
                                        -- Check if all nations are done in this cycle
                                        local cycle_complete = true
                                        for _, check_ew in ipairs(ECO_WARRIORS) do
                                            if not ocd.eco_cycle[check_ew.key] then
                                                cycle_complete = false
                                                break
                                            end
                                        end
                                        if cycle_complete then
                                            log('Manual override: Eco full round-robin cycle complete - all nations will be available next.')
                                            ocd.eco_cycle = {}
                                        end
                                        log(string.format('Manual override: Eco %s [%s] completed %s',
                                            ew.nation, override_selected_char, ovr_week))
                                        save_data()
                                    end
                                end
                                imgui.PopID()
                            end
                        end

                        -- ---- Dynamis ----
                        imgui.Spacing()
                        if imgui.CollapsingHeader('Override: Dynamis##ovr_dyn') then
                            if not ocd.dynamis then ocd.dynamis = {} end
                            local dyn = ocd.dynamis
                            local used = #dyn

                            local remove_idx = nil
                            for i, entry in ipairs(dyn) do
                                imgui.Text(string.format('  Entrance %d: %s (%s)',
                                    i, entry.zone or '??', format_time(entry.time)))
                                imgui.SameLine()
                                imgui.PushID('ovr_dyn_rm_' .. i)
                                if imgui.SmallButton('Remove') then
                                    remove_idx = i
                                end
                                imgui.PopID()
                            end
                            if remove_idx then
                                local removed = dyn[remove_idx]
                                table.remove(ocd.dynamis, remove_idx)
                                log(string.format('Manual override: removed Dynamis entry %d (%s) [%s]',
                                    remove_idx, removed and removed.zone or '??', override_selected_char))
                                save_data()
                            end

                            if used == 0 then
                                imgui.TextColored(KI_COLOR_DIM, '  No entries this week.')
                            end

                            if used < DYNAMIS_MAX_ENTRIES then
                                imgui.Text('  Add:')
                                local zone_ids_sorted = {}
                                for zid, _ in pairs(DYNAMIS_ZONES) do
                                    zone_ids_sorted[#zone_ids_sorted + 1] = zid
                                end
                                table.sort(zone_ids_sorted)
                                local btn_count = 0
                                for _, zid in ipairs(zone_ids_sorted) do
                                    local zname = DYNAMIS_ZONES[zid]
                                    local short = zname:gsub('Dynamis %- ', '')
                                    if btn_count > 0 and btn_count % 5 ~= 0 then
                                        imgui.SameLine()
                                    end
                                    imgui.PushID('ovr_dyn_add_' .. zid)
                                    if imgui.SmallButton(short) then
                                        ocd.dynamis[#ocd.dynamis + 1] = {
                                            zone = zname,
                                            zone_id = zid,
                                            time = os.time(),
                                        }
                                        log(string.format('Manual override: added Dynamis %s [%s]',
                                            zname, override_selected_char))
                                        save_data()
                                    end
                                    imgui.PopID()
                                    btn_count = btn_count + 1
                                end
                            else
                                imgui.TextColored(KI_COLOR_DIM,
                                    string.format('  All %d entrances used.', DYNAMIS_MAX_ENTRIES))
                            end
                        end

                    end -- if ocd
                end -- if override_selected_char

                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end
    imgui.End()
end

-- ============================================================================
-- Events
-- ============================================================================
ashita.events.register('load', 'weeklier_load_cb', function()
    save_path = string.format('%s/char_data.json', addon.path)
    build_ki_lookup()
    load_data()
    -- Normalize every stored character so weekly rollover resets apply even
    -- to characters that haven't logged in since the reset.
    for cname, cdata in pairs(data) do
        if cname ~= '_hidden' and cname ~= '_settings' and type(cdata) == 'table' then
            ensure_char(cname)
        end
    end
    save_data()
    log('Loaded. Use /weeklier show to open the tracker.')
end)

ashita.events.register('unload', 'weeklier_unload_cb', function()
    save_data()
    log('Data saved. Unloaded.')
end)

-- ============================================================================
-- Commands
-- ============================================================================
ashita.events.register('command', 'weeklier_command_cb', function(e)
    local args = e.command:args()
    if not args or #args == 0 then return end
    if args[1]:lower() ~= '/weeklier' then return end

    e.blocked = true

    local sub = args[2] and args[2]:lower() or 'show'

    if sub == 'show' or sub == 'toggle' then
        show_window[1] = not show_window[1]
        if show_window[1] then
            select_current_tab = true
        end
        return
    end

    if sub == 'hide' then
        show_window[1] = false
        return
    end

    if sub == 'reset' then
        -- Reset current character's quest data for this week
        local name = get_current_char_name()
        if name then
            local cd = ensure_char(name)
            if cd then
                for _, q in ipairs(QUESTS) do
                    if q.type ~= 'enm' then
                        if q.type == 'kill_mob' then
                            cd.quests[q.name] = 'NEED TO COMPLETE'
                        else
                            cd.quests[q.name] = 'NOT STARTED'
                        end
                    end
                end
                cd.dynamis = {}
                save_data()
                log('Reset all quests and dynamis for ' .. name)
            end
        else
            log('Cannot determine current character.')
        end
        return
    end

    if sub == 'resetall' then
        data = {}
        hidden_quests = {}
        data._hidden = hidden_quests
        data._settings = settings
        save_data()
        log('All character data cleared.')
        return
    end

    if sub == 'status' then
        local name = get_current_char_name()
        if name then
            local cd = ensure_char(name)
            if cd then
                log('Quest status for ' .. name .. ' (' .. cd.week .. '):')
                for _, q in ipairs(QUESTS) do
                    log(string.format('  %s: %s', q.name, cd.quests[q.name] or 'NOT STARTED'))
                end
                -- Eco warriors
                local eco_statuses = derive_eco_statuses(cd, true)
                for _, ew in ipairs(ECO_WARRIORS) do
                    local r = eco_statuses[ew.key]
                    local cw = r.completed_week or 'Never'
                    log(string.format('  [Eco] %s: %s (last=%s)', ew.nation, r.status, cw))
                end
                -- Dynamis
                local dyn = cd.dynamis or {}
                log(string.format('  [Dynamis] %d/%d entrances used', #dyn, DYNAMIS_MAX_ENTRIES))
                for i, entry in ipairs(dyn) do
                    log(string.format('    Entrance %d: %s (%s)', i, entry.zone, format_time(entry.time)))
                end
            end
        else
            log('Cannot determine current character.')
        end
        return
    end

    if sub == 'help' then
        log('Commands:')
        log('  /weeklier show    - toggle the tracker window')
        log('  /weeklier hide    - close the tracker window')
        log('  /weeklier status  - print quest status to chat')
        log('  /weeklier reset   - reset current character\'s quests')
        log('  /weeklier resetall- clear ALL character data')
        log('  /weeklier debug   - toggle debug logging')
        log('  /weeklier dump    - dump current packet state for diagnostics')
        log('  /weeklier help    - show this help')
        return
    end

    if sub == 'debug' then
        debug_mode = not debug_mode
        log('Debug mode: ' .. (debug_mode and 'ON' or 'OFF'))
        return
    end

    if sub == 'dump' then
        local char = get_current_char_name() or '(unknown)'
        log('--- Weeklier State Dump ---')
        log('Current char: ' .. char)
        log('Week key: ' .. get_week_key())
        log('Debug mode: ' .. (debug_mode and 'ON' or 'OFF'))

        -- KI bitmap loaded tables
        local ki_tables = {}
        for idx, _ in pairs(ki_bitmap) do ki_tables[#ki_tables + 1] = tostring(idx) end
        table.sort(ki_tables)
        log('KI bitmap tables loaded: [' .. table.concat(ki_tables, ', ') .. ']')

        -- Quest blocks loaded
        local qb_tables = {}
        for idx, _ in pairs(active_quest_blocks) do qb_tables[#qb_tables + 1] = tostring(idx) end
        table.sort(qb_tables)
        log('Quest blocks loaded (log_ids): [' .. table.concat(qb_tables, ', ') .. ']')

        -- Per-quest diagnostics
        for _, q in ipairs(QUESTS) do
            if q.type == 'enm' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                local has = ki_id and has_key_item(ki_id) or false
                log(string.format('  [ENM] %s: ki=%s (id=%s) has=%s',
                    q.name, tostring(q.ki_quest_active), tostring(ki_id), tostring(has)))
            elseif q.type == 'kill_mob' then
                local cd = data[char] and data[char].quests or {}
                log(string.format('  [KILL] %s: stored=%s',
                    q.name, tostring(cd[q.name])))
            else
                local cd = data[char] and data[char].quests or {}
                local stored = cd[q.name] or 'NOT STARTED'
                local qa = (q.quest_log_id and q.quest_id) and is_quest_active(q.quest_log_id, q.quest_id) or false
                local ki_a_id = resolve_ki_id(q.ki_quest_active)
                local ki_i_id = resolve_ki_id(q.ki_quest_incomplete)
                local has_a = ki_a_id and has_key_item(ki_a_id) or false
                local has_i = ki_i_id and has_key_item(ki_i_id) or false
                log(string.format('  [QUEST] %s: stored=%s quest_active=%s ki_active=%s(id=%s,has=%s) ki_incomplete=%s(id=%s,has=%s)',
                    q.name, stored, tostring(qa),
                    tostring(q.ki_quest_active), tostring(ki_a_id), tostring(has_a),
                    tostring(q.ki_quest_incomplete), tostring(ki_i_id), tostring(has_i)))
            end
        end

        -- Eco warrior diagnostics
        local cd_eco = data[char] and data[char].eco or {}
        for _, ew in ipairs(ECO_WARRIORS) do
            local eco_data = cd_eco[ew.key] or {}
            local qa = is_quest_active(ew.quest_log_id, ew.quest_id)
            local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
            local has_ki = ki_id and has_key_item(ki_id) or false
            log(string.format('  [ECO] %s: completed_week=%s quest_active=%s ki=%s(id=%s,has=%s)',
                ew.nation, tostring(eco_data.completed_week), tostring(qa),
                tostring(ew.ki_quest_incomplete), tostring(ki_id), tostring(has_ki)))
        end

        -- Dynamis diagnostics
        local cd_dyn = data[char] and data[char].dynamis or {}
        log(string.format('  [DYNAMIS] %d/%d entrances used', #cd_dyn, DYNAMIS_MAX_ENTRIES))
        for i, entry in ipairs(cd_dyn) do
            log(string.format('    %d: zone=%s (id=%d) time=%s',
                i, entry.zone or '??', entry.zone_id or 0, format_time(entry.time)))
        end

        log('--- End Dump ---')
        return
    end

    log('Unknown command. Try /weeklier help')
end)

-- ============================================================================
-- Chat Monitoring
-- ============================================================================
ashita.events.register('text_in', 'weeklier_text_in_cb', function(e)
    if not e.message or e.message == '' then return end

    -- Ignore our own log/dlog output to prevent recursive matching.
    -- log() prints "[weeklier]" and dlog() prints "[weeklier:DBG]".
    if string.find(e.message, '[weeklier', 1, true) then return end

    local msg = normalize_string(e.message)
    if not msg then return end

    -- ------------------------------------------------------------------
    -- Dynamis session time tracking (chat-based)
    -- ------------------------------------------------------------------
    -- These are injected system messages, so they must be processed BEFORE
    -- the e.injected early-return below.
    --
    -- "You will be expelled from Dynamis in X minute(s) (Earth time)." -> set expiry
    -- "Your stay in Dynamis has been extended by X minutes."           -> extend expiry

    -- Expulsion warning (singular and plural)
    local expel_minutes = string.match(msg, 'you will be expelled from dynamis in (%d+) minutes?')
    if expel_minutes then
        local minutes = tonumber(expel_minutes)
        if minutes and minutes > 0 then
            local now_ts = os.time()
            local expiry = now_ts + (minutes * 60)
            if dynamis_active_session then
                dynamis_active_session.expiry_time = expiry
                dynamis_active_session.last_update = now_ts
                log(string.format('Dynamis session updated: %s - %d minutes remaining.',
                    dynamis_active_session.zone_name, minutes))
            else
                dynamis_active_session = {
                    zone_id     = 0,
                    zone_name   = 'Unknown',
                    expiry_time = expiry,
                    last_update = now_ts,
                }
                log(string.format('Dynamis session created from chat: %d minutes remaining.', minutes))
            end
            dlog(string.format('Dynamis session expiry set: %s (in %d minutes, epoch=%d).',
                dynamis_active_session.zone_name, minutes, expiry))
            persist_dynamis_session()
        end
    end

    -- Time extension
    local extend_minutes = string.match(msg, 'your stay in dynamis has been extended by (%d+) minutes?')
    if extend_minutes then
        local minutes = tonumber(extend_minutes)
        if minutes and minutes > 0 then
            local now_ts = os.time()
            if dynamis_active_session then
                dynamis_active_session.expiry_time = dynamis_active_session.expiry_time + (minutes * 60)
                dynamis_active_session.last_update = now_ts
                local remaining = math.max(0, dynamis_active_session.expiry_time - now_ts)
                log(string.format('Dynamis session extended: +%d minutes (%s). Total remaining: %d minutes.',
                    minutes, dynamis_active_session.zone_name, math.ceil(remaining / 60)))
            else
                dlog(string.format('Dynamis extension chat detected but no active session. Creating one with %d minutes.',
                    minutes))
                dynamis_active_session = {
                    zone_id     = 0,
                    zone_name   = 'Unknown',
                    expiry_time = now_ts + (minutes * 60),
                    last_update = now_ts,
                }
            end
            persist_dynamis_session()
        end
    end

    -- ------------------------------------------------------------------
    -- Kill-mob phase 1: look for "defeats the <mob>" (injected message)
    -- Must be checked before the e.injected early-return below.
    -- ------------------------------------------------------------------
    for qi, q in ipairs(QUESTS) do
        if q.type == 'kill_mob' and q.kill_mob and q.kill_mob ~= '' then
            local mob_norm      = normalize_string(q.kill_mob)
            local defeat_phrase = 'defeats the ' .. mob_norm
            local falls_phrase  = mob_norm .. ' falls to the ground'
            if string.find(msg, defeat_phrase, 1, true)
               or string.find(msg, falls_phrase, 1, true) then
                queue_or_confirm_kill(qi, q)
            end
        end
    end

    -- Skip injected messages for all other processing (quest phrases, etc.)
    if e.injected then return end

    -- Identify the current character
    local name = get_current_char_name()
    if not name then return end

    -- Keep current_char up to date for UI sorting
    if current_char ~= name then
        current_char = name
        ensure_char(name)
    end

    local now = os.clock()

    -- ------------------------------------------------------------------
    -- Kill-mob phase 2: track the player's XP gains and confirm pending
    -- kills. Message order is NOT guaranteed under server load - the XP
    -- line can render before the defeat line - so every XP gain is
    -- remembered (last_xp_gain_time) and checked when a death is
    -- detected later (see queue_or_confirm_kill).
    -- Pattern: "<charname> gains 1234 experience points."
    -- ("limit points" also counts, for kills made in limit mode.)
    -- ------------------------------------------------------------------
    local who = normalize_string(name)
    local xp_amount = tonumber(string.match(msg, who .. ' gains (%d+) experience points') or '')
    if xp_amount or string.find(msg, who .. ' gains %d+ limit points') then
        last_xp_gain_time = now

        -- Zone-gated exact-amount confirmation: kills that happen out of
        -- message/packet range produce no death signal at all, but the XP
        -- award always reaches the player. If a quest defines kill_xp_amount
        -- and kill_xp_zones, an XP gain of exactly that amount in one of
        -- those zones confirms the kill by itself.
        if xp_amount then
            local zone_id = get_current_zone_id()
            for qi, q in ipairs(QUESTS) do
                if q.type == 'kill_mob' and q.kill_xp_amount == xp_amount and q.kill_xp_zones then
                    local already = data[name] and data[name].quests
                        and data[name].quests[q.name] == 'COMPLETED'
                    if not already then
                        if zone_id and q.kill_xp_zones[zone_id] then
                            log(string.format('Kill confirmed: %s (exactly %d XP in zone %d)',
                                q.name, xp_amount, zone_id))
                            try_advance(name, q.name, 'COMPLETED')
                            pending_kills[qi] = nil
                        else
                            dlog(string.format('Exact XP match for %s (%d) but zone %s is not in kill_xp_zones - ignored.',
                                q.name, xp_amount, tostring(zone_id)))
                        end
                    end
                end
            end
        end

        if next(pending_kills) then
            dlog(string.format('XP message matched: "%s"', msg))
            -- Confirm every pending kill that is still within the window
            for qi, ts in pairs(pending_kills) do
                if (now - ts) <= KILL_CONFIRM_WINDOW then
                    local q = QUESTS[qi]
                    if q then
                        try_advance(name, q.name, 'COMPLETED')
                        log(string.format('Kill confirmed: %s (XP received)', q.name))
                    end
                else
                    dlog(string.format('Kill expired: quest[%d] age=%.1fs > window=%.1fs',
                        qi, now - ts, KILL_CONFIRM_WINDOW))
                end
            end
            -- Clear all pending kills once XP is confirmed
            pending_kills = {}
        end
    end

    -- Expire any stale pending kills outside the window
    for qi, ts in pairs(pending_kills) do
        if (now - ts) > KILL_CONFIRM_WINDOW then
            pending_kills[qi] = nil
        end
    end

    -- ------------------------------------------------------------------
    -- Check every quest definition
    -- ------------------------------------------------------------------
    for _, q in ipairs(QUESTS) do

        -- ==============================================================
        -- Flag phrase detection (chat-based alternative to quest_log_id)
        -- ==============================================================
        if q.flag_phrase and q.type ~= 'enm' and q.type ~= 'kill_mob' then
            local matched = match_flag_phrase(q.flag_phrase, msg)
            if matched then
                try_advance(name, q.name, 'NEED TO COMPLETE')
                dlog(string.format('Flag phrase matched [%s]: "%s"', q.name, matched))
            end
        end

        -- ==============================================================
        -- Complete phrase detection (chat-based turn-in confirmation)
        -- ==============================================================
        if q.complete_phrase and q.complete_phrase ~= '' and q.type ~= 'enm' and q.type ~= 'kill_mob' then
            local phrase = normalize_string(q.complete_phrase)
            if phrase and string.find(msg, phrase, 1, true) then
                try_advance(name, q.name, 'COMPLETED')
                dlog(string.format('Complete phrase matched [%s]: "%s"', q.name, q.complete_phrase))
            end
        end

        -- ==============================================================
        -- ENM / cooldown quest: detect the reward being obtained.
        -- KI rewards: "Obtained key item: <ki_display_name>."
        -- Item rewards (e.g. HAAP pages): custom obtain_phrase.
        -- ==============================================================
        if q.type == 'enm' then
            local obtain_phrase
            if q.obtain_phrase and q.obtain_phrase ~= '' then
                obtain_phrase = normalize_string(q.obtain_phrase)
            elseif q.ki_display_name and q.ki_display_name ~= '' then
                obtain_phrase = 'obtained key item: ' .. normalize_string(q.ki_display_name)
            end
            if obtain_phrase and string.find(msg, obtain_phrase, 1, true) then
                local cd = ensure_char(name)
                if cd then
                    if not cd.enms then cd.enms = {} end
                    if not cd.enms[q.name] then cd.enms[q.name] = {} end
                    cd.enms[q.name].ki_obtained_time = os.time()
                    cd.enms[q.name].notified_ready = nil  -- clear alert flag so next expiry triggers a new notification
                    local cooldown = q.enm_cooldown_days or 5
                    log(string.format('%s obtained - %d day cooldown started.', q.name, cooldown))
                    save_data()
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Eco Warrior flag_phrase detection
    -- ------------------------------------------------------------------
    for _, ew in ipairs(ECO_WARRIORS) do
        if ew.flag_phrase then
            local matched = match_flag_phrase(ew.flag_phrase, msg)
            if matched then
                local cd = ensure_char(name)
                if cd then
                    if not cd.eco then cd.eco = {} end
                    if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
                    if not cd.eco[ew.key].stored_flagged then
                        cd.eco[ew.key].stored_flagged = true
                        log(string.format('Eco Warrior %s: flag phrase detected - marking as flagged. ("%s")', ew.nation, matched))
                        save_data()
                    end
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Eco Warrior verify_phrase detection
    -- ------------------------------------------------------------------
    for _, ew in ipairs(ECO_WARRIORS) do
        if ew.verify_phrase then
            local matched = match_flag_phrase(ew.verify_phrase, msg)
            if matched then
                local cd = ensure_char(name)
                if cd then
                    if not cd.eco then cd.eco = {} end
                    if not cd.eco[ew.key] then cd.eco[ew.key] = {} end
                    if not cd.eco[ew.key].stored_verified then
                        cd.eco[ew.key].stored_verified = true
                        log(string.format('Eco Warrior %s: verify phrase detected - marking as verified. ("%s")', ew.nation, matched))
                        save_data()
                    end
                end
            end
        end
    end
end)

-- ============================================================================
-- Key Item Packet (0x055) - updates ki_bitmap
-- ============================================================================
-- Packet layout (GP_SERV_SCENARIOITEM):
--   0x00  header (4 bytes: id/size/sync)
--   0x04  GetItemFlag[16]  - 16 x uint32 = 64 bytes (obtained KI bits)
--   0x44  LookItemFlag[16] - 16 x uint32 = 64 bytes (viewed KI bits)
--   0x84  TableIndex       - uint16 (0-6, which 512-KI block)
--   0x86  padding
-- All offsets are 0-based; Lua string.byte is 1-based, so +1.
-- ============================================================================
ashita.events.register('packet_in', 'weeklier_packet_in_cb', function(e)
    if e.id ~= 0x055 then return end

    -- Clear stale packet state if the character has changed since last packet
    check_packet_char_change()

    local pkt = e.data
    if not pkt or #pkt < 0x88 then return end

    -- TableIndex is at offset 0x84 (uint16 LE) -> 1-based offset 0x85
    local table_index = u16le(pkt, 0x84 + 1)
    if table_index < 0 or table_index > 6 then return end

    -- Snapshot the previous bitmap for this table before overwriting
    if ki_bitmap[table_index] then
        local prev = {}
        for i = 0, 15 do
            prev[i] = ki_bitmap[table_index][i] or 0
        end
        prev_ki_bitmap[table_index] = prev
    end

    -- GetItemFlag starts at offset 0x04 -> 1-based offset 0x05
    local tbl = {}
    for i = 0, 15 do
        tbl[i] = u32le(pkt, 0x04 + 1 + (i * 4))
    end
    ki_bitmap[table_index] = tbl

    -- Debug: log KI status for every configured quest whose KI lives in this table
    if debug_mode then
        for _, q in ipairs(QUESTS) do
            -- Check ki_quest_active
            if q.ki_quest_active and q.ki_quest_active ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_active)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    dlog(string.format('0x055 [%s]: ki_quest_active=%s (id=%d) has=%s',
                        q.name, q.ki_quest_active, ki_id, tostring(has_key_item(ki_id))))
                end
            end
            -- Check ki_quest_incomplete
            if q.ki_quest_incomplete and q.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(q.ki_quest_incomplete)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    local prev_had = had_key_item(ki_id)
                    local now_has = has_key_item(ki_id)
                    dlog(string.format('0x055 [%s]: ki_quest_incomplete=%s (id=%d) prev=%s now=%s',
                        q.name, q.ki_quest_incomplete, ki_id, tostring(prev_had), tostring(now_has)))
                end
            end
        end
        -- Eco warriors
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.ki_quest_incomplete and ew.ki_quest_incomplete ~= '' then
                local ki_id = resolve_ki_id(ew.ki_quest_incomplete)
                if ki_id and math.floor(ki_id / 512) == table_index then
                    local prev_had = had_key_item(ki_id)
                    local now_has = has_key_item(ki_id)
                    dlog(string.format('0x055 [Eco %s]: ki=%s (id=%d) prev=%s now=%s',
                        ew.nation, ew.ki_quest_incomplete, ki_id, tostring(prev_had), tostring(now_has)))
                end
            end
        end
    end

    -- Persist ENM KI possession state so it's viewable on other characters
    local char_name = get_current_char_name()
    if char_name then
        local cd = ensure_char(char_name)
        if cd then
            local changed = false
            for _, q in ipairs(QUESTS) do
                if q.type == 'enm' and q.ki_quest_active and q.ki_quest_active ~= '' then
                    local ki_id = resolve_ki_id(q.ki_quest_active)
                    if ki_id and math.floor(ki_id / 512) == table_index then
                        local has = has_key_item(ki_id)
                        if not cd.enms[q.name] then cd.enms[q.name] = {} end
                        if cd.enms[q.name].has_ki ~= has then
                            local prev_has = cd.enms[q.name].has_ki
                            cd.enms[q.name].has_ki = has
                            changed = true
                            -- Only log when transitioning from a known state (not initial load)
                            if prev_has ~= nil then
                                log(string.format('ENM KI %s: %s', has and 'obtained' or 'lost', q.name))
                            end
                            dlog(string.format('ENM KI persisted [%s]: has_ki=%s', q.name, tostring(has)))
                        end
                    end
                end
            end
            if changed then save_data() end
        end
    end

    -- Detect KI removals (ki_quest_incomplete -> COMPLETED, ki_quest_active -> READY TO TURN IN or COMPLETED)
    if prev_ki_bitmap[table_index] then
        process_ki_removals(table_index)
    end

    -- Derive and persist statuses from updated packet data
    update_current_char_statuses()
end)

ashita.events.register('packet_in', 'weeklier_packet_in_cb_056_active_quests', function(e)
    if e.id ~= 0x056 then
        return
    end

    -- Clear stale packet state if the character has changed since last packet
    check_packet_char_change()

    local pkt = e.data
    if not pkt or #pkt < 0x28 then
        return
    end

    -- Port at offset 0x24 (uint16 LE)
    local port = u16le(pkt, 0x24 + 1)
    local log_id = QUEST_OFFER_PORT_TO_LOG_ID[port]
    if log_id == nil then
        return
    end

    active_quest_blocks[log_id] = read_u32x8(pkt)

    -- Debug: log quest active status for every configured quest in this log_id
    if debug_mode then
        for _, q in ipairs(QUESTS) do
            if q.quest_log_id and q.quest_log_id == log_id and q.quest_id then
                local active = is_quest_active(q.quest_log_id, q.quest_id)
                dlog(string.format('0x056 [%s]: log_id=%d quest_id=%d active=%s',
                    q.name, q.quest_log_id, q.quest_id, tostring(active)))
            end
        end
        -- Eco warriors
        for _, ew in ipairs(ECO_WARRIORS) do
            if ew.quest_log_id == log_id and ew.quest_id then
                local active = is_quest_active(ew.quest_log_id, ew.quest_id)
                dlog(string.format('0x056 [Eco %s]: log_id=%d quest_id=%d active=%s',
                    ew.nation, ew.quest_log_id, ew.quest_id, tostring(active)))
            end
        end
    end

    -- Derive and persist statuses from updated packet data
    update_current_char_statuses()
end)

-- ============================================================================
-- Zone-In Packet (0x00A) - Dynamis tracking
-- ============================================================================
-- Detects when the player zones into a Dynamis zone. Records the entry
-- (up to DYNAMIS_MAX_ENTRIES per week) with zone name and timestamp.
-- If the player leaves and re-enters the same Dynamis zone while the timer
-- is still running (active session tracked via chat messages), it is NOT
-- counted again.
ashita.events.register('packet_in', 'weeklier_packet_in_cb_00A_zone', function(e)
    if e.id ~= 0x00A then return end

    -- Clear stale packet state if the character has changed since last packet.
    -- If a change IS detected, skip this packet entirely: the 0x00A is the first
    -- packet to arrive during login, so the zone data inside it may still reflect
    -- the previous character's zone (especially on private servers). Processing it
    -- could incorrectly record a Dynamis entry for the new character.
    if check_packet_char_change() then
        dlog('0x00A: character change detected - skipping packet to avoid stale zone data.')
        return
    end

    local pkt = e.data
    if not pkt or #pkt < 0x34 then return end

    -- Zone ID at offset 0x30 (uint32 LE) -> 1-based offset 0x31
    local zone_id = u32le(pkt, 0x30 + 1)
    local zone_name = DYNAMIS_ZONES[zone_id]

    -- (EXP band scanning on zone-in is handled by the 0x01D Inventory Finish
    --  packet handler, which schedules a deferred scan once the post-zone
    --  inventory burst is complete. No action needed here.)

    -- Zoning into a non-Dynamis zone: clear active session
    if not zone_name then
        if dynamis_active_session then
            dlog(string.format('Zoned to non-Dynamis zone (id=%d) - clearing active Dynamis session (%s, expiry in %ds).',
                zone_id, dynamis_active_session.zone_name,
                math.max(0, dynamis_active_session.expiry_time - os.time())))
            -- Don't clear - the session expiry is tracked by time.
            -- The player might zone out briefly and come back.
            -- The session is only truly over when the timer expires.
        end
        return
    end

    -- Dynamis zone detected
    dlog(string.format('0x00A zone-in: %s (id=%d)', zone_name, zone_id))

    -- No in-memory session: try restoring a persisted one. The in-memory
    -- session is lost when the client crashes or the player relogs inside
    -- Dynamis - without this, the re-entry would count as a second weekly
    -- entrance.
    if not is_dynamis_session_active() then
        local rname = get_current_char_name()
        local saved = rname and data[rname] and data[rname].dynamis_session or nil
        if saved and saved.expiry_time then
            if saved.expiry_time > os.time() then
                dynamis_active_session = {
                    zone_id     = saved.zone_id or zone_id,
                    zone_name   = saved.zone_name or zone_name,
                    expiry_time = saved.expiry_time,
                    last_update = os.time(),
                }
                log(string.format('Restored Dynamis session from save (%s, ~%d min left) - treating zone-in as re-entry.',
                    dynamis_active_session.zone_name,
                    math.ceil((saved.expiry_time - os.time()) / 60)))
            else
                data[rname].dynamis_session = nil
            end
        end
    end

    -- Check if there is an active Dynamis session (timer still running).
    -- If so, this is a re-entry (e.g. d/c or voluntary zone-out) - don't count it.
    if is_dynamis_session_active() then
        dlog(string.format('Dynamis zone-in %s (id=%d) - active session exists (%s, expiry in %ds). Treating as re-entry.',
            zone_name, zone_id, dynamis_active_session.zone_name,
            math.max(0, dynamis_active_session.expiry_time - os.time())))
        -- Update the session's zone in case they re-entered a different dynamis zone
        -- (shouldn't normally happen, but be safe)
        dynamis_active_session.zone_id = zone_id
        dynamis_active_session.zone_name = zone_name
        persist_dynamis_session()
        return
    end

    local name = get_current_char_name()
    if not name then return end

    local cd = ensure_char(name)
    if not cd then return end

    local used = #cd.dynamis
    if used >= DYNAMIS_MAX_ENTRIES then
        dlog(string.format('Dynamis zone-in %s (id=%d) but already at max entries (%d).',
            zone_name, zone_id, DYNAMIS_MAX_ENTRIES))
        return
    end

    local entry = {
        zone    = zone_name,
        zone_id = zone_id,
        time    = os.time(),
    }
    cd.dynamis[#cd.dynamis + 1] = entry
    log(string.format('Dynamis entrance %d/%d: %s', #cd.dynamis, DYNAMIS_MAX_ENTRIES, zone_name))
    save_data()

    -- Initialize the active session. The expiry will be set properly when the
    -- "expelled from Dynamis in X minutes" chat message arrives. For now, set a
    -- generous placeholder so that a rapid zone-out/zone-in before the first time
    -- message is still treated as the same session.
    dynamis_active_session = {
        zone_id     = zone_id,
        zone_name   = zone_name,
        expiry_time = os.time() + 120,  -- 2 min placeholder until time chat message arrives
        last_update = os.time(),
    }
    persist_dynamis_session()
    dlog(string.format('Initialized Dynamis session: %s (placeholder expiry in 120s).', zone_name))
end)

-- ============================================================================
-- Inventory Finish Packet (0x01D) - schedules the authoritative EXP band scan
-- ============================================================================
-- Sent by the server once the post-zone inventory burst is complete. The scan
-- itself must NOT run here: packet handlers fire before the client has
-- processed the burst into memory, so an immediate scan sees empty bags and
-- wrongly clears the stored band (the next zone's 0x020 then re-adds it,
-- spamming clear/found/READY messages on every zone). Instead, schedule the
-- full scan (the only one allowed to clear, allow_clear = true) to run from
-- d3d_present a couple of seconds later, once memory has caught up.
ashita.events.register('packet_in', 'weeklier_packet_in_cb_01D_inv_finish', function(e)
    if e.id ~= 0x01D then return end
    if not settings.exp_band_tracking_enabled then return end
    exp_band_scan_at = os.time() + EXP_BAND_SCAN_DELAY
    exp_band_scan_retries = 0
    dlog(string.format('0x01D inventory finish - EXP band scan scheduled in %ds.', EXP_BAND_SCAN_DELAY))
end)

-- ============================================================================
-- Inventory Item Packet (0x020) - EXP Band detection
-- ============================================================================
-- The server sends 0x020 (Inventory Item) per item slot to deliver full item
-- info, including the 24-byte Extra buffer that holds the band's charges and
-- next-use timestamp. It fires:
--   - For every item in every bag during the post-zone inventory burst.
--   - When a new item is obtained (e.g. ENM band drop).
--   - When an item changes state (charges consumed, timer updated).
--   - With count=0 to signal a slot was cleared.
-- Filtering by item id up-front keeps this cheap even though it fires per
-- item: the body only runs when one of the 3 EXP band IDs comes through.
--
-- Packet 0x020 layout (1-based offsets):
--   [05..08] u32  count
--   [09..12] u32  bazaar price
--   [13]     u8   bag id
--   [14]     u8   slot
--   [15..16] u16  item id
--   [17]     u8   status / flag
--   [18..41] 24B  Extra
ashita.events.register('packet_in', 'weeklier_packet_in_cb_020_item', function(e)
    if e.id ~= 0x020 then return end
    if not settings.exp_band_tracking_enabled then return end
    if not e.data or #e.data < 41 then return end

    local item_id = u16le(e.data, 15)
    local band_name = EXP_BANDS[item_id]
    if not band_name then return end

    -- Only track bands in bags they can actually be used from. A band parked
    -- in e.g. Mog Safe would otherwise be recorded here and then cleared by
    -- the memory scan (which only checks these bags), flip-flopping the state.
    local bag_id = string.byte(e.data, 13)
    if not EXP_BAND_BAG_NAMES[bag_id] then return end

    local cur = get_current_char_name()
    if not cur then return end
    local cd = ensure_char(cur)
    if not cd then return end

    local count = u32le(e.data, 5)
    local extra = string.sub(e.data, 18, 41)    -- 24 bytes
    local charges = string.byte(extra, 2) or 0

    -- Slot cleared, item gone, or out of charges: treat as removal, but only
    -- if the stored band matches this item (don't wipe a different band that
    -- might be in another slot).
    if count == 0 or charges < 1 then
        if cd.exp_band and cd.exp_band.item_id == item_id then
            log(string.format('EXP Band removed/depleted: %s - clearing.', band_name))
            cd.exp_band = nil
            save_data()
        end
        return
    end

    local extra_ts = u32le(extra, 5)
    local expiry   = extra_ts + VANA_OFFSET

    local prev = cd.exp_band
    local found = {
        item_id     = item_id,
        name        = band_name,
        expiry_time = expiry,
        charges     = charges,
    }
    -- Preserve notified_ready if nothing material changed.
    local same_as_prev = prev
        and prev.item_id     == found.item_id
        and prev.expiry_time == found.expiry_time
        and prev.charges     == found.charges
    if prev and prev.item_id == found.item_id and prev.expiry_time == found.expiry_time then
        found.notified_ready = prev.notified_ready
    end
    cd.exp_band = found
    if not same_as_prev then
        local now = os.time()
        if expiry <= now then
            -- This log line already announces READY - mark it notified so
            -- the alert checker doesn't announce it a second time.
            found.notified_ready = true
            log(string.format('EXP Band found: %s (%d charge%s) - READY now.',
                band_name, charges, charges == 1 and '' or 's'))
        else
            log(string.format('EXP Band found: %s (%d charge%s) - ready in %s.',
                band_name, charges, charges == 1 and '' or 's',
                format_countdown(expiry - now)))
        end
        save_data()
    end

    check_exp_band_alerts(cur, false)
end)

-- ============================================================================
-- ImGui Render Hook
-- ============================================================================
ashita.events.register('d3d_present', 'weeklier_present_cb', function()
    -- Keep current char name fresh
    local name = get_current_char_name()
    if name and name ~= '' then
        if current_char ~= name then
            current_char = name
            ensure_char(name)
        end

        -- ENM alert: one-time login check for the current character
        if not enm_alert_login_done[name] then
            enm_alert_login_done[name] = true
            check_enm_alerts(name, true)
        end

        -- ENM alert: periodic check (once per ENM_ALERT_CHECK_INTERVAL seconds)
        local now_ts = os.time()
        if (now_ts - enm_alert_last_check) >= ENM_ALERT_CHECK_INTERVAL then
            enm_alert_last_check = now_ts
            check_enm_alerts(name, false)
            -- EXP Band: periodic alert check (same interval)
            if settings.exp_band_tracking_enabled then
                check_exp_band_alerts(name, false)
            end
        end

        -- EXP Band: one-time login scan + alert check. Set-only scan
        -- (allow_clear=false): bags may not be fully populated this early
        -- after login; the authoritative full scan is scheduled by the 0x01D
        -- Inventory Finish handler once the burst completes.
        if settings.exp_band_tracking_enabled and not exp_band_alert_login_done[name] then
            exp_band_alert_login_done[name] = true
            scan_exp_band_for_char(name, false)
            check_exp_band_alerts(name, true)
        end

        -- EXP Band: deferred scan scheduled by the 0x01D handler. Zone loads
        -- can take far longer than the initial delay (long loading screens),
        -- so an empty scan while a band is stored is NOT trusted: it is
        -- retried on the same delay, and only the final attempt runs with
        -- allow_clear to drop a band that is genuinely gone.
        if exp_band_scan_at and os.time() >= exp_band_scan_at then
            exp_band_scan_at = nil
            if settings.exp_band_tracking_enabled then
                local result = scan_exp_band_for_char(name, false)
                local stored = data[name] and data[name].exp_band
                if result ~= 'found' and stored then
                    if exp_band_scan_retries < EXP_BAND_SCAN_MAX_RETRIES then
                        exp_band_scan_retries = exp_band_scan_retries + 1
                        exp_band_scan_at = os.time() + EXP_BAND_SCAN_DELAY
                        dlog(string.format('EXP band scan: stored band not visible in memory yet - retry %d/%d.',
                            exp_band_scan_retries, EXP_BAND_SCAN_MAX_RETRIES))
                    else
                        scan_exp_band_for_char(name, true)
                    end
                end
            end
        end
    end

    render_ui()
end)








# Weeklier

An [Ashita v4](https://www.ashitaxi.com/) addon for [HorizonXI](https://horizonxi.com/) that tracks weekly quest completion across all of your characters.
Now officially approved for use! (may not appear on the approved addon list yet)

## Features

- **Multi-character tracking** - Quest status is persisted to JSON so you can view progress for all characters from any character.
- **Automatic detection** - Status is derived from live packet data (key items via `0x055`, quest log via `0x056`, zone-in via `0x00A`) and chat message parsing. No manual check-offs needed.
- **Weekly reset countdown** - Displays the current week and a live countdown to the next reset (midnight Monday JST / Sunday 15:00 UTC).
- **ImGui UI** - Tabbed interface with a tab per character, collapsible sections, and color-coded statuses.
- **Configurable** - Add or remove quests by editing the `QUESTS` table in the Lua file.

## Screenshot

![Weeklier UI](example.png)

## Tracked Content

### Weekly Quests

Standard weekly quests with automatic status progression:

| Status | Meaning |
|---|---|
| NOT STARTED | Quest has not been flagged this week |
| NEED TO COMPLETE | Quest is active (flagged, has entry KI) |
| READY TO TURN IN | Objective complete, needs to be turned in to NPC |
| COMPLETED | Quest turned in for the week |

Pre-configured quests:
- Secrets of Ovens Lost
- Uninvited Guests
- Spice Gals
- Requiem of Sin

### Cooldowns (ENM / Limbus / HAAP / Assault / ISNM)

ENMs and Limbus have an independent cooldown timer rather than following the weekly reset. ENMs typically have a 5-day cooldown, while Limbus has a 3-day cooldown. The addon tracks when the key item was obtained and displays a countdown until the next one can be acquired.

Pre-configured ENMs:
- Monarch Linn ENM
- Test Your Mite
- Mine Shaft #2716 ENM
- Boneyard Gully ENM
- Bearclaw Pinnacle ENM
- Dem: You Are What You Eat
- Mea: Playing Host
- Holla: Simulant
- Vahzl: Pulling the Plug

Pre-configured Limbus:
- Limbus (Cosmo-Cleanse, 3-day cooldown)

Pre-configured ISNM orders (Shajaf, Aht Urhgan Whitegate):
- ISNM Order (2000) - Confidential Imperial order, for the level-60 fights
- ISNM Order (3000) - Secret Imperial order, for the uncapped fights

A character can buy one order per JST day, whichever it is, so the two rows share one lock: buying either starts both, and they become READY together at the next JST midnight (15:00 UTC) rather than 24 hours later. Has KI shows which order is being held (an order can't be bought while one is held).

### Kill-Based Quests

Weekly NMs that are completed simply by killing them and receiving experience points. Detection uses a two-step confirmation: a "defeats the X" message followed by an XP gain message within a short time window.

Pre-configured:
- Kill Highwind

### Eco Warriors

A special round-robin system tracking the three Eco Warrior quests (San d'Oria, Bastok, Windurst). Only one nation can be completed per week, and each nation must be completed before repeating one. The addon tracks the rotation and shows which nations are available.

| Status | Meaning |
|---|---|
| Available | Can be flagged this week |
| Flagged | Quest is currently active |
| Return to NPC | KI obtained, needs in-zone verification before turning in |
| Need To Complete | Verified in-zone, return to quest giver to complete |
| Completed | Completed this week |
| Not Available | Another nation was done this week, or this nation must wait its turn |

A manual override is available in the Config tab to bootstrap the round-robin cycle for existing characters.

### Dynamis

Tracks Dynamis entries (up to 2 per week per character, same weekly reset). The addon detects zone-ins to any Dynamis zone via the `0x00A` packet and records the zone name and timestamp.

To prevent leaving and re-entering the same Dynamis zone from counting as a second entry, the addon tracks the active session timer by parsing system chat messages:
- "You will be expelled from Dynamis in X minutes (Earth time)." - sets the session expiry
- "Your stay in Dynamis has been extended by X minutes." - extends the session expiry

While the session timer is still running, subsequent zone-ins are treated as re-entries and are not counted.

Supported zones:
- Dynamis - Valkurm, Buburimu, Qufim, Tavnazia
- Dynamis - Beaucedine, Xarcabard
- Dynamis - San d'Oria, Bastok, Windurst, Jeuno

### Ashu Talif (account, weekly)

Halshaob's three quests in Nashmau - Scouting the Ashu Talif, Royal Painter Escort and Targeting the Captain - are fought in turn on The Ashu Talif. On HorizonXI the chain runs once a week for the whole account, so this section keeps **one record per account** and shows it on every character's tab: each stage as Paid, Won or Failed, with who and when. The record empties at the weekly reset.

| Status | Meaning |
|---|---|
| Paid | Halshaob took the fee; the fight is still ahead |
| Won | "Objective complete" on the ship |
| Failed | "The mission has failed" on the ship - final, even after an objective-complete line |

Stages are read from chat: Halshaob's "...in exchange fer lettin' you take on \<quest>" line, then the ship's objective-complete or mission-failed line. Ship lines only count for a character with a stage paid for, so The Black Coffin and other fights on the ship are not recorded. A stage paid for in an earlier week and not fought yet is listed under the table.

The section records what happened; it does not say which characters are locked out for the week. The Config tab can mark a stage won or clear it.

### Assault

Tracks the Assault tag stock (banked Imperial Army I.D. tags). Tags are a server-side counter rather than a key item, so the only way to read them is to **talk to Rytaal in Aht Urhgan Whitegate** - the section shows "Unknown" until you do. One visit is enough: the addon stores the restock timer the NPC sends and projects the stock forward from it, so the count and countdowns stay correct without going back.

On HorizonXI the stock is **shared across the whole account** - one pool of tags behind every character, restocking on one timer. The addon stores it once instead of per character, so a reading taken on any character shows on all of their tabs (labelled `Stock (account)`), a tag drawn on one is deducted for all of them, and `Last read` names the character the reading came from. Apart from the rank rows below, only `Holding tag` and `Registered` are per character, because a tag in hand is a key item and a sign-up is a registration - neither is part of the stock.

The client never sends an account id, so there is nothing to group characters by: every character the addon tracks is taken to be on the one account. Two accounts played through the same Ashita install would share the one record.

Rytaal only sends that reading while you are talking to him, which is before you draw a tag or sign up for anything. Everything that happens afterwards is picked up separately:

- **Drawing a tag** - its key item arriving decrements the account's stock, and starts the restock timer if the stock was full.
- **Signing up** - the mission is read from the reply the client sends when you pick one at a reception counter, so it is recorded the moment you commit to it. The mission is cross-checked against the counter that offered it, since each counter only books its own staging point.
- **Talking to a counter** - its event reports the assault you are currently registered for, which corrects the display on any later visit.
- **Finishing** - the assault orders being taken back clears the registration.

The section shows the current stock and cap, time until the next tag, time until the stock is full, whether you are carrying an undrawn tag, and which assault you are registered for (by name and staging point, e.g. `Seagull Grounded (Periqia)`).

Tags restock up to a cap of 3 (or 4 at Second Lieutenant with every assault completed). The cap is not in the packet, so it is learned from the highest stock seen.

The restock period is not in the packet either. It is 24 hours on HorizonXI and on retail / upstream LandSandBoat, which is the default, but it can be changed per install for servers that tune it:

```
/weeklier assaultperiod <hours>
```

Restocks land on a fixed time of day, set by the draw that started the timer. The addon derives the schedule from that time of day rather than from the packet's absolute timestamp, because on HorizonXI that timestamp arrives exactly one period early - verified against `Obtained key item: Imperial Army I.D. tag` chatlog lines. Using only the time of day makes the countdown immune to that offset.

A count projected past what the server actually reported is marked `(est.)`, and the `Last read` row always shows the raw value.

Save files written before 1.6 kept a stock on each character. They are migrated on first load: the most recent of those readings becomes the shared one, and the stock fields are dropped from the character entries.

#### Rank and rank-up points

`Rank` is the highest Wildcat badge the character holds.

`Rank-up points` counts toward the 25 a promotion needs. The server keeps these as a hidden counter - **+5** for clearing a mission for the first time, **+1** for a repeat, nothing for a failure, back to 0 on promotion - and never sends it to the client, so weeklier counts clears itself:

- A clear is the "You gain \<n> Assault points!" line inside an Assault zone (Leujaoam Sanctum, Mamool Ja Training Grounds, Lebros Cavern, Periqia or Ilrusi Atoll).
- First or repeat comes from the list of completed missions the server sends with the quest log. If that list or the registered mission is unknown, the clear counts +1 and the value is marked `(est.)`.
- A promotion - the new badge's "Obtained key item" line - restarts the count at 0.

The starting value cannot be read from the game, so the row shows `Unknown - set in Config` until you enter it in the Config tab (buttons for Unknown, Set 0, -5, -1, +1 and +5). Once set, it stays correct from clears and promotions. At 25 or more the row reads `promotion ready (Naja Salaheem)`.

## Detection Methods

The addon uses multiple detection methods depending on the quest type:

- **Packet 0x055 (Key Items)** - Monitors the key item bitmap to detect when quest-related KIs are obtained or removed. KI removal is used to detect quest completion or objective completion.
- **Packet 0x056 (Quest Log)** - Reads the active quest bitmap to determine if a quest is currently flagged, and the completed Aht Urhgan block (port 0x00C0), whose words 4-7 list every completed Assault mission, to tell a first clear from a repeat.
- **Packet 0x00A (Zone-In)** - Detects Dynamis zone-ins, and leaving The Ashu Talif after a run.
- **Packet 0x034 (NPC Event)** - Reads the Assault tag stock and restock timer from Rytaal's event parameters, and the currently registered assault from the reception counters' events. Matched on event id (268 for Rytaal, 273-277 for the counters) in Aht Urhgan Whitegate rather than on NPC ids, which are not guaranteed to be identical across servers.
- **Packet 0x05B (Event Option, outgoing)** - Reads the Assault mission picked at a reception counter, which the server never sends back in a packet of its own.
- **Chat parsing** - Detects quest flag/completion phrases for bugged quests that don't appear correctly in the quest log. Also used to track Dynamis session timers (injected system messages), Eco Warrior in-zone verification steps, Ashu Talif payments and results, ISNM and ENM key items, Assault clears, and promotions.

## Installation

1. Copy the `weeklier` folder into your Ashita `addons` directory.
2. Load the addon in-game: `/addon load weeklier`

## Commands

| Command | Description |
|---|---|
| `/weeklier show` | Toggle the tracker window (default) |
| `/weeklier hide` | Close the tracker window |
| `/weeklier status` | Print quest status to chat log |
| `/weeklier reset` | Reset current character's quest data for this week |
| `/weeklier resetall` | Clear ALL character data |
| `/weeklier debug` | Toggle debug logging |
| `/weeklier dump` | Dump current packet state for diagnostics |
| `/weeklier help` | Show help text |

## Configuration

### Adding Quests

Edit the `QUESTS` table near the top of `weeklier.lua`. Each quest entry supports the following fields:

```lua
{
    name                = 'Quest Name',           -- Display name (required)
    type                = nil,                    -- nil for standard, 'enm', or 'kill_mob'

    -- Quest log detection (packet 0x056)
    quest_log_id        = 4,                      -- Log ID (0=Sandy, 1=Bastok, 2=Windy, 3=Jeuno, etc.)
    quest_id            = 73,                     -- Quest ID within that log (0-255)

    -- Key item detection (packet 0x055)
    ki_quest_active     = 'KEY_ITEM_NAME',        -- KI received on quest accept
    ki_active_is_completion = false,              -- If true, KI removal = COMPLETED (no turn-in)
    ki_quest_incomplete = 'KEY_ITEM_NAME',        -- KI held until turn-in

    -- Chat-based detection (fallback for bugged quests)
    flag_phrase         = 'npc dialogue text',    -- Chat text when quest is flagged (string or table of strings)
    complete_phrase     = 'npc dialogue text',    -- Chat text when quest is completed
}
```

### Hiding Quests

Click the `x` button next to any quest in the UI to hide it. Hidden quests can be restored from the Config tab.

### Manual Status Override

The Config tab provides a manual status override for any quest, ENM / Limbus, Eco Warrior nation, or Dynamis entry. This is useful for bootstrapping data on characters that have already completed content before installing the addon.

## Data Storage

All data is saved to `char_data.json` in the addon directory. This includes per-character quest status, ENM / Limbus / ISNM cooldown timers, Eco Warrior rotation history, Dynamis entry logs, Assault rank and rank-up points, the account-wide Assault tag stock and Ashu Talif week, and UI preferences (hidden quests).

## Dependencies

- [Ashita v4](https://www.ashitaxi.com/)
- `data/key_item.lua` - Key item name-to-ID mapping (included)

## License

This project is provided as-is for use with HorizonXI.


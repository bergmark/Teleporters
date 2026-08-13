-- Dev-only smoke test: builds a handful of teleporters on a running save and drives the mod
-- through the paths a player would actually take - stepping onto a teleporter, the linked GUI,
-- searching, renaming (both via the GUI and via the map tag), teleporting to another teleporter,
-- and removal - checking the mod's own stored state after each step.
--
-- Not wired into the mod by default - it builds entities on a running save, so it must only run
-- against a disposable test map. To use it: uncomment the `handler.add_lib` for this file in
-- control.lua, then run e.g. `factorio.exe --create test.zip` followed by
-- `factorio.exe --benchmark test.zip --benchmark-ticks 1200` and check the log for
-- "SELF_TEST_RESULT". Re-comment it out again afterwards.
--
-- Note on driving the GUI: on_gui_click / on_gui_text_changed / on_gui_confirmed cannot go
-- through script.raise_event (the engine only allows a small whitelist), so this calls the mod's
-- own registered handlers directly with the same event shape the engine would deliver.
local self_test = {}

local names = require("shared")
local teleporters = require("script/teleporters")
local teleporter_name = names.entities.teleporter

local refs
local setup_ok = false

local state = function()
  return storage.teleporters
end

local network = function()
  return state().networks["player"]
end

-- Call one of the mod's own event handlers directly, with the fields the engine would set.
local fire = function(event_id, data)
  local handler = teleporters.events[event_id]
  if not handler then error("the mod has no handler registered for event " .. tostring(event_id)) end
  data.name = data.name or event_id
  data.tick = data.tick or game.tick
  handler(data)
end

local click = function(element, player_index)
  fire(defines.events.on_gui_click,
  {
    element = element,
    player_index = player_index,
    button = defines.mouse_button_type.left,
    alt = false,
    control = false,
    shift = false
  })
end

local check = function(condition, message)
  if not condition then error(message, 2) end
end

local check_eq = function(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

-- Depth-first walk over a GUI subtree.
local find_element = function(root, predicate)
  if not (root and root.valid) then return end
  local stack = {root}
  while #stack > 0 do
    local element = table.remove(stack)
    if element.valid then
      if predicate(element) then return element end
      for _, child in pairs(element.children) do
        stack[#stack + 1] = child
      end
    end
  end
end

local teleporter_frame = function(player_index)
  local frame = state().teleporter_frames[player_index]
  check(frame and frame.valid, "the linked teleporter GUI is not open")
  return frame
end

-- The button the GUI builds for a given teleporter is named "_" .. its network name.
local find_teleport_button = function(player_index, name)
  local button = find_element(teleporter_frame(player_index), function(element)
    return element.type == "button" and element.name == "_" .. name
  end)
  check(button, "no teleport button in the GUI for '" .. name .. "'")
  return button
end

local name_of = function(entity)
  local data = state().teleporter_map[entity.unit_number]
  check(data, "no teleporter data registered for unit " .. tostring(entity.unit_number))
  return data.name
end

local build = function(surface, force, position, raise)
  local entity = surface.create_entity
  {
    name = teleporter_name,
    position = position,
    force = force,
    raise_built = raise
  }
  check(entity and entity.valid, "failed to build a teleporter at " .. serpent.line(position))
  return entity
end

local setup = function()
  local surface = game.surfaces.nauvis
  surface.request_to_generate_chunks({0, 0}, 5)
  surface.force_generate_chunk_requests()

  local force = game.forces.player
  force.research_all_technologies()

  -- A save created via headless --create has never had a client join and spawn, so the local
  -- player starts in remote view rather than as a character. The whole point of this mod is
  -- walking a character onto a teleporter, so it needs a real one.
  local player = game.players[1]
  check(player and player.valid, "no player 1 to test with")
  if player.controller_type ~= defines.controllers.character then
    local character = surface.create_entity{name = "character", position = {0, -12}, force = force}
    player.set_controller{type = defines.controllers.character, character = character}
  end
  player.character.teleport({0, -12})

  local a = build(surface, force, {0, 0}, true)
  local b = build(surface, force, {32, 0}, true)
  local c = build(surface, force, {64, 0}, true)

  return
  {
    surface = surface,
    force = force,
    player = player,
    a = a,
    b = b,
    c = c,
    expected_count = 3
  }
end

local check_registration = function()
  local net = network()
  check(net, "no network was created for the player force")
  check_eq(table_size(net), refs.expected_count, "teleporters registered in the network")

  for name, data in pairs(net) do
    check(data.teleporter and data.teleporter.valid, "network entry '" .. name .. "' has no valid entity")
    check(data.flying_text and data.flying_text.valid, "network entry '" .. name .. "' has no flying text")
    check(data.tag and data.tag.valid, "network entry '" .. name .. "' has no map tag")
    check_eq(data.name, name, "the name stored on entry '" .. name .. "'")
    check_eq(data.tag.text, name, "the map tag text for '" .. name .. "'")
    check_eq(data.flying_text.text, name, "the flying text for '" .. name .. "'")
  end

  check_eq(table_size(state().teleporter_map), refs.expected_count, "entries in the unit number map")
  check_eq(table_size(state().tag_map), refs.expected_count, "entries in the tag map")

  -- The map tag has to carry the teleporter icon, since that is how the mod tells its own tags
  -- apart from player-made ones.
  local any = state().teleporter_map[refs.a.unit_number]
  check_eq(any.tag.icon.name, teleporter_name, "the icon on a teleporter's map tag")

  log("SELF_TEST: " .. refs.expected_count .. " teleporters registered with text, tags and names")
end

-- Rename through the map tag, which is the on_chart_tag_modified path.
local rename_by_tag = function(force, data, new_name)
  local old_name = data.name
  local tag = data.tag
  local old_icon, old_position, old_surface = tag.icon, tag.position, tag.surface
  tag.text = new_name
  -- Writing tag.text may already have raised the event and completed the rename; if so this
  -- second delivery finds nothing under the old name and returns without doing anything.
  if tag.valid then
    fire(defines.events.on_chart_tag_modified,
    {
      force = force,
      tag = tag,
      old_text = old_name,
      old_icon = old_icon,
      old_position = old_position,
      old_surface = old_surface,
      player_index = 1
    })
  end
end

-- A player may rename a teleporter to the default name a not-yet-built teleporter would claim.
-- Building into that name must not silently drop the existing one out of the network.
local check_default_name_collision = function()
  local net = network()
  local clash_holder_old_name = name_of(refs.c)

  -- Build without raising, so the name is still free while we set the trap.
  local d = build(refs.surface, refs.force, {96, 0}, false)
  local clash = "Teleporter " .. d.unit_number
  refs.d = d

  rename_by_tag(refs.force, net[clash_holder_old_name], clash)
  check_eq(net[clash] and net[clash].teleporter.unit_number, refs.c.unit_number,
    "the teleporter parked on the clashing name")
  check(net[clash_holder_old_name] == nil, "the old name is still registered after renaming")

  fire(defines.events.script_raised_built, {entity = d})
  refs.expected_count = refs.expected_count + 1

  check_eq(net[clash] and net[clash].teleporter.unit_number, refs.c.unit_number,
    "the teleporter on the clashing name after a collision")
  local fallback = clash .. " (2)"
  check(net[fallback], "the newly built teleporter did not fall back to '" .. fallback .. "'")
  check_eq(net[fallback].teleporter.unit_number, d.unit_number, "the teleporter under the fallback name")
  check_eq(table_size(net), refs.expected_count, "network size after a name collision")

  log("SELF_TEST: name collision on build kept both teleporters ('" .. clash .. "' and '" .. fallback .. "')")
end

local check_tag_rename = function()
  local net = network()
  local old_name = name_of(refs.b)
  rename_by_tag(refs.force, net[old_name], "Renamed By Tag")

  check(net[old_name] == nil, "the old name survived a map tag rename")
  local data = net["Renamed By Tag"]
  check(data, "the new name is not in the network after a map tag rename")
  check_eq(data.teleporter.unit_number, refs.b.unit_number, "the teleporter under the new name")
  check_eq(data.name, "Renamed By Tag", "the stored name after a map tag rename")
  check_eq(data.flying_text.text, "Renamed By Tag", "the flying text after a map tag rename")
  check_eq(table_size(net), refs.expected_count, "network size after a rename")
  check_eq(table_size(state().tag_map), refs.expected_count, "tag map size after a rename")

  log("SELF_TEST: renaming through the map tag moved the network entry and resynced text/tag")
end

local check_duplicate_name_rejected = function()
  local net = network()
  local taken = name_of(refs.b)
  local victim_name = name_of(refs.a)
  local data = net[victim_name]

  data.tag.text = taken
  fire(defines.events.on_chart_tag_modified,
  {
    force = refs.force,
    tag = data.tag,
    old_text = victim_name,
    old_icon = data.tag.icon,
    old_position = data.tag.position,
    old_surface = data.tag.surface,
    player_index = 1
  })

  check(net[victim_name], "the teleporter lost its name to a duplicate rename")
  check_eq(net[victim_name].teleporter.unit_number, refs.a.unit_number, "the teleporter after a rejected rename")
  check_eq(net[taken].teleporter.unit_number, refs.b.unit_number, "the teleporter that already owned the name")
  check_eq(data.tag.text, victim_name, "the map tag text after a rejected rename")
  check_eq(table_size(net), refs.expected_count, "network size after a rejected rename")

  log("SELF_TEST: a rename onto an already-taken name was rejected and the tag reverted")
end

-- Rejecting a rename means writing the old name back onto the tag, which raises
-- on_chart_tag_modified straight back into the mod. If that re-entry is not stopped, the mod
-- looks at the reverted name, finds it 'taken' (by this very teleporter) and reverts again,
-- ping-ponging until the C stack blows. Data with no stored name is the case where the revert
-- target alternates every time, so it is the one that actually runs away.
local check_rename_rejection_does_not_recurse = function()
  local net = network()
  local victim_name = name_of(refs.a)
  local data = net[victim_name]
  local taken = name_of(refs.b)
  local stored_name = data.name
  data.name = nil

  data.tag.text = taken
  fire(defines.events.on_chart_tag_modified,
  {
    force = refs.force,
    tag = data.tag,
    old_text = victim_name,
    old_icon = data.tag.icon,
    old_position = data.tag.position,
    old_surface = data.tag.surface,
    player_index = 1
  })

  data.name = stored_name

  check(net[victim_name], "the teleporter lost its name to a rejected rename with no stored name")
  check_eq(data.tag.text, victim_name, "the map tag text after a rejected rename with no stored name")
  check_eq(table_size(net), refs.expected_count, "network size after a rejected rename with no stored name")

  log("SELF_TEST: a rejected rename settles in one pass instead of recursing")
end

local check_fake_tag_rejected = function()
  local before = table_size(state().tag_map)
  local tag = refs.force.add_chart_tag(refs.surface,
  {
    icon = {type = "item", name = teleporter_name},
    position = {-64, 0},
    text = "Not A Real Teleporter"
  })

  check(not (tag and tag.valid), "a player-made tag using the teleporter icon was not destroyed")
  check_eq(table_size(state().tag_map), before, "tag map size after a rejected fake tag")
  check_eq(table_size(network()), refs.expected_count, "network size after a rejected fake tag")

  -- An unrelated tag must be left alone.
  local innocent = refs.force.add_chart_tag(refs.surface,
  {
    icon = {type = "item", name = "iron-plate"},
    position = {-64, 32},
    text = "Just A Note"
  })
  check(innocent and innocent.valid, "an unrelated player tag was destroyed")
  innocent.destroy()

  log("SELF_TEST: fake teleporter tags are destroyed, unrelated tags are left alone")
end

local check_tag_icon_protected = function()
  local data = network()[name_of(refs.a)]
  local tag = data.tag
  local name = tag.text
  tag.icon = {type = "item", name = "iron-plate"}
  fire(defines.events.on_chart_tag_modified,
  {
    force = refs.force,
    tag = tag,
    old_text = name,
    old_icon = {type = "item", name = teleporter_name},
    old_position = tag.position,
    old_surface = tag.surface,
    player_index = 1
  })

  check(tag.valid, "the teleporter's map tag was destroyed by an icon change")
  check_eq(tag.icon.name, teleporter_name, "the map tag icon after someone tried to change it")
  check_eq(tag.text, name, "the map tag text after an icon change")

  log("SELF_TEST: changing a teleporter tag's icon is reverted")
end

local check_tag_removal_resync = function()
  local name = name_of(refs.a)
  local data = network()[name]
  local old_tag = data.tag

  fire(defines.events.on_chart_tag_removed, {force = refs.force, tag = old_tag, player_index = 1})
  old_tag.destroy()

  local new_tag = network()[name].tag
  check(new_tag and new_tag.valid, "the map tag was not recreated after being removed")
  check_eq(new_tag.text, name, "the recreated map tag's text")
  check_eq(table_size(state().tag_map), refs.expected_count, "tag map size after a tag was recreated")
  check_eq(network()[name].name, name, "the network name after a tag was recreated")

  log("SELF_TEST: deleting a teleporter's map tag recreates it")
end

local step_onto_teleporter = function()
  -- Land mines only fire once their arming timeout has run down.
  check_eq(refs.a.status, defines.entity_status.armed, "the teleporter's status before stepping on it")
  refs.player.character.teleport(refs.a.position)
  log("SELF_TEST: character stepped onto the teleporter")
end

local check_linked = function()
  local player = refs.player
  local linked = state().player_linked_teleporter[player.index]
  check(linked and linked.valid, "stepping onto a teleporter did not link the player to it")
  check_eq(linked.unit_number, refs.a.unit_number, "the teleporter the player is linked to")

  -- 2.1 replaced the LuaEntity::active write with disabled_by_script.
  check_eq(refs.a.disabled_by_script, true, "the teleporter being disabled while its GUI is open")
  check_eq(player.character.disabled_by_script, true, "the character being frozen while the GUI is open")
  check_eq(refs.a.active, false, "the teleporter reading as inactive")

  local frame = teleporter_frame(player.index)
  check_eq(player.opened, frame, "the player's opened GUI")

  -- Every other teleporter in the network gets a button; the one being stood on does not.
  for name, data in pairs(network()) do
    local button = find_element(frame, function(element)
      return element.type == "button" and element.name == "_" .. name
    end)
    if data.teleporter.unit_number == refs.a.unit_number then
      check(not button, "the teleporter being stood on has a button to itself")
    else
      check(button, "no button in the GUI for '" .. name .. "'")
    end
  end

  log("SELF_TEST: stepping on a teleporter froze the character, disabled the pad and opened the GUI")
end

local check_search_filter = function()
  local player = refs.player
  local box = state().search_boxes[player.index]
  check(box and box.valid, "the GUI has no search box")

  local target = name_of(refs.b)
  box.text = target
  fire(defines.events.on_gui_text_changed, {element = box, player_index = player.index, text = target})

  local shown, hidden = 0, 0
  for name, data in pairs(network()) do
    local button = find_element(teleporter_frame(player.index), function(element)
      return element.type == "button" and element.name == "_" .. name
    end)
    if button then
      if name == target then
        check(button.visible, "the searched-for teleporter '" .. name .. "' was hidden")
        shown = shown + 1
      else
        check(not button.visible, "teleporter '" .. name .. "' stayed visible while searching")
        hidden = hidden + 1
      end
    end
  end
  check(shown == 1, "the search matched " .. shown .. " teleporters instead of exactly one")
  check(hidden > 0, "the search had nothing to filter out, so it proves nothing")

  -- Clear it again so the rest of the run sees the full list.
  box.text = ""
  fire(defines.events.on_gui_text_changed, {element = box, player_index = player.index, text = ""})
  local button = find_teleport_button(player.index, target)
  check(button.visible, "clearing the search did not bring the buttons back")

  log("SELF_TEST: the search box filtered the teleporter list down to the match and back")
end

local check_gui_rename = function()
  local player = refs.player
  local frame = teleporter_frame(player.index)
  local old_name = name_of(refs.a)

  -- The first sprite-button in the title flow is the rename button.
  local rename_button = find_element(frame, function(element)
    return element.type == "sprite-button" and element.sprite == "utility/rename_icon"
  end)
  check(rename_button, "no rename button in the teleporter GUI")
  click(rename_button, player.index)

  local rename_frame = state().rename_frames[player.index]
  check(rename_frame and rename_frame.valid, "clicking rename did not open the rename frame")

  local textfield = find_element(rename_frame, function(element) return element.type == "textfield" end)
  check(textfield, "the rename frame has no textfield")
  check_eq(textfield.text, old_name, "the rename textfield's starting text")

  textfield.text = "Renamed By Gui"
  fire(defines.events.on_gui_confirmed, {element = textfield, player_index = player.index})

  local net = network()
  check(net[old_name] == nil, "the old name survived a GUI rename")
  local data = net["Renamed By Gui"]
  check(data, "the new name is not in the network after a GUI rename")
  check_eq(data.teleporter.unit_number, refs.a.unit_number, "the teleporter under the GUI-renamed name")
  check_eq(data.name, "Renamed By Gui", "the stored name after a GUI rename")
  check_eq(data.tag.text, "Renamed By Gui", "the map tag text after a GUI rename")
  check_eq(table_size(net), refs.expected_count, "network size after a GUI rename")

  check(not (state().rename_frames[player.index] and state().rename_frames[player.index].valid),
    "the rename frame stayed open after confirming")
  -- The rename refreshes the teleporter GUI, so the player must still be linked and looking at it.
  check(state().player_linked_teleporter[player.index], "renaming unlinked the player from the teleporter")
  teleporter_frame(player.index)

  log("SELF_TEST: renaming through the GUI moved the network entry and rebuilt the GUI")
end

local do_teleport = function()
  local player = refs.player
  local destination = name_of(refs.b)
  refs.teleport_destination = destination
  refs.origin_position = {x = player.position.x, y = player.position.y}
  click(find_teleport_button(player.index, destination), player.index)
  log("SELF_TEST: clicked the teleport button for '" .. destination .. "'")
end

local check_teleported = function()
  local player = refs.player
  local target = refs.b.position

  local distance = ((player.position.x - target.x) ^ 2 + (player.position.y - target.y) ^ 2) ^ 0.5
  check(distance < 1, string.format("the player ended up %.2f tiles from the destination teleporter", distance))

  check(state().player_linked_teleporter[player.index] == nil, "the player is still linked after teleporting")
  check(not (state().teleporter_frames[player.index] and state().teleporter_frames[player.index].valid),
    "the teleporter GUI stayed open after teleporting")

  check_eq(refs.a.disabled_by_script, false, "the source teleporter being re-enabled after teleporting")
  check_eq(player.character.disabled_by_script, false, "the character being unfrozen after teleporting")
  check_eq(refs.a.active, true, "the source teleporter reading as active again")

  -- The destination is re-armed on arrival, otherwise the player would be caught by it instantly
  -- and never be able to leave.
  check(refs.b.timeout > 0, "the destination teleporter was not disarmed on arrival")
  check(refs.b.status ~= defines.entity_status.armed, "the destination teleporter is still armed on arrival")

  local recent = state().recent[player.name]
  check(recent and recent[refs.b.unit_number], "the destination was not recorded as recently used")

  -- Step off before the destination re-arms, so later phases are not disturbed.
  player.character.teleport({0, -12})

  log(string.format("SELF_TEST: teleport landed the player within %.2f tiles and disarmed the destination", distance))
end

local check_no_immediate_relink = function()
  check(state().player_linked_teleporter[refs.player.index] == nil,
    "the player got caught by a teleporter again after walking away")
  log("SELF_TEST: the player stayed free after stepping off the destination")
end

local check_removal = function()
  local net = network()
  local name = name_of(refs.c)
  local data = net[name]
  local flying_text, tag = data.flying_text, data.tag
  local unit_number = refs.c.unit_number

  refs.c.destroy{raise_destroy = true}
  refs.expected_count = refs.expected_count - 1

  check(net[name] == nil, "the removed teleporter is still in the network")
  check(state().teleporter_map[unit_number] == nil, "the removed teleporter is still in the unit number map")
  check(not flying_text.valid, "the removed teleporter's flying text was not destroyed")
  check(not tag.valid, "the removed teleporter's map tag was not destroyed")
  check_eq(table_size(net), refs.expected_count, "network size after a removal")
  check_eq(table_size(state().teleporter_map), refs.expected_count, "unit number map size after a removal")
  check_eq(table_size(state().tag_map), refs.expected_count, "tag map size after a removal")

  log("SELF_TEST: removing a teleporter cleaned up its network entry, flying text and map tag")
end

-- A teleporter can disappear without the mod hearing about it (a mod destroying it without
-- raising, a surface being deleted). on_configuration_changed rebuilds from the networks and
-- must drop those leftovers rather than keep serving them up in the GUI.
local check_stale_pruning = function()
  local net = network()
  local stale_name = name_of(refs.d)
  local unit_number = refs.d.unit_number
  local flying_text = net[stale_name].flying_text

  refs.d.destroy{raise_destroy = false}
  check(net[stale_name], "destroying without raising should have left the stale entry behind")

  -- A save from a version before a table existed comes back without it, and every lookup
  -- against it would then error.
  state().recent = nil
  state().to_be_removed = nil

  teleporters.on_configuration_changed()

  check(type(state().recent) == "table", "a missing 'recent' table was not restored on a configuration change")
  check(type(state().to_be_removed) == "table", "a missing 'to_be_removed' table was not restored on a configuration change")
  refs.expected_count = refs.expected_count - 1

  check(net[stale_name] == nil, "the stale network entry survived a configuration change")
  check(state().teleporter_map[unit_number] == nil, "the stale unit number entry survived a configuration change")
  check(not flying_text.valid, "the stale flying text was not destroyed")
  check_eq(table_size(net), refs.expected_count, "network size after pruning")
  check_eq(table_size(state().teleporter_map), refs.expected_count, "unit number map size after pruning")
  check_eq(table_size(state().tag_map), refs.expected_count, "tag map size after pruning")

  -- Everything still standing must have come back with a fresh, matching text and tag.
  for name, data in pairs(net) do
    check(data.teleporter and data.teleporter.valid, "entry '" .. name .. "' survived pruning without an entity")
    check(data.flying_text and data.flying_text.valid, "entry '" .. name .. "' has no flying text after a resync")
    check(data.tag and data.tag.valid, "entry '" .. name .. "' has no map tag after a resync")
    check_eq(data.name, name, "the stored name on '" .. name .. "' after a resync")
    check_eq(data.tag.text, name, "the map tag text on '" .. name .. "' after a resync")
  end

  log("SELF_TEST: a configuration change pruned the stale teleporter and resynced the rest")
end

-- 2.1 stopped accepting the lenient modifier spellings in key_sequence, which made the hotkey
-- prototype fail to load with "unknown key_sequence" at startup.
local check_hotkey_prototype = function()
  local prototype = prototypes.custom_input[names.hotkeys.focus_search]
  check(prototype, "the focus search custom input prototype is missing")
  check_eq(prototype.linked_game_control, "focus-search", "the custom input's linked game control")
  check_eq(prototype.key_sequence, "", "the custom input's key sequence")
  log("SELF_TEST: the search hotkey is linked to the game control with no explicit key sequence")
end

-- Teleporting between surfaces is the whole point of the mod, and a teleporter being mined out
-- from under a player has to hand the player back their character. Both need teleporters that
-- have had time to arm, so they get built well before the phases that use them.
local prepare_extra_teleporters = function()
  local second = game.create_surface("teleporter-test-surface")
  second.request_to_generate_chunks({0, 0}, 3)
  second.force_generate_chunk_requests()
  -- A map tag can only be placed on a charted chunk, and the mod gives every teleporter one.
  refs.force.chart(second, {{-64, -64}, {64, 64}})
  refs.second_surface = second

  refs.f = build(second, refs.force, {0, 0}, true)
  refs.g = build(refs.surface, refs.force, {-32, 0}, true)
  refs.expected_count = refs.expected_count + 2

  local net = network()
  check_eq(table_size(net), refs.expected_count, "network size after building on a second surface")
  local f_data = net[name_of(refs.f)]
  check(f_data.tag and f_data.tag.valid, "the teleporter on the second surface got no map tag")
  check_eq(f_data.tag.surface.index, second.index, "the surface the second surface's map tag is on")
  check(f_data.flying_text and f_data.flying_text.valid, "the teleporter on the second surface got no flying text")

  log("SELF_TEST: built teleporters on a second surface and back on nauvis")
end

local step_onto_source_again = function()
  check_eq(refs.a.status, defines.entity_status.armed, "the source teleporter's status on the way back")
  refs.player.character.teleport(refs.a.position)
end

local teleport_across_surfaces = function()
  local player = refs.player
  check(state().player_linked_teleporter[player.index], "stepping back onto the teleporter did not link the player")
  check_eq(player.surface.index, refs.surface.index, "the surface the player starts on")
  click(find_teleport_button(player.index, name_of(refs.f)), player.index)
end

local check_teleported_across_surfaces = function()
  local player = refs.player
  check_eq(player.surface.index, refs.second_surface.index, "the surface the player ended up on")

  local target = refs.f.position
  local distance = ((player.position.x - target.x) ^ 2 + (player.position.y - target.y) ^ 2) ^ 0.5
  check(distance < 1, string.format("the player landed %.2f tiles from the teleporter on the other surface", distance))

  check(state().player_linked_teleporter[player.index] == nil, "the player is still linked after a cross-surface teleport")
  check_eq(refs.a.disabled_by_script, false, "the source teleporter after a cross-surface teleport")
  check_eq(player.character.disabled_by_script, false, "the character after a cross-surface teleport")
  check(player.character.surface.index == refs.second_surface.index, "the character followed the player across surfaces")
  check(refs.f.timeout > 0, "the cross-surface destination was not disarmed on arrival")

  -- Head back to nauvis, clear of everything, for the removal test.
  player.teleport({0, -12}, refs.surface)

  log(string.format("SELF_TEST: teleported across surfaces, landing within %.2f tiles", distance))
end

local step_onto_doomed_teleporter = function()
  check_eq(refs.player.surface.index, refs.surface.index, "the surface the player returned to")
  check_eq(refs.g.status, defines.entity_status.armed, "the doomed teleporter's status before stepping on it")
  refs.player.character.teleport(refs.g.position)
end

-- Mining the pad someone is standing on must not leave them frozen in place with a dead GUI.
local remove_teleporter_under_player = function()
  local player = refs.player
  check(state().player_linked_teleporter[player.index], "the player never got linked to the doomed teleporter")
  check_eq(player.character.disabled_by_script, true, "the character being frozen before the teleporter is removed")
  refs.doomed_name = name_of(refs.g)
  refs.g.destroy{raise_destroy = true}
  refs.expected_count = refs.expected_count - 1
end

local check_freed_after_removal = function()
  local player = refs.player
  check(state().player_linked_teleporter[player.index] == nil,
    "the player is still linked to a teleporter that was removed under them")
  check_eq(player.character.disabled_by_script, false,
    "the character was left frozen after the teleporter under it was removed")
  check(not (state().teleporter_frames[player.index] and state().teleporter_frames[player.index].valid),
    "the GUI stayed open after the teleporter under the player was removed")
  check(network()[refs.doomed_name] == nil, "the removed teleporter is still in the network")
  check_eq(table_size(network()), refs.expected_count, "network size after removing the teleporter under the player")

  log("SELF_TEST: mining the teleporter under a player freed them and closed the GUI")
end

local phases =
{
  [90] = {name = "registration", run = check_registration},
  [120] = {name = "default_name_collision", run = check_default_name_collision},
  [150] = {name = "tag_rename", run = check_tag_rename},
  [180] = {name = "duplicate_name_rejected", run = check_duplicate_name_rejected},
  [195] = {name = "rename_rejection_does_not_recurse", run = check_rename_rejection_does_not_recurse},
  [210] = {name = "fake_tag_rejected", run = check_fake_tag_rejected},
  [240] = {name = "tag_icon_protected", run = check_tag_icon_protected},
  [270] = {name = "tag_removal_resync", run = check_tag_removal_resync},
  -- The teleporters are built at tick 60 and arm 300 ticks later, so nothing can step on one
  -- before tick 360.
  [420] = {name = "step_onto_teleporter", run = step_onto_teleporter},
  [450] = {name = "linked", run = check_linked},
  [480] = {name = "search_filter", run = check_search_filter},
  [510] = {name = "gui_rename", run = check_gui_rename},
  [540] = {name = "teleport", run = do_teleport},
  [570] = {name = "teleported", run = check_teleported},
  -- Well past the destination's 300 tick re-arm, to prove stepping away really did free them.
  [900] = {name = "no_immediate_relink", run = check_no_immediate_relink},
  [930] = {name = "removal", run = check_removal},
  [960] = {name = "stale_pruning", run = check_stale_pruning},
  [990] = {name = "hotkey_prototype", run = check_hotkey_prototype},
  -- Built here so both have run down their 300 tick arming timeout by the phases that use them.
  [1020] = {name = "prepare_extra_teleporters", run = prepare_extra_teleporters},
  [1050] = {name = "step_onto_source_again", run = step_onto_source_again},
  [1080] = {name = "teleport_across_surfaces", run = teleport_across_surfaces},
  [1110] = {name = "teleported_across_surfaces", run = check_teleported_across_surfaces},
  [1380] = {name = "step_onto_doomed_teleporter", run = step_onto_doomed_teleporter},
  [1410] = {name = "remove_teleporter_under_player", run = remove_teleporter_under_player},
  [1440] = {name = "freed_after_removal", run = check_freed_after_removal},
}

local last_phase_tick = 1440
local phase_failures = {}

local tick_handler = function(event)
  local tick = event.tick

  if tick == 60 then
    local ok, result = xpcall(setup, debug.traceback)
    setup_ok = ok
    if ok then
      refs = result
    else
      log("SELF_TEST_RESULT: SETUP_FAIL - " .. tostring(result))
      game.print("SELF_TEST_RESULT: SETUP_FAIL - " .. tostring(result))
    end
    return
  end

  if not setup_ok then return end

  local phase = phases[tick]
  if phase then
    local ok, err = xpcall(phase.run, debug.traceback)
    if not ok then
      phase_failures[#phase_failures + 1] = phase.name
      log("SELF_TEST: PHASE_FAIL " .. phase.name .. " - " .. tostring(err))
      game.print("SELF_TEST: PHASE_FAIL " .. phase.name .. " - " .. tostring(err))
    end
  end

  if tick == last_phase_tick + 30 then
    local total = table_size(phases)
    if #phase_failures == 0 then
      local msg = string.format("PASS - all %d checks passed", total)
      log("SELF_TEST_RESULT: " .. msg)
      game.print("SELF_TEST_RESULT: " .. msg)
    else
      local msg = string.format("FAIL - %d of %d checks failed (%s)",
        #phase_failures, total, table.concat(phase_failures, ", "))
      log("SELF_TEST_RESULT: " .. msg)
      game.print("SELF_TEST_RESULT: " .. msg)
    end
  end
end

self_test.events =
{
  [defines.events.on_tick] = tick_handler
}

return self_test

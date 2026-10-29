-- mob_arena v7: PvP arena waves with two region modes + piggy-bank rewards.
-- v7 (06.09): owner LEAVES the region -> arena STOPS (waves + owned mobs +
-- markers cleaned, bank burns). Fixes: death -> respawn outside arena made
-- waves spawn/leash around the player far from the circle. Next-wave timer
-- also refuses to restart when the owner is outside the region.
--
-- Mode A (persistent, admin): place GOLD BLOCK at corner A, DIAMOND BLOCK at
-- corner B (sneak+place, server priv). Box region, survives restarts.
-- Mode B (quick, anyone): /arena with no marked box -> circle of
-- mob_arena.radius blocks around the player. Center is FIXED at /arena time
-- (does not follow the player) so containment stays meaningful.
--
-- Commands:
--   /arena <type> [count]  — start wave series in region (auto-next waves)
--   /arena_stop            — stop waves, remove owned mobs
--   /arena_show            — (re)sync the boundary markers now
--   /arena_info            — region + wave status
--   /arena_off             — (admin) clear box region
-- v6 reward economy (piggy bank): each completed wave adds
-- mob_arena.reward_emeralds to the session bank; the bank is paid out ONLY
-- after the FINAL wave (mob_arena.waves_total, default 3); dying during the
-- arena resets the bank to 0 (the run continues — survivors can rebuild it);
-- /arena_stop or disconnect forfeits it. Kills give XP orb only.
-- Boundary is marked CONTINUOUSLY while active: box -> gold pillars +
-- diamond top; circle -> glowing bedrock ring (permanent particle
-- spawners, cleaned on stop / player leave / box clear).

local REWARD_EMERALDS = tonumber(core.settings:get("mob_arena.reward_emeralds")) or 1
local MAX_COUNT       = math.max(1, tonumber(core.settings:get("mob_arena.max_count")) or 12)
local WAVE_PAUSE      = math.max(5, tonumber(core.settings:get("mob_arena.wave_pause")) or 12)
local WAVES_TOTAL     = math.max(1, math.min(12, tonumber(core.settings:get("mob_arena.waves_total")) or 3))
local MAX_SIDE        = tonumber(core.settings:get("mob_arena.max_side")) or 48
local RADIUS          = math.min(30, math.max(6, tonumber(core.settings:get("mob_arena.radius")) or 20))
-- v7: how far beyond the boundary the owner may wander before the arena is
-- stopped (blocks). Small slack so grazing the marker line doesn't abort.
local OWNER_SLACK     = math.max(2, math.min(30, tonumber(core.settings:get("mob_arena.owner_slack")) or 6))
-- circle-mode leash for MOBS: they may follow the owner at (r + LEASH);
-- the OWNER himself gets only OWNER_SLACK beyond the boundary (v7).
local LEASH           = 15

local CORNER_A = "mcl_core:goldblock"
local CORNER_B = "mcl_core:diamondblock"

local TYPES = {
	easy   = { "mobs_mc:zombie" },
	normal = { "mobs_mc:zombie", "mobs_mc:skeleton", "mobs_mc:spider" },
	hard   = { "mobs_mc:zombie", "mobs_mc:skeleton", "mobs_mc:spider",
	           "mobs_mc:pillager", "mobs_mc:husk", "mobs_mc:creeper" },
	zombie = { "mobs_mc:zombie" }, skeleton = { "mobs_mc:skeleton" },
	spider = { "mobs_mc:spider" }, creeper = { "mobs_mc:creeper" },
	pillager = { "mobs_mc:pillager" }, witch = { "mobs_mc:witch" },
	husk = { "mobs_mc:husk" }, stray = { "mobs_mc:stray" },
	drowned = { "mobs_mc:drowned" }, silverfish = { "mobs_mc:silverfish" },
	enderman = { "mobs_mc:enderman" }, slime = { "mobs_mc:slime_big" },
}

local store = core.get_mod_storage()
local waves = {}       -- owner -> {count,killed,wave_no,base,sid,pool,reg,total}
local purse = {}       -- owner -> banked emeralds; non-nil == active session
local sid_seq = 0

-- ---------------------------------------------------------------- regions
-- region = {kind="box", minx,maxx,minz,maxz,y0,y1}
--        | {kind="circle", cx,cz,cy,r,y0,y1}

local function box_from_corners(a, b)
	local r = {
		kind = "box",
		minx = math.min(a.x, b.x), maxx = math.max(a.x, b.x),
		minz = math.min(a.z, b.z), maxz = math.max(a.z, b.z),
	}
	r.y0 = math.min(a.y, b.y)
	r.y1 = r.y0 + 16
	return r
end

local function circle_region(pos, rad)
	local p = pos
	return {
		kind = "circle",
		cx = p.x, cz = p.z, cy = math.floor(p.y), r = rad,
		y0 = math.floor(p.y) - 1, y1 = math.floor(p.y) + 17,
	}
end

local function in_region(reg, p, m)
	m = m or 0
	if p.y < reg.y0 - m or p.y > reg.y1 + m then return false end
	if reg.kind == "box" then
		return p.x >= reg.minx - m and p.x <= reg.maxx + 1 + m
			and p.z >= reg.minz - m and p.z <= reg.maxz + 1 + m
	else
		local dx, dz = p.x - reg.cx, p.z - reg.cz
		return dx * dx + dz * dz <= (reg.r + m) * (reg.r + m)
	end
end

-- v7: owner-side boundary test (with slack). Owner outside => arena stops.
local function owner_in_region(reg, p, slack)
	if reg.kind == "box" then
		return in_region(reg, p, slack)
	end
	local dx, dz = p.x - reg.cx, p.z - reg.cz
	return dx * dx + dz * dz <= (reg.r + slack) * (reg.r + slack)
		and p.y >= reg.y0 - slack and p.y <= reg.y1 + slack
end

local function region_center(reg)
	if reg.kind == "box" then
		return vector.new((reg.minx + reg.maxx + 1) / 2, reg.y0 + 2,
			(reg.minz + reg.maxz + 1) / 2)
	end
	return vector.new(reg.cx, reg.cy + 2, reg.cz)
end

local function region_obj_radius(reg)
	if reg.kind == "box" then
		local dx, dz = reg.maxx - reg.minx + 1, reg.maxz - reg.minz + 1
		return math.sqrt(dx * dx + dz * dz) / 2 + 24
	end
	return reg.r + 24
end

local function region_desc(reg)
	if reg.kind == "box" then
		return string.format("%dx%d@y%d", reg.maxx - reg.minx + 1,
			reg.maxz - reg.minz + 1, reg.y0)
	end
	return string.format("круг r=%d@y%d", reg.r, reg.cy)
end

-- ------------------------------------------------------- boundary markers
-- One-shot burst (used for /arena_show pulse).
local function burst(x, y, z)
	core.add_particlespawner({
		amount = 2, time = 0.6,
		minpos = { x = x - 0.4, y = y, z = z - 0.4 },
		maxpos = { x = x + 0.4, y = y + 1.2, z = z + 0.4 },
		minvel = { x = 0, y = 0.5, z = 0 },
		maxvel = { x = 0, y = 1.5, z = 0 },
		minexptime = 0.5, maxexptime = 1.2,
		minsize = 1, maxsize = 2,
		node = "mcl_core:goldblock", node_tile = 1,
		glow = 5,
	})
end

local function boundary_points(reg)
	local pts = {}
	if reg.kind == "box" then
		local corners = {
			{ reg.minx + 0.5, reg.minz + 0.5 },
			{ reg.maxx + 1.5, reg.minz + 0.5 },
			{ reg.maxx + 1.5, reg.maxz + 1.5 },
			{ reg.minx + 0.5, reg.maxz + 1.5 },
		}
		for i = 1, 4 do
			local a, b = corners[i], corners[i % 4 + 1]
			local dist = math.max(math.abs(b.x - a.x), math.abs(b.z - a.z))
			local n = math.max(3, math.floor(dist / 3))
			for k = 0, n do
				local t = k / n
				pts[#pts + 1] = { x = a.x + (b.x - a.x) * t, y = reg.y0 + 0.3,
				                  z = a.z + (b.z - a.z) * t }
			end
		end
	else
		local n = math.max(20, math.floor(reg.r * 2.5))
		for k = 0, n - 1 do
			local ang = (k / n) * math.pi * 2
			pts[#pts + 1] = { x = reg.cx + math.cos(ang) * reg.r,
			                  y = reg.cy + 0.3, z = reg.cz + math.sin(ang) * reg.r }
		end
	end
	return pts
end

local function flash_region(reg)
	for _, p in ipairs(boundary_points(reg)) do
		burst(p.x, p.y, p.z)
	end
end

-- Persistent markers: keyed by owner ("__box__" for the admin box).
-- Each spawner has static_tiles (glowing node cubes standing at fixed
-- positions along the boundary) + a small rising-dust spawner region;
-- time=0 => never expires, cleaned explicitly via
-- core.delete_particlespawner(id).
local markers = {}         -- key -> {ids = {...}}
local clear_markers  -- fwd

-- Continuous boundary marker: node-tile cubes (proven pattern from burst() —
-- no texture-availability assumptions), time=0 => respawns forever until
-- core.delete_particlespawner(id). Low velocity + 1.2-2.4s lifetime = glowing
-- shimmer of cubes pinned to the boundary point.
local function spawn_spawner(tile, x, y, z)
	return core.add_particlespawner({
		amount = 1, time = 0,
		minpos = { x = x - 0.1, y = y, z = z - 0.1 },
		maxpos = { x = x + 0.1, y = y + 0.25, z = z + 0.1 },
		minvel = { x = 0, y = 0, z = 0 },
		maxvel = { x = 0, y = 0.15, z = 0 },
		minacc = { x = 0, y = 0, z = 0 },
		maxacc = { x = 0, y = 0, z = 0 },
		minexptime = 1.2, maxexptime = 2.4,
		minsize = 0.7, maxsize = 0.9,
		node = tile, node_tile = 1,
		glow = 8,
	})
end

local function set_markers(key, reg, tile)
	clear_markers(key)
	local ids = {}
	for _, p in ipairs(boundary_points(reg)) do
		ids[#ids + 1] = spawn_spawner(tile, p.x, p.y, p.z)
	end
	markers[key] = { ids = ids }
end

clear_markers = function(key)
	local m = markers[key]
	if not m then return end
	for _, id in ipairs(m.ids) do
		if id then pcall(core.delete_particlespawner, id) end
	end
	markers[key] = nil
end

-- box region persisted in mod_storage (admin marker mode)
local box_corners -- {c1,c2}

local function save_box()
	if box_corners then
		store:set_string("arena", core.serialize(box_corners))
	else
		store:set_string("arena", "")
	end
end

local box_reg -- cached region from box_corners
local function set_box(corners)
	box_corners = corners
	box_reg = corners and box_from_corners(corners.c1, corners.c2)
	save_box()
end

do
	local s = store:get_string("arena")
	if s and s ~= "" then
		local ok, d = pcall(core.deserialize, s)
		if ok and d and d.c1 and d.c2 then set_box(d) end
	end
end
local function notify_all(msg, owner)
	for _, p in ipairs(core.get_connected_players()) do
		if p:get_player_name() ~= owner then
			core.chat_send_player(p:get_player_name(), msg)
		end
	end
end
local function try_set_corner(player, key, pos)
	box_corners = box_corners or {}
	box_corners[key] = { x = pos.x, y = pos.y, z = pos.z }
	if not (box_corners.c1 and box_corners.c2) then
		local need = box_corners.c1 and "алмазный блок в угол B" or "золотой блок в угол A"
		core.chat_send_player(player:get_player_name(),
			"⚔ Арена: помечен один угол. Доспавай " .. need .. " (sneak+place).")
		return
	end
	local reg = box_from_corners(box_corners.c1, box_corners.c2)
	local sx, sz = reg.maxx - reg.minx + 1, reg.maxz - reg.minz + 1
	if sx > MAX_SIDE or sz > MAX_SIDE or sx < 6 or sz < 6 then
		core.chat_send_player(player:get_player_name(),
			string.format("⚔ Арена %dx%d — не годится (сторона 6..%d). Переставь углы.", sx, sz, MAX_SIDE))
		return
	end
	set_box(box_corners)
	set_markers("__box__", box_reg, "mcl_core:goldblock")
	flash_region(box_reg)
	core.chat_send_player(player:get_player_name(),
		string.format("⚔ Арена задана: %s. Волны спавнятся внутри, сбежавшие мобы удаляются.",
			region_desc(box_reg)))
end

core.register_on_mods_loaded(function()
	for key, nodename in pairs({ c1 = CORNER_A, c2 = CORNER_B }) do
		local def = core.registered_nodes[nodename]
		if def then
			local prev = def.after_place_node
			def.after_place_node = function(pos, placer, stack, pt)
				if prev then prev(pos, placer, stack, pt) end
				if placer and placer:is_player() and placer:check_privilege("server") then
					local ctrl = placer:get_player_control()
					if ctrl and ctrl.sneak then
						try_set_corner(placer, key, pos)
					end
				end
			end
		else
			core.log("warning", "[mob_arena] marker node missing: " .. nodename)
		end
	end
	print(string.format(
		"[MOD] mob_arena v7 loaded: bank +%d/wave, payout after %d waves, death=reset, LEAVE region=stop+burn, max=%d, pause=%ds, radius=%d, owner_slack=%d, box=%s",
		REWARD_EMERALDS, WAVES_TOTAL, MAX_COUNT, WAVE_PAUSE, RADIUS, OWNER_SLACK,
		box_reg and region_desc(box_reg) or "not set"))
end)

core.register_on_dignode(function(pos, node, digger)
	if not box_corners then return end
	local hit = (node.name == CORNER_A and box_corners.c1
			and pos.x == box_corners.c1.x and pos.z == box_corners.c1.z and pos.y == box_corners.c1.y)
		or (node.name == CORNER_B and box_corners.c2
			and pos.x == box_corners.c2.x and pos.z == box_corners.c2.z and pos.y == box_corners.c2.y)
	if hit then
		set_box(nil)
		clear_markers("__box__")
		notify_all("⚔_box-арена снята (маркер сломан). Быстрые круговые арены работают всегда.")
	end
end)
-- ---------------------------------------------------------------- rewards
local function give_emeralds(player, n, reason_text)
	if not player or not player:is_player() then return end
	local inv = player:get_inventory()
	local leftover = inv:add_item("main", ItemStack("mcl_core:emerald " .. n))
	if leftover:get_count() > 0 then
		core.add_item(player:get_pos(), leftover)
	end
	core.chat_send_player(player:get_player_name(),
		string.format("* моб-арена: +%d изумруда! %s", n, reason_text))
end

local function reward_kill(killer, owner)
	if not killer or not killer:is_player() then return end
	if core.get_modpath("mcl_experience") then
		mcl_experience.throw_xp(killer:get_pos(), math.random(5, 12))
	end
end

local wave_consumed -- fwd
local do_start_wave -- fwd

wave_consumed = function(owner)
	local wave = waves[owner]
	if not wave then return end
	wave.killed = wave.killed + 1
	core.log("action", string.format("[mob_arena] %s wave %d kill %d/%d",
		owner, wave.wave_no, wave.killed, wave.count))
	if wave.killed < wave.count then return end
	local op = core.get_player_by_name(owner)
	waves[owner] = nil
	if not op then clear_markers(owner) purse[owner] = nil return end
	if not wave.no_reward then
		purse[owner] = (purse[owner] or 0) + REWARD_EMERALDS
	end
	local total = wave.total or WAVES_TOTAL
	if wave.wave_no >= total then
		-- FINAL wave: pay out the bank, session over
		local bank = purse[owner] or 0
		purse[owner] = nil
		if wave.reg and wave.reg.kind == "circle" then clear_markers(owner) end
		if bank > 0 then
			give_emeralds(op, bank, string.format("Все %d волн зачищены!", total))
		else
			core.chat_send_player(op, string.format(
				"⚔ Все %d волн зачищены, но копилка пуста (гибель обнулила). Без изумрудов.", total))
		end
		return
	end
	local next_no = wave.wave_no + 1
	local next_count = math.min(MAX_COUNT, wave.base + next_no - 1)
	core.chat_send_player(owner, string.format(
		"⚔ Волна %d %s Копилка: %d. Передышка %d с... волна %d/%d: %d мобов",
		wave.wave_no,
		wave.no_reward and "зачищена, но обнулена смертью!" or "зачищена!",
		purse[owner] or 0, WAVE_PAUSE, next_no, total, next_count))
	local sid = wave.sid
	local reg = wave.reg
	local pool = wave.pool
	core.after(WAVE_PAUSE, function()
		if waves[owner] ~= nil or wave.sid ~= sid_seq then return end
		local p = core.get_player_by_name(owner)
		if not p then clear_markers(owner) purse[owner] = nil return end
		-- v7: owner must be back INSIDE the region when the timer fires,
		-- otherwise the series ends here and the bank burns.
		if not owner_in_region(reg, p:get_pos(), OWNER_SLACK) then
			local bank = purse[owner] or 0
			purse[owner] = nil
			clear_markers(owner)
			core.chat_send_player(owner, string.format(
				"⚔ Ты вне арены (%s) — волна %d отменена. Арена остановлена, копилка сгорела: %d.",
				region_desc(reg), next_no, bank))
			core.log("action", string.format(
				"[mob_arena] %s stopped: outside region at next-wave timer (bank %d burned)", owner, bank))
			return
		end
		waves[owner] = { count = 0, killed = 0, wave_no = next_no,
		                 base = wave.base, sid = sid, pool = pool, reg = reg, total = total }
		do_start_wave(owner, pool, next_count)
	end)
end

-- v6: death during an active session burns the bank (run continues)
core.register_on_dieplayer(function(player)
	local name = player:get_player_name()
	if purse[name] then
		local lost = purse[name]
		purse[name] = 0
		local w = waves[name]
		if w then w.no_reward = true end -- current wave is forfeited too
		core.chat_send_player(name,
			string.format("☠ Гибель на арене! Копилка сгорела: было %d, теперь 0. Эта волна тоже без награды — но волны продолжаются, заработай заново!", lost))
		core.log("action", "[mob_arena] " .. name .. " died: bank reset (was " .. lost .. ")")
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	if purse[name] then
		purse[name] = nil
		clear_markers(name)
	end
end)

local function reward_and_count(killer, owner)
	reward_kill(killer, owner)
	wave_consumed(owner)
end

-- v7: hard stop of an active arena — waves, owned mobs, markers all go away,
-- bank burns (message is sent to the owner). Shared by the /arena_stop
-- command and the globalstep owner-outside check.
local function stop_arena(owner, msg)
	local w = waves[owner]
	waves[owner] = nil -- block pending after() timers
	local bank = purse[owner] or 0
	purse[owner] = nil
	clear_markers(owner)
	local reg = w and w.reg
	local c = reg and region_center(reg) or nil
	if c then
		for _, obj in ipairs(core.get_objects_inside_radius(c, region_obj_radius(reg) + 16)) do
			local ent = obj:get_luaentity()
			if ent and ent._arena_owner == owner then obj:remove() end
		end
	end
	local op = core.get_player_by_name(owner)
	if op and msg then core.chat_send_player(owner, msg) end
	core.log("action", string.format("[mob_arena] %s arena stopped (bank %d burned)", owner, bank))
end
core.register_on_mods_loaded(function()
	local mc = rawget(mcl_mobs, "mob_class")
	if not mc or not mc.on_punch then
		core.log("warning", "[mob_arena] could not patch mcl_mobs.mob_class.on_punch")
		return
	end
	local orig = mc.on_punch
	mc.on_punch = function(self, hitter, ...)
		local res = orig(self, hitter, ...)
		if self._arena_owner and not self._arena_rewarded
				and (self.dead or (self.health or 1) <= 0) then
			self._arena_rewarded = true
			local killer = (hitter and hitter:is_player()) and hitter
				or core.get_player_by_name(self._arena_owner)
			reward_and_count(killer, self._arena_owner)
		end
		return res
	end
end)

-- ---------------------------------------------------------------- spawning
local function players_min_dist(pos)
	local best = math.huge
	for _, p in ipairs(core.get_connected_players()) do
		best = math.min(best, vector.distance(pos, p:get_pos()))
	end
	return best
end

-- find floor under/at column (x,z) around scan_y; returns standing pos or nil
local function floor_at(x, z, scan_y)
	for y = scan_y + 3, scan_y - 6, -1 do
		local n1 = core.get_node({ x = x, y = y, z = z })
		local d1 = core.registered_nodes[n1.name]
		if d1 and d1.walkable and not d1.buildable_to then
			local n2 = core.get_node({ x = x, y = y + 1, z = z })
			local d2 = core.registered_nodes[n2.name]
			local n3 = core.get_node({ x = x, y = y + 2, z = z })
			local d3 = core.registered_nodes[n3.name]
			if d2 and d2.buildable_to and d3 and d3.buildable_to then
				return { x = x + 0.5, y = y + 1, z = z + 0.5 }
			end
			return nil
		end
	end
	return nil
end

local MAX_SPAWN_DIST = 9 -- spawn band around the owner: mobs must be findable
local function region_spawn_pos(reg, origin)
	for bi = 1, 2 do
		local maxd = MAX_SPAWN_DIST * bi
		for _ = 1, 30 do
			local x, z
			local ang = math.random() * math.pi * 2
			local rr = 3 + math.sqrt(math.random()) * (maxd - 3)
			if reg.kind == "box" then
				x = math.floor(origin.x + math.cos(ang) * rr)
				z = math.floor(origin.z + math.sin(ang) * rr)
			else
				x = math.floor(reg.cx + math.cos(ang) * rr)
				z = math.floor(reg.cz + math.sin(ang) * rr)
			end
			local pos = floor_at(x, z, origin.y)
			if pos and vector.distance(pos, origin) >= 3
					and (reg.kind == "circle" or in_region(reg, pos, 0))
					and players_min_dist(pos) >= 3 then
				return pos
			end
		end
	end
	return nil
end

-- remove wild mobs inside region before a wave (isolation)
local function clear_wild_in_region(reg)
	local removed = 0
	for _, obj in ipairs(core.get_objects_inside_radius(
			region_center(reg), region_obj_radius(reg))) do
		local ent = obj:get_luaentity()
		if ent and not ent._arena_owner and ent.type == "mob" then
			local p = obj:get_pos()
			if in_region(reg, p, 0) then
				obj:remove()
				removed = removed + 1
			end
		end
	end
	return removed
end

do_start_wave = function(owner, pool_name, count)
	local pool = TYPES[pool_name]
	local wave = waves[owner]
	if not wave then return end
	local sd = core.serialize({ persist_in_peaceful = true })
	local op0 = core.get_player_by_name(owner)
	if not op0 then waves[owner] = nil return end
	local origin = op0:get_pos()
	-- v7: spawn anchor = region center (NOT the player). The player only
	-- picks the region at /arena time; dying/respawning outside must not
	-- drag the spawn anchor along with him.
	local anchor = region_center(wave.reg)
	wave.origin = origin -- kept for diagnostics
	local spawned = 0
	local spawned_names = {}
	wave.mobs = {} -- v6.2 watchdog refs {ent=, obj=}
	for _ = 1, count do
		local mname = pool[math.random(#pool)]
		local pos = region_spawn_pos(wave.reg, anchor)
		if not pos then
			-- v7: fallback is the region center, never the player's feet —
			-- a wave must never teleport itself to an owner standing outside.
			pos = floor_at(math.floor(anchor.x), math.floor(anchor.z), math.floor(anchor.y))
		end
		if pos then
		local obj = core.add_entity(pos, mname, sd)
		if obj then
			local ent = obj:get_luaentity()
			if ent then
				ent._arena_owner = owner
				ent.nametag = "⚔ " .. owner
				ent:update_tag()
				wave.mobs[#wave.mobs + 1] = { ent = ent, obj = obj }
			end
			spawned = spawned + 1
			spawned_names[#spawned_names + 1] =
				mname:gsub("mobs_mc:", "") .. string.format("@(%.0f,%.0f,%.0f)", pos.x, pos.y, pos.z)
			end
		end
	end
	-- stdout trail: greppable proof of who spawned where (debug aid)
	print(string.format("[mob_arena] %s wave %d: %s", owner, wave.wave_no,
		table.concat(spawned_names, " ")))
	wave.count = wave.count + spawned
	if spawned == 0 then
		waves[owner] = nil
		core.log("action", string.format("[mob_arena] %s wave %d: SPAWN FAILED (0/%d)", owner, wave.wave_no, count))
		local op = core.get_player_by_name(owner)
		if op then core.chat_send_player(owner, "⚔ Не удалось заспавнить мобов (рельеф?)") end
		return false
	end
	flash_region(wave.reg)
	if wave.reg.kind == "circle" then
		set_markers(owner, wave.reg, "mcl_core:bedrock")
	end
	notify_all(string.format("⚔ %s: волна %d — %d мобов (%s)!",
		owner, wave.wave_no, wave.count, region_desc(wave.reg)), owner)
	return true
end
core.register_chatcommand("arena", {
	params = "<easy|normal|hard|zombie|...> [кол-во [волн]]",
	description = "Волны мобов: в box-арене (углы) или кругом вокруг тебя",
	func = function(name, param)
		core.log("action", "[mob_arena] /arena invoked by " .. name .. " param='" .. param .. "'")
		-- NB: Luanti's String:split splits by LITERAL separator (pattern off by
		-- default) — ":split('%s')" was the v3.2 silent-fail root cause.
		-- LuaJIT quirk: exhausted gmatch iterator returns NO values (not nil),
		-- so tonumber(it()) crashes with "value expected" -> collect tokens first.
		local args = {}
		for w in param:gmatch("%S+") do args[#args + 1] = w end
		local key = (args[1] or ""):lower()
		local count = math.min(MAX_COUNT, math.max(1, tonumber(args[2]) or 3))
		local total = math.max(1, math.min(12, tonumber(args[3]) or WAVES_TOTAL))
		local pool = TYPES[key]
		if not pool then
			local names = {}
			for k in pairs(TYPES) do names[#names + 1] = k end
			table.sort(names)
			core.log("action", "[mob_arena] /arena bad type '" .. key .. "'")
			return false, "Тип: " .. table.concat(names, ", ")
				.. " + кол-во (1-" .. MAX_COUNT .. "). Отмена: /arena_stop"
		end
		local player = core.get_player_by_name(name)
		if not player then return false, "нужно быть в игре" end
		if waves[name] then
			core.log("action", "[mob_arena] /arena rejected: wave in progress for " .. name)
			return false, string.format("Волна уже идёт: %d/%d. /arena_stop чтобы отменить.",
				waves[name].killed, waves[name].count)
		end
		local reg = box_reg
		if not reg then
			-- quick mode: circle around the player, fixed here and now
			reg = circle_region(player:get_pos(), RADIUS)
		elseif not owner_in_region(reg, player:get_pos(), OWNER_SLACK) then
			-- v7: box mode — starting from outside makes no sense; the
			-- containment step would stop the arena one second later.
			return false, "Ты вне box-арены (" .. region_desc(reg) .. "). Зайди внутрь и запусти /arena."
		end
		local wilds = clear_wild_in_region(reg)
		sid_seq = sid_seq + 1
		purse[name] = 0
		waves[name] = { count = 0, killed = 0, wave_no = 1, base = count,
			            sid = sid_seq, pool = key, reg = reg, total = total }
		local ok = do_start_wave(name, key, count)
		if not ok then return false, "спавн не удался" end
		return true, string.format(
			"⚔ Волна 1: %d мобов (%s, %s%s). Копилка: +%d за волну, волн всего: %d — выдача после последней. Смерть = 0. Авто-волны каждые %d с. Стоп: /arena_stop",
			count, key, region_desc(reg),
			wilds > 0 and string.format(", зачищено диких: %d", wilds) or "",
			REWARD_EMERALDS, total, WAVE_PAUSE) ..
			". Ищи мобов с ⚔ над головой рядом (до 9 блоков)."
	end,
})

core.register_chatcommand("arena_stop", {
	description = "Остановить волны, убрать своих мобов",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, "нужно быть в игре" end
		local lost = purse[name] or 0
		stop_arena(name, nil)
		return true, "Волны остановлены" ..
			(lost > 0 and string.format(". Копилка сгорела: %d", lost) or "")
	end,
})

core.register_chatcommand("arena_show", {
	description = "Показать границы арены (box или круг радиуса арены у тебя)",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, "нужно быть в игре" end
		local w = waves[name]
		local reg = box_reg or (w and w.reg)
			or circle_region(player:get_pos(), RADIUS)
		flash_region(reg)
		return true, "Границы: " .. region_desc(reg)
	end,
})

core.register_chatcommand("arena_info", {
	description = "Инфо по арене и текущей волне",
	func = function(name)
		local w = waves[name]
		local parts = {}
		if box_reg then parts[#parts + 1] = "box-арена: " .. region_desc(box_reg) end
		if w then
			parts[#parts + 1] = string.format("волна %d/%d: %d/%d зачищено, копилка %d (%s)",
				w.wave_no, w.total or WAVES_TOTAL, w.killed, w.count, purse[name] or 0, region_desc(w.reg))
		end
		if #parts == 0 then
			return true, string.format(
				"Box-арены нет — /arena создаст круг r=%d вокруг тебя. Или пометь углы: золото + алмаз (sneak+place).", RADIUS)
		end
		return true, table.concat(parts, ". ")
	end,
})

core.register_chatcommand("arena_off", {
	params = "", description = "(admin) снять box-регион арены",
	func = function(name)
		local p = core.get_player_by_name(name)
		if not p or not p:check_privilege("server") then return false, "нужны права админа" end
		set_box(nil)
		clear_markers("__box__")
		notify_all("⚔ Box-регион арены снят админом.")
		return true, "регион снят; маркеры-блоки можно забрать"
	end,
})

-- ---------------------------------------------------------------- containment
-- box region: strict static walls (that's what marking corners means).
-- circle region: dynamic leash — the arena follows the owner with slack
-- (r + LEASH); the owner himself only gets OWNER_SLACK beyond the boundary,
-- stepping out stops the arena (v7).
local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < 1 then return end
	acc = 0
	for owner, wave in pairs(waves) do
		-- v6.2 watchdog: deaths outside on_punch (creeper boom, fire, fall,
		-- despawn) never hit the punch counter -> without this sweep the
		-- counter stalls below wave.count and the next wave never starts.
		if wave.mobs then
			local i = 1
			while i <= #wave.mobs and waves[owner] do
				local e = wave.mobs[i]
				local gone = e.ent.removed -- mcl_mobs safe_remove (creeper boom, ...)
				if not gone then
					-- methods on removed objects error -> pcall probes existence
					local ok = pcall(function() return e.obj:get_pos() end)
					gone = not ok
				end
				if e.ent._arena_rewarded then
					table.remove(wave.mobs, i)
				elseif gone then
					e.ent._arena_rewarded = true
					table.remove(wave.mobs, i)
					core.log("action", "[mob_arena] " .. owner .. ": wave mob gone without punch (explode/despawn?), counting as kill")
					wave_consumed(owner)
				else
					i = i + 1
				end
			end
		end
		local reg = wave.reg
		local op = core.get_player_by_name(owner)
		if not op then
			-- owner left: clean up their mobs (otherwise orphaned waves roam free)
			for _, obj in ipairs(core.get_objects_inside_radius(
					region_center(reg), region_obj_radius(reg))) do
				local ent = obj:get_luaentity()
				if ent and ent._arena_owner == owner then obj:remove() end
			end
			waves[owner] = nil
			clear_markers(owner)
		else
			-- v7: owner stepped outside the region -> STOP the whole arena
			-- (waves, owned mobs, markers); the bank burns. This is the fix
			-- for "died, respawned outside, waves followed me around".
			if not owner_in_region(reg, op:get_pos(), OWNER_SLACK) then
				local bank = purse[owner] or 0
				stop_arena(owner, string.format(
					"⚔ Ты покинул арену (%s) — волны остановлены, мобы убраны, копилка сгорела: %d. Зайди внутрь и начни заново: /arena",
					region_desc(reg), bank))
			else
			local center = region_center(reg)
			local esc = 0
			for _, obj in ipairs(core.get_objects_inside_radius(
					center, region_obj_radius(reg) + LEASH)) do
				local ent = obj:get_luaentity()
				if ent and ent._arena_owner == owner and not ent._arena_rewarded then
					local out
					if reg.kind == "circle" then
						local d = vector.distance(obj:get_pos(), center)
						out = d > reg.r + LEASH or math.abs(obj:get_pos().y - reg.cy) > 18
					else
						out = not in_region(reg, obj:get_pos(), 0.5)
					end
					if out then
						ent._arena_rewarded = true -- no reward on escape
						obj:remove()
						esc = esc + 1
					end
				end
			end
			-- v6.2: each escaped mob counts as one toward the wave total
			-- (one call per mob, not one per sweep tick); stop if the wave
			-- already completed mid-loop so leftovers never leak into wave N+1.
			for _ = 1, esc do
				if waves[owner] ~= wave then break end
				wave_consumed(owner)
			end
			end
		end
	end
end)

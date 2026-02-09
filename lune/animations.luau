--!strict
--[[
@UpliftKainoa 

This tooling utilizes asphalt to bulk upload animations to Roblox. Do note a couple of things:
    1. To upload an animation, save out a .rbxm of keyframe sequences (or a single keyframe sequence).
        * The tooling here will iterate through children of the .rbxm and upload each keyframe sequence.
        * Note that exporting a KeyframeSequence AS a .rbxm will also work (single animations)
    2. The keyframe sequences you are uploading should be in their final form, meaning:
        * If you are uploading multiple sequences underneath a pet:
            * Pet MUST be completely run through pipeline tooling.
            * Animations are in their final states (gameplay attachments configured, etc.)

To use:
    1. Use asphalt_group.toml (rename to asphalt.toml/and rename current active asphalt.toml)
    2. Place animation .rbxm files under /assets/
    3. Run `lune run animations` to upload the animations to Roblox.
    4. A module will be generated in the root of the project called `generated_animations.luau`.
        * This module will contain a map of obfuscated animation names to their asset ids.
        * This module will also contain a map of obfuscated animation names to their original names.

UUID Generated using Roblox's method, taken from Wikipedia and inspired by a few implementations online. (https://en.wikipedia.org/wiki/Universally_unique_identifier#Version_4_(random))
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local process = require("@lune/process")
local datetime = require("@lune/datetime")

local ROOT_FOLDER = "assets"
local TMP_DIR = ".asphalt_tmp_uuid"
local OUT_MODULE = "generated_animations.luau"

type Dict<K, V> = { [K]: V }

local function basename(p: string): string
	local s, e = p:find("([^/]+)$")
	return s and p:sub(s, e) or p
end
local function extname(p: string): string
	local b = basename(p)
	local i = b:match("()%.%w+$")
	return i and b:sub(i) or ""
end
local function stem(p: string): string
	local b = basename(p)
	local i = b:match("()%.%w+$")
	return i and b:sub(1, i - 1) or b
end
local function join(a: string, b: string): string
	if a == "" then return b end
	if a:sub(-1) == "/" then return a .. b end
	return a .. "/" .. b
end

local function split_path(p: string): {string}
	local parts = {}
	for part in string.gmatch(p, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

local function mkdirp_manual(dir: string)
	if dir == "" or dir == "." then return end
	local parts = split_path(dir)
	local acc = ""
	for i = 1, #parts do
		acc = (acc == "") and parts[i] or (acc .. "/" .. parts[i])
		pcall(function() fs.mkdir(acc) end)
	end
end

local function ensure_parent_dir(file_path: string)
	local last = 0
	for i = 1, #file_path do
		if file_path:sub(i, i) == "/" then last = i end
	end
	if last > 0 then
		local dir = file_path:sub(1, last - 1)
		if #dir > 0 then mkdirp_manual(dir) end
	end
end

local function read_dir_safe(path: string): {string}?
	local ok, entries = pcall(function() return fs.readDir(path) end)
	if ok then return entries end
	return nil
end

local function remove_safe(path: string)
	pcall(function() fs.remove(path, true) end)
end

local HEX = "0123456789abcdef"
local function rand_hex(n: number): string
	local s = table.create(n)
	for i = 1, n do
		local k = math.random(1, 16)
		s[i] = HEX:sub(k, k)
	end
	return table.concat(s)
end
local function generate_uuid_v4(): string
	local function y()
		local v = { 8, 9, 10, 11 }
		local k = v[math.random(1, 4)] + 1
		return HEX:sub(k, k)
	end
	local parts = {
		rand_hex(8),
		rand_hex(4),
		"4" .. rand_hex(3),
		y() .. rand_hex(3),
		rand_hex(12),
	}
	return table.concat(parts, "-")
end

local function list_animation_files(): { string }
	local entries = read_dir_safe(ROOT_FOLDER)
	if not entries then return {} end
	local out: { string } = {}
	for _, name in ipairs(entries) do
		local p = join(ROOT_FOLDER, name)
		if fs.isFile(p) then
			local ext = extname(p):lower()
			if ext == ".rbxm" or ext == ".rbxmx" then
				table.insert(out, p)
			end
		end
	end
	return out
end

local function read_asphalt_toml(): any
	local raw = fs.readFile("asphalt.toml")
	return serde.decode("toml", raw)
end

local function build_temp_asphalt_toml(creator: any, path_glob: string): string
	local lines = {
		"[creator]",
		string.format('type = "%s"', tostring(creator.type)),
		string.format("id = %s", tostring(creator.id)),
	}
	if creator.api_key ~= nil then
		table.insert(lines, string.format('api_key = "%s"', tostring(creator.api_key)))
	end
	table.insert(lines, "")
	table.insert(lines, "[inputs.animations]")
	table.insert(lines, string.format('path = "%s"', path_glob))
	table.insert(lines, 'output_path = ".asphalt_codegen_ignored"')
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

local function parse_lockfile(): Dict<string, number>
	local map: Dict<string, number> = {}
	local ok, lock = pcall(function() return fs.readFile("asphalt.lock.toml") end)
	if not ok then return map end
	for block in (lock :: string):gmatch("%[%[assets%]%][^%[]*") do
		local path_val = block:match('path%s*=%s*"([^"]+)"')
		local id_val = block:match("id%s*=%s*(%d+)")
		if path_val and id_val then
			map[basename(path_val)] = tonumber(id_val) :: number
		end
	end
	return map
end

local function read_codegen_mapping(): Dict<string, string>
	local ok, mod = pcall(function()
		return require("../.asphalt_codegen_ignored/animations") :: any
	end)
	if ok and type(mod) == "table" then
		return (mod :: any) :: Dict<string, string>
	end
	return {}
end

local function parse_rbxassetid(value: string): number?
	local id = tostring(value):match("rbxassetid://(%d+)")
	return id and tonumber(id) or nil
end

local function build_obf_to_id_from_codegen(): Dict<string, number>
	local out: Dict<string, number> = {}
	local codegen = read_codegen_mapping()
	for obf, url in pairs(codegen) do
		local id = parse_rbxassetid(url)
		if id then
			out[obf] = id
		end
	end
	return out
end

local function get_timestamp_filename(): string
	local now = datetime.now()
	return now:formatLocalTime("%Y-%m-%d_%H-%M-%S", "en")
end

local function collect_keyframe_sequences_from(modelRoots: { Instance }): { Instance }
	local sequences: { Instance } = {}

	local function walk(inst: Instance)
		if (inst :: any).ClassName == "KeyframeSequence" then
			table.insert(sequences, inst)
		end
		for _, child in (inst :: any):GetChildren() do
			walk(child)
		end
	end

	for _, root in modelRoots do
		walk(root)
	end

	return sequences
end

local function export_keyframes_bundle(originals: { string })
	local container = roblox.Instance.new("Folder")
	container.Name = "Animations"

	for _, src in ipairs(originals) do
		local ok, instances = pcall(function()
			return roblox.deserializeModel(fs.readFile(src))
		end)
		if ok and type(instances) == "table" then
			local seqs = collect_keyframe_sequences_from(instances :: any)
			if #seqs > 0 then
				for _, seq in ipairs(seqs) do
					local copy = (seq :: any):Clone()
					copy.Name = (seq :: any).Name
					copy.Parent = container
				end
			end
		else
			print("[warn]\tFailed to read or parse " .. src)
		end
	end

	local outName = "Animations_" .. get_timestamp_filename() .. ".rbxm"
	local outPath = join("output", outName)
	ensure_parent_dir(outPath)
	fs.writeFile(outPath, roblox.serializeModel({ container }))
	print("Wrote keyframe bundle to " .. outPath)
end

-- split an input .rbxm/.rbxmx into multiple files, one per KeyframeSequence
local function sanitize_filename(s: string): string
	-- prevent path traversal and remove characters that can confuse tools
	s = s:gsub("[\\/]+", "_")
	s = s:gsub("[\r\n\t]", " ")
	return s
end

local function split_model_into_sequences(src: string): { [string]: string }
	local outputs: { [string]: string } = {}
	local ok, instances = pcall(function()
		return roblox.deserializeModel(fs.readFile(src))
	end)
	if not ok or type(instances) ~= "table" then
		return outputs
	end

	local seqs = collect_keyframe_sequences_from(instances :: any)
	local prefix = stem(src)

	local used: Dict<string, number> = {}

	for _, seq in ipairs(seqs) do
		local seqName = sanitize_filename((seq :: any).Name)
		local baseName = prefix .. seqName
		local finalName = baseName .. ".rbxm"
		if used[finalName] then
			used[finalName] += 1
			finalName = string.format("%s_%d.rbxm", baseName, used[finalName])
		else
			used[finalName] = 1
		end

		local copy = (seq :: any):Clone()
		copy.Name = (seq :: any).Name
		local content = roblox.serializeModel({ copy })
		outputs[finalName] = content
	end

	return outputs
end

-- now we write our generated module
local function write_generated_module(obf_to_orig: Dict<string, string>, obf_to_id: Dict<string, number>)
	local lines = {}
	table.insert(lines, "--!strict")
	table.insert(lines, "-- Auto-generated by animations uploader")
	table.insert(lines, "type AnimMap = {[string]: string}")
	table.insert(lines, "local animations: AnimMap = {}")

	for obf, orig in pairs(obf_to_orig) do
		local id = obf_to_id[obf]
		if id then
			table.insert(lines, string.format('animations[%q] = "rbxassetid://%d"', stem(orig), id))
		else
			print("[warn]\tMissing asset id for " .. obf .. " (orig " .. orig .. ")")
		end
	end

	table.insert(lines, "return animations\n")
	fs.writeFile(OUT_MODULE, table.concat(lines, "\n"))
end

local function upload_asphalt()
	-- add some rng jitter (for the UUIDs)
	local jitter = tonumber(tostring(os.time()):reverse():sub(1, 6)) or os.time()
	math.randomseed(jitter)

	-- read asphalt.toml and api key
	local asphalt = read_asphalt_toml()
	local creator = asphalt.creator
	assert(creator, "No [creator] in asphalt.toml")
	local api_key = creator.api_key
	if not api_key then
		error("No api-key provided!")
	end

	-- collect animations
	local originals = list_animation_files()
	if #originals == 0 then
		error("No .rbxm/.rbxmx found in '" .. ROOT_FOLDER .. "'")
	end

	-- rebuild temp dir
	remove_safe(TMP_DIR)
	mkdirp_manual(TMP_DIR)

	-- copy with UUID filenames using only readFile/writeFile
	local obf_to_orig: Dict<string, string> = {}
	for _, src in ipairs(originals) do
		local splits = split_model_into_sequences(src)
		if next(splits) == nil then
			-- fallback: no sequences found, upload whole file
			local uuid = generate_uuid_v4()
			local obfname = "anim_" .. uuid .. extname(src):lower()
			local dst = join(TMP_DIR, obfname)
			local content = fs.readFile(src)
			ensure_parent_dir(dst)
			fs.writeFile(dst, content)
			obf_to_orig[obfname] = basename(src)
		else
			for filename, content in pairs(splits) do
				local uuid = generate_uuid_v4()
				local obfname = "anim_" .. uuid .. ".rbxm"
				local dst = join(TMP_DIR, obfname)
				ensure_parent_dir(dst)
				fs.writeFile(dst, content)
				obf_to_orig[obfname] = filename
			end
		end
	end

	-- backup original asphalt.toml, write temporary one, run, restore
	local original_toml_raw = fs.readFile("asphalt.toml")
	fs.writeFile("asphalt.toml.bak", original_toml_raw)

	local temp_toml = build_temp_asphalt_toml(creator, TMP_DIR .. "/**/*")
	fs.writeFile("asphalt.toml", temp_toml)

	local result = process.spawn("asphalt", {
		"sync",
		"--target", "cloud",
		"--api-key", api_key,
	})

	-- restore original regardless of outcome
	fs.writeFile("asphalt.toml", original_toml_raw)
	remove_safe("asphalt.toml.bak")

	if result.ok then
		if result.stdout and #result.stdout > 0 then print(result.stdout) end
		if result.stderr and #result.stderr > 0 then print(result.stderr) end
		print("Asphalt successfully ran")
	else
		error(result.stderr)
	end

	-- lock -> ids -> module
	local obf_to_id = build_obf_to_id_from_codegen()
	if next(obf_to_id) == nil then
		obf_to_id = parse_lockfile()
	end
	write_generated_module(obf_to_orig, obf_to_id)

	-- also export all keyframe sequences into a single .rbxm (in case it's needed, i've needed this a few times)
	export_keyframes_bundle(originals)
end

assert(fs.isFile("asphalt.toml"), "No asphalt.toml found.")
upload_asphalt()

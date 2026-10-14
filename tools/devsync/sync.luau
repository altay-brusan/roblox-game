-- Paste into Studio's command bar (Edit mode) while server.js is running.
-- Pulls every changed script from LastSignal/src into the open place.
local Http = game:GetService("HttpService")
Http.HttpEnabled = true
local base = "http://127.0.0.1:34900"
local manifest = Http:JSONDecode(Http:GetAsync(base .. "/manifest"))
local changed = {}
for _, e in manifest do
	local segs = string.split(e.path, "/")
	local node: Instance = game:GetService(segs[1])
	for i = 2, #segs do
		local child = node:FindFirstChild(segs[i])
		local wantClass = if i == #segs then e.className else "Folder"
		if child and i == #segs and child.ClassName ~= e.className then
			child:Destroy()
			child = nil
		end
		if not child then
			child = Instance.new(wantClass)
			child.Name = segs[i]
			child.Parent = node
		end
		node = child
	end
	if node:GetAttribute("DevSyncHash") ~= e.hash then
		local target: any = node
		target.Source = Http:GetAsync(base .. "/source?path=" .. Http:UrlEncode(e.path))
		node:SetAttribute("DevSyncHash", e.hash)
		table.insert(changed, e.path)
	end
end
return string.format("%d scripts, %d updated: %s", #manifest, #changed, table.concat(changed, ", "))

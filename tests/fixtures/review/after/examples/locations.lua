local waypoint = require("waypoint")

waypoint.add("lua/waypoint/init.lua", "Saved locations")
waypoint.add("lua/waypoint/storage.lua", "Persistence")

vim.print(waypoint.list())

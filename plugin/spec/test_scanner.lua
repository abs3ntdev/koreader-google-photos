local T = require("support")
local Scanner = require("gphotos/scanner")

T.test("scanner: keeps regular images, skips symlinks/hidden/unsupported/empty", function()
    local lfs = T.fake_lfs({
        ["/shots"] = { mode = "directory" },
        ["/shots/b.png"] = { mode = "file", size = 10, modification = 5 },
        ["/shots/a.JPG"] = { mode = "file", size = 20, modification = 6 },
        ["/shots/link.png"] = { mode = "link", target = "/etc/secret.png" },
        ["/shots/.hidden.png"] = { mode = "file", size = 1 },
        ["/shots/notes.txt"] = { mode = "file", size = 5 },
        ["/shots/empty.png"] = { mode = "file", size = 0 },
        ["/shots/sub"] = { mode = "directory" },
    })
    local files, skipped = Scanner.scan(lfs, "/shots/")
    T.eq(#files, 2); T.eq(files[1].name, "a.JPG"); T.eq(files[2].name, "b.png")
    T.eq(skipped, 4)
    T.eq(files[2].key, "/shots/b.png|10|5")
end)

T.test("scanner: refuses symlinked folder", function()
    local lfs = T.fake_lfs({ ["/l"] = { mode = "link" } })
    T.eq(Scanner.scan(lfs, "/l"), nil)
end)

T.test("scanner.single: exact file only; rejects symlink, hidden, unsupported, symlinked parent", function()
    local lfs = T.fake_lfs({
        ["/shots"] = { mode = "directory" },
        ["/shots/a.png"] = { mode = "file", size = 10, modification = 5 },
        ["/shots/b.png"] = { mode = "file", size = 11, modification = 5 },
        ["/shots/link.png"] = { mode = "link", target = "/shots/a.png" },
        ["/shots/.h.png"] = { mode = "file", size = 1 },
        ["/shots/n.txt"] = { mode = "file", size = 1 },
        ["/l"] = { mode = "link", target = "/shots" },
    })
    local files = Scanner.single(lfs, "/shots/a.png")
    T.eq(#files, 1); T.eq(files[1].key, "/shots/a.png|10|5")
    for _, bad in ipairs({ "/shots/link.png", "/shots/.h.png", "/shots/n.txt", "/shots/missing.png", "/l/a.png", "a.png" }) do
        T.eq(Scanner.single(lfs, bad), nil, bad)
    end
end)

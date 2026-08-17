-- End-to-end resumable full-book download tests: an interrupted job keeps its
-- progress, a restarted download skips finished chapters, retries the failed
-- one, verifies integrity, and clears the checkpoint after the EPUB is built.
-- Run from the repo root with:
--   luajit spec/downloader_resume_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        preventStandby = function() end,
        allowStandby = function() end,
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        show = function() end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/time"] = function()
    return { now = function() return 1000 end }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weread.lib.thoughts"] = function()
    return { is_download_enabled = function() return false end }
end
package.preload["weread.lib.footnotes"] = function()
    return {
        scan_chapter = function() return { refs = {}, definitions = {} } end,
        build_book_index = function() return {} end,
        transform_chapter = function(html)
            return html, { candidates = 0, converted = 0 }
        end,
        validate = function() return true end,
        has_converted = function() return false end,
        FOOTNOTES_CSS = "",
    }
end
package.preload["weread.lib.protocol"] = function()
    return {
        normalize_cover_url = function(value) return value end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
    }
end
package.preload["weread.ui.download_dialog"] = function()
    return {
        new = function(_self, options)
            return {
                options = options,
                show = function() end,
                close = function() end,
                setTitle = function() end,
                reportProgress = function() end,
            }
        end,
    }
end

-- Fake JSON and SQLite so the real DownloadQueue module runs in-process.
local encoded, next_payload = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            next_payload = next_payload + 1
            local key = "payload-" .. next_payload
            encoded[key] = value
            return key
        end,
        decode = function(value) return encoded[value] end,
    }
end

local fs_files = { ["/data/weread"] = true }
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path) return fs_files[path] and "file" or nil end,
        mkdir = function(path) fs_files[path] = true; return true end,
    }
end

local databases = {}
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path)
            fs_files[path] = true
            databases[path] = databases[path] or { jobs = {}, chapters = {} }
            local data = databases[path]
            local db = {}
            db.exec = function() end
            db.close = function() end
            db.prepare = function(_db, sql)
                local stmt = { sql = sql, args = {} }
                stmt.reset = function(current)
                    current.args = {}
                    current.rows = nil
                    current.row_index = 0
                    return current
                end
                stmt.bind = function(current, ...)
                    current.args = { ... }
                    return current
                end
                stmt.step = function(current)
                    local a = current.args
                    if current.sql:find("SELECT payload FROM jobs", 1, true) then
                        local payload = data.jobs[a[1]]
                        return payload and { payload } or nil
                    end
                    if current.sql:find("INSERT OR REPLACE INTO jobs", 1, true) then
                        data.jobs[a[1]] = a[2]
                        return nil
                    end
                    if current.sql:find("DELETE FROM jobs", 1, true) then
                        data.jobs[a[1]] = nil
                        return nil
                    end
                    if current.sql:find("DELETE FROM chapters", 1, true) then
                        for key, row in pairs(data.chapters) do
                            if row.book_id == a[1] then
                                data.chapters[key] = nil
                            end
                        end
                        return nil
                    end
                    if current.sql:find("INSERT OR REPLACE INTO chapters", 1, true) then
                        local key = a[1] .. "|" .. tostring(a[2])
                        if #a == 4 then
                            data.chapters[key] = {
                                book_id = a[1], position = a[2],
                                chapter_uid = a[3], title = a[4],
                                status = "pending", attempts = 0,
                            }
                        else
                            data.chapters[key] = {
                                book_id = a[1], position = a[2],
                                chapter_uid = a[3], title = a[4],
                                status = a[5], attempts = a[6],
                                last_error = a[7], body_path = a[8],
                                payload = a[9],
                            }
                        end
                        return nil
                    end
                    if current.sql:find("AND position=?", 1, true) then
                        local row = data.chapters[a[1] .. "|" .. tostring(a[2])]
                        return row and {
                            row.chapter_uid, row.title, row.status, row.attempts,
                            row.last_error, row.body_path, row.payload,
                        } or nil
                    end
                    if current.sql:find("ORDER BY position", 1, true) then
                        if not current.rows then
                            current.rows = {}
                            for _key, row in pairs(data.chapters) do
                                if row.book_id == a[1] then
                                    current.rows[#current.rows + 1] = {
                                        row.position, row.chapter_uid, row.title,
                                        row.status, row.attempts, row.last_error,
                                        row.body_path, row.payload,
                                    }
                                end
                            end
                            table.sort(current.rows, function(left, right)
                                return left[1] < right[1]
                            end)
                        end
                        current.row_index = current.row_index + 1
                        return current.rows[current.row_index]
                    end
                    return nil
                end
                stmt.close = function() end
                return stmt
            end
            return db
        end,
    }
end

-- Fake Content: chapter 22 fails its source fetch while `chapter22_fails`.
-- Queue bodies are written to a real temp directory because the downloader
-- checks body-file existence with plain io.open.
local spec_tmp = "/tmp/weread_resume_spec_tmp"
os.execute("rm -rf " .. spec_tmp .. " && mkdir -p " .. spec_tmp)
local chapter22_fails = true
local fetch_counts = {}
local body_files = {}
local saved_epubs = {}
local queue_cleanups = 0
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        book_resolved_dir = function() return spec_tmp .. "/book1" end,
        fetch_single_chapter_source = function(_client, _settings, _book, chapter)
            local uid = tostring(chapter.chapterUid)
            fetch_counts[uid] = (fetch_counts[uid] or 0) + 1
            if uid == "22" and chapter22_fails then
                error("injected network failure")
            end
            return "<p>body " .. uid .. "</p>"
        end,
        finalize_single_chapter_content = function(_client, _settings, _book,
                chapter, xhtml)
            return xhtml, {}
        end,
        write_queue_body = function(body_dir, uid, xhtml)
            os.execute("mkdir -p " .. string.format("%q", body_dir))
            local path = string.format("%s/chapter-%s.xhtml", body_dir, uid)
            local file = assert(io.open(path, "wb"))
            file:write(xhtml)
            file:close()
            body_files[path] = xhtml
            return path
        end,
        read_queue_body = function(path)
            local file = io.open(path, "rb")
            if not file then
                error("queued chapter body missing: " .. tostring(path))
            end
            local data = file:read("*a")
            file:close()
            return data
        end,
        cleanup_download_queue = function()
            queue_cleanups = queue_cleanups + 1
            return true
        end,
        cleanup_download_workspace = function() return true end,
        save_book_epub = function(_settings, _book, chapters, bodies, suffix,
                _assets, _css, _cover, files)
            saved_epubs[#saved_epubs + 1] = {
                chapters = chapters,
                bodies = bodies,
                suffix = suffix,
                body_files = files,
            }
            return spec_tmp .. "/book1/book-full.epub"
        end,
    }
end

local DownloadQueue = require("weread.lib.download_queue")
local Downloader = require("weread.lib.downloader")

local chapters = {
    { chapterUid = 11, title = "One" },
    { chapterUid = 22, title = "Two" },
    { chapterUid = 33, title = "Three" },
}

local function run_scheduled()
    while #scheduled > 0 do
        local callback = table.remove(scheduled, 1)
        callback()
    end
end

local function new_downloader(completions, messages)
    local stored_books = {}
    return Downloader:new{
        client = {},
        settings = {
            data_dir = "/data/weread",
            get = function(_self, key)
                if key == "books" then return stored_books end
                if key == "cache" then return { download_book_images = false } end
                return nil
            end,
            set = function(_self, key, value)
                if key == "books" then stored_books = value end
            end,
            flush = function() end,
        },
        download_queue = DownloadQueue:new({ data_dir = "/data/weread" }),
        require_login = function() return true end,
        run_online_task = function(_label, fn) fn() return true end,
        run_background_task = function(fn) fn() return true end,
        show_info = function(text) messages[#messages + 1] = text end,
        show_transient = function() end,
        refresh_ui = function() end,
        refresh_shelf = function() end,
        open_file = function() end,
        safe_callback = function(_label, fn) return fn end,
    }, stored_books
end

-- Run 1: chapter 22 fails permanently; the job must stay resumable.
local completions, messages = {}, {}
local downloader = new_downloader(completions, messages)
local book = { book_id = "book1", title = "Book" }
local started = downloader:start(book, chapters, "full", {
    on_complete = function(ok, value)
        completions[#completions + 1] = { ok, value }
    end,
})
expect(started == true, "full-book download did not start")
run_scheduled()

expect(#completions == 1, "run 1 completion count was wrong")
expect(completions[1][1] == false
    and completions[1][2] == "incomplete_full_book",
    "run 1 must report an incomplete full book")
expect(#saved_epubs == 0, "incomplete run must not build an EPUB")
local job = DownloadQueue:new({ data_dir = "/data/weread" }):loadJob("book1")
expect(job ~= nil, "interrupted job was not persisted")
expect(job.chapters[1].status == "done" and job.chapters[3].status == "done",
    "finished chapters were not checkpointed")
expect(job.chapters[2].status == "failed",
    "failed chapter was not marked")
expect(body_files[job.chapters[1].body_path] == "<p>body 11</p>",
    "chapter 11 body was not persisted on disk")
expect(messages[#messages]:find("Start the download again to resume", 1, true)
    ~= nil, "resume hint was not shown to the user")

-- Run 2 ("process restart"): chapter 22 recovers; only it is fetched again.
chapter22_fails = false
fetch_counts = {}
completions, messages = {}, {}
downloader = new_downloader(completions, messages)
started = downloader:start({ book_id = "book1", title = "Book" }, chapters,
    "full", {
        on_complete = function(ok, value)
            completions[#completions + 1] = { ok, value }
        end,
    })
expect(started == true, "resumed download did not start")
run_scheduled()

expect(#completions == 1 and completions[1][1] == true,
    "resumed download did not complete")
expect(fetch_counts["11"] == nil and fetch_counts["33"] == nil,
    "finished chapters were downloaded again")
expect(fetch_counts["22"] == 1,
    "failed chapter was not retried exactly once")
expect(#saved_epubs == 1, "resumed run did not build the EPUB")
local saved = saved_epubs[1]
expect(#saved.chapters == 3, "EPUB chapter count was wrong")
expect(saved.chapters[1].chapterUid == 11
    and saved.chapters[2].chapterUid == 22
    and saved.chapters[3].chapterUid == 33,
    "EPUB chapters were not in catalog order")
expect(saved.body_files ~= nil
    and saved.body_files["11"] ~= nil
    and saved.body_files["22"] ~= nil
    and saved.body_files["33"] ~= nil,
    "EPUB was not built from on-disk chapter bodies")
expect(next(saved.bodies) == nil,
    "queue mode must not accumulate chapter bodies in memory")
expect(queue_cleanups == 1, "queue staging directory was not cleaned up")
expect(DownloadQueue:new({ data_dir = "/data/weread" }):loadJob("book1") == nil,
    "completed job was not cleared")

print(("downloader_resume_spec: %d checks passed"):format(checks))

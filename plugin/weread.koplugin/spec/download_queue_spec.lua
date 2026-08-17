-- Tests for the resumable full-book download queue state machine.
-- Run from the repo root with:
--   luajit spec/download_queue_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

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

local files = { ["/data/weread"] = true }
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path) return files[path] and "file" or nil end,
        mkdir = function(path) files[path] = true; return true end,
    }
end

-- Minimal in-memory SQ3 fake covering exactly the statements used by
-- weread/lib/download_queue.lua.
local databases = {}
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function(path)
            files[path] = true
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

local DownloadQueue = require("weread.lib.download_queue")

local settings = { data_dir = "/data/weread" }
local queue = DownloadQueue:new(settings)

local catalog = {
    { chapterUid = 11, title = "One" },
    { chapterUid = 22, title = "Two" },
    { chapterUid = 33, title = "Three" },
}

-- Fresh job creation and read-back.
expect(queue:loadJob("book-a") == nil, "unexpected job before creation")
expect(queue:createJob("book-a", { suffix = "full", css = "body{}" }, catalog),
    "job creation failed")
local job = queue:loadJob("book-a")
expect(job and job.book_id == "book-a", "job was not persisted")
expect(job.css == "body{}", "job css was not persisted")
expect(#job.chapters == 3, "queued chapter count was wrong")
expect(job.chapters[2].chapter_uid == "22"
    and job.chapters[2].status == "pending"
    and job.chapters[2].attempts == 0,
    "queued chapter initial state was wrong")

-- Chapter completion persists body path and asset metadata.
expect(queue:markChapterDone("book-a", 1, "/cache/book-a/.weread-queue/bodies/chapter-11.xhtml",
    { { href = "images/a.png", media_type = "image/png", size = 10 } }),
    "markChapterDone failed")
job = queue:loadJob("book-a")
expect(job.chapters[1].status == "done", "chapter 1 was not marked done")
expect(job.chapters[1].body_path:find("chapter%-11%.xhtml$") ~= nil,
    "chapter 1 body path was not persisted")
expect(job.chapters[1].assets
    and job.chapters[1].assets[1].href == "images/a.png",
    "chapter 1 assets were not persisted")

-- Retry attempts accumulate; terminal failure is explicit.
expect(queue:recordChapterAttempt("book-a", 2, "timeout"), "attempt 1 failed")
expect(queue:recordChapterAttempt("book-a", 2, "timeout"), "attempt 2 failed")
expect(queue:markChapterFailed("book-a", 2, "timeout"), "markChapterFailed failed")
job = queue:loadJob("book-a")
expect(job.chapters[2].status == "failed"
    and job.chapters[2].attempts == 2
    and job.chapters[2].last_error == "timeout",
    "failed chapter state was wrong")
local counts = DownloadQueue.chapterCounts(job.chapters)
expect(counts.total == 3 and counts.done == 1
    and counts.failed == 1 and counts.pending == 1,
    "chapter counts were wrong")

-- Manual retry: failed chapters go back to pending with a fresh budget.
expect(queue:resetFailedChapters("book-a") == 1, "failed chapter reset count wrong")
job = queue:loadJob("book-a")
expect(job.chapters[2].status == "pending" and job.chapters[2].attempts == 0,
    "failed chapter was not reset to pending")

-- A done chapter whose body vanished is re-downloaded.
expect(queue:resetChapterToPending("book-a", 1), "resetChapterToPending failed")
job = queue:loadJob("book-a")
expect(job.chapters[1].status == "pending" and job.chapters[1].body_path == nil,
    "done chapter was not reset")
expect(queue:markChapterDone("book-a", 1, "/cache/book-a/.weread-queue/bodies/chapter-11.xhtml"),
    "re-done failed")

-- Job metadata merges (CSS grows while chapters finish).
expect(queue:saveJobMeta("book-a", { css = "body{}p{}", used_asset_names = { ["a.png"] = true } }),
    "saveJobMeta failed")
job = queue:loadJob("book-a")
expect(job.css == "body{}p{}", "merged css was not persisted")
expect(job.used_asset_names and job.used_asset_names["a.png"] == true,
    "asset name registry was not persisted")

-- plan_resume: matching catalog splits chapters by state.
expect(queue:markChapterFailed("book-a", 2, "timeout"), "re-fail failed")
job = queue:loadJob("book-a")
local plan = DownloadQueue.plan_resume(job.chapters, catalog, function(path)
    return path == "/cache/book-a/.weread-queue/bodies/chapter-11.xhtml"
end)
expect(plan ~= nil, "matching catalog did not produce a resume plan")
expect(plan.done[1] ~= nil, "done chapter missing from plan")
expect(#plan.failed == 1 and plan.failed[1] == 2, "failed chapter missing from plan")
expect(#plan.pending == 1 and plan.pending[1] == 3, "pending chapter missing from plan")
expect(#plan.missing == 0, "unexpected missing bodies")

-- plan_resume: a done chapter whose body file is gone must be re-downloaded.
plan = DownloadQueue.plan_resume(job.chapters, catalog, function()
    return false
end)
expect(plan and #plan.missing == 1 and plan.missing[1] == 1,
    "missing body file was not detected")

-- plan_resume: changed catalog rejects the plan (caller starts fresh).
expect(DownloadQueue.plan_resume(job.chapters, {
    { chapterUid = 11 }, { chapterUid = 99 }, { chapterUid = 33 },
}) == nil, "changed catalog must not resume")
expect(DownloadQueue.plan_resume(job.chapters, {
    { chapterUid = 11 }, { chapterUid = 22 },
}) == nil, "shorter catalog must not resume")

-- verify_complete: integrity reconciliation before building the EPUB.
job = queue:loadJob("book-a")
local verified, problem = DownloadQueue.verify_complete(job.chapters, 3, function()
    return true
end)
expect(not verified and type(problem) == "string",
    "incomplete job must fail verification")
expect(queue:resetFailedChapters("book-a") == 1, "second reset failed")
expect(queue:markChapterDone("book-a", 2, "/cache/book-a/.weread-queue/bodies/chapter-22.xhtml"),
    "done 2 failed")
expect(queue:markChapterDone("book-a", 3, "/cache/book-a/.weread-queue/bodies/chapter-33.xhtml"),
    "done 3 failed")
job = queue:loadJob("book-a")
verified = DownloadQueue.verify_complete(job.chapters, 3, function(path)
    return path:find("%.xhtml$") ~= nil
end)
expect(verified, "complete job did not verify")
verified = DownloadQueue.verify_complete(job.chapters, 3, function()
    return false
end)
expect(not verified, "missing body files must fail verification")
verified = DownloadQueue.verify_complete(job.chapters, 2, function()
    return true
end)
expect(not verified, "chapter count mismatch must fail verification")

-- Completion clears the job.
expect(queue:clearJob("book-a"), "clearJob failed")
expect(queue:loadJob("book-a") == nil, "job was not cleared")
expect(queue:clearJob("book-a"), "clearing a missing job must succeed")

print(("download_queue_spec: %d checks passed"):format(checks))

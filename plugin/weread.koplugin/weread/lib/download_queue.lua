-- Resumable full-book download queue (per-chapter checkpointing).
--
-- Full-book downloads on low-end devices run for a long time and are often
-- interrupted (crash, suspend, OOM), which previously discarded all progress.
-- This module checkpoints every finished chapter in SQLite and keeps the
-- finalized chapter bodies on disk, so a restarted download skips completed
-- chapters and only (re)downloads pending or failed ones.
--
-- Storage layout:
--   <data_dir>/download_queue.db      job metadata + per-chapter state
--   <book_dir>/.weread-queue/bodies/  finalized chapter XHTML, one file each
--   <book_dir>/.weread-queue/images/  staged image assets (shared EPUB dir)
--
-- The .weread-queue directory intentionally survives plugin restarts; it is
-- removed only when the job completes or is replaced by a fresh download.
--
-- All public functions are pcall-guarded and report failure through return
-- values instead of raising: a checkpoint-store hiccup must never crash a
-- download, the caller simply falls back to the non-resumable in-memory flow.

local logger = require("weread.lib.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

DownloadQueue.STATUS_PENDING = "pending"
DownloadQueue.STATUS_DONE = "done"
DownloadQueue.STATUS_FAILED = "failed"

local function getSQ3()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    return ok and SQ3 or nil
end

local function encode(value)
    if not ok_json then return nil, "JSON module is not available" end
    local ok, result = pcall(function()
        return json.encode and json.encode(value) or json:encode(value)
    end)
    return ok and result or nil, ok and nil or result
end

local function decode(value)
    if type(value) ~= "string" or value == "" or not ok_json then return nil end
    local ok, result = pcall(function()
        return json.decode and json.decode(value) or json:decode(value)
    end)
    return ok and type(result) == "table" and result or nil
end

local function close_statement(stmt)
    if stmt then pcall(function() stmt:close() end) end
end

-- Nullable text columns are stored as empty strings so statement binds never
-- receive nil (ljsqlite3 bind semantics with trailing/inner nils vary).
local function nonempty(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

function DownloadQueue:new(settings)
    local data_dir = settings and (settings.data_dir or settings.cache_dir) or "."
    return setmetatable({
        settings = settings,
        db_path = data_dir .. "/download_queue.db",
    }, self)
end

--- The on-disk staging directory for one book's resumable download.
function DownloadQueue.queue_dir(book_dir)
    return tostring(book_dir) .. "/.weread-queue"
end

--- True when the SQLite/JSON stack needed for checkpointing is available.
function DownloadQueue.is_available()
    return getSQ3() ~= nil and ok_json == true
end

function DownloadQueue:open(create)
    local SQ3 = getSQ3()
    if not SQ3 then
        return nil, "lua-ljsqlite3 is unavailable"
    end
    local lfs = require("libs/libkoreader-lfs")
    if not create and not lfs.attributes(self.db_path, "mode") then
        return nil
    end
    local dir = self.db_path:match("^(.*)/[^/]+$")
    if dir and not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
    local ok, db = pcall(SQ3.open, self.db_path)
    if not ok or not db then
        return nil, tostring(db or "database open failed")
    end
    local schema_ok, schema_err = pcall(function()
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=NORMAL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS jobs (
                book_id    TEXT PRIMARY KEY,
                payload    TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            ) WITHOUT ROWID
        ]])
        db:exec([[
            CREATE TABLE IF NOT EXISTS chapters (
                book_id     TEXT NOT NULL,
                position    INTEGER NOT NULL,
                chapter_uid TEXT NOT NULL,
                title       TEXT,
                status      TEXT NOT NULL DEFAULT 'pending',
                attempts    INTEGER NOT NULL DEFAULT 0,
                last_error  TEXT,
                body_path   TEXT,
                payload     TEXT,
                PRIMARY KEY (book_id, position)
            ) WITHOUT ROWID
        ]])
    end)
    if not schema_ok then
        pcall(function() db:close() end)
        return nil, tostring(schema_err)
    end
    return db
end

local function read_job_row(db, book_id)
    local stmt
    local payload
    local ok, err = pcall(function()
        stmt = db:prepare("SELECT payload FROM jobs WHERE book_id=?")
        local row = stmt:reset():bind(book_id):step()
        payload = row and row[1] or nil
    end)
    close_statement(stmt)
    if not ok then
        return nil, err
    end
    return payload
end

local function write_job_row(db, book_id, payload)
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare(
            "INSERT OR REPLACE INTO jobs (book_id, payload, updated_at)"
                .. " VALUES (?, ?, ?)")
        stmt:reset():bind(book_id, payload, os.time()):step()
    end)
    close_statement(stmt)
    return ok, err
end

local function read_chapter_rows(db, book_id)
    local stmt
    local rows = {}
    local ok, err = pcall(function()
        stmt = db:prepare([[
            SELECT position, chapter_uid, title, status, attempts,
                   last_error, body_path, payload
            FROM chapters WHERE book_id=? ORDER BY position
        ]])
        local row = stmt:reset():bind(book_id):step()
        while row do
            local extra = decode(row[8]) or {}
            rows[#rows + 1] = {
                position = tonumber(row[1]),
                chapter_uid = tostring(row[2]),
                title = row[3],
                status = tostring(row[4]),
                attempts = tonumber(row[5]) or 0,
                last_error = nonempty(row[6]),
                body_path = nonempty(row[7]),
                assets = type(extra.assets) == "table" and extra.assets or nil,
            }
            row = stmt:step()
        end
    end)
    close_statement(stmt)
    if not ok then
        return nil, err
    end
    return rows
end

--- Load the interrupted job for a book, or nil when none exists.
--- Returns { book_id, css, used_asset_names, chapters = { ... } }.
function DownloadQueue:loadJob(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then return nil end
    local db, open_err = self:open(false)
    if not db then
        if open_err then
            logger.warn("download queue read skipped:", open_err)
        end
        return nil
    end
    local job
    local ok, err = pcall(function()
        local payload = read_job_row(db, book_id)
        if not payload then return end
        local meta = decode(payload)
        if type(meta) ~= "table" then return end
        local chapters = read_chapter_rows(db, book_id)
        if type(chapters) ~= "table" or #chapters == 0 then return end
        job = {
            book_id = book_id,
            suffix = meta.suffix,
            css = meta.css,
            used_asset_names = type(meta.used_asset_names) == "table"
                and meta.used_asset_names or nil,
            chapters = chapters,
        }
    end)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("download queue read failed:", err)
        return nil
    end
    return job
end

--- Start a fresh job, replacing any interrupted one for the same book.
--- chapters: array of catalog chapter tables ({ chapterUid, title, ... }).
function DownloadQueue:createJob(book_id, meta, chapters)
    book_id = tostring(book_id or "")
    if book_id == "" or type(chapters) ~= "table" or #chapters == 0 then
        return false, "book id and chapters are required"
    end
    meta = meta or {}
    local payload, encode_err = encode({
        suffix = meta.suffix,
        css = meta.css,
        used_asset_names = meta.used_asset_names,
    })
    if not payload then return false, tostring(encode_err) end
    local db, open_err = self:open(true)
    if not db then return false, open_err end
    local transaction_open = false
    local stmt
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        local del_stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        del_stmt:reset():bind(book_id):step()
        close_statement(del_stmt)
        assert(write_job_row(db, book_id, payload))
        stmt = db:prepare([[
            INSERT OR REPLACE INTO chapters
                (book_id, position, chapter_uid, title, status, attempts)
            VALUES (?, ?, ?, ?, 'pending', 0)
        ]])
        for position, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or position)
            stmt:reset():bind(book_id, position, uid,
                tostring(chapter.title or "")):step()
        end
        close_statement(stmt)
        stmt = nil
        db:exec("COMMIT")
        transaction_open = false
    end)
    close_statement(stmt)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    if not ok then
        logger.warn("download queue job creation failed:", err)
        return false, tostring(err)
    end
    return true
end

--- Persist job-level metadata that grows during the download (CSS, asset
--- name registry) so a resumed job rebuilds the exact same EPUB inputs.
function DownloadQueue:saveJobMeta(book_id, meta)
    book_id = tostring(book_id or "")
    if book_id == "" or type(meta) ~= "table" then
        return false, "book id and metadata are required"
    end
    local db, open_err = self:open(true)
    if not db then return false, open_err end
    local ok, err = pcall(function()
        local payload = read_job_row(db, book_id)
        if not payload then
            error("no download job for book " .. book_id)
        end
        local merged = decode(payload) or {}
        for key, value in pairs(meta) do
            merged[key] = value
        end
        local encoded = assert(encode(merged))
        assert(write_job_row(db, book_id, encoded))
    end)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("download queue metadata write failed:", err)
        return false, tostring(err)
    end
    return true
end

local function load_chapter_row(db, book_id, position)
    local stmt
    local row_data
    local ok, err = pcall(function()
        stmt = db:prepare([[
            SELECT chapter_uid, title, status, attempts, last_error,
                   body_path, payload
            FROM chapters WHERE book_id=? AND position=?
        ]])
        local row = stmt:reset():bind(book_id, position):step()
        if row then
            row_data = {
                chapter_uid = tostring(row[1]),
                title = row[2],
                status = tostring(row[3]),
                attempts = tonumber(row[4]) or 0,
                last_error = nonempty(row[5]),
                body_path = nonempty(row[6]),
                payload = row[7],
            }
        end
    end)
    close_statement(stmt)
    if not ok then
        return nil, err
    end
    return row_data
end

local function store_chapter_row(db, book_id, position, row)
    local stmt
    local ok, err = pcall(function()
        stmt = db:prepare([[
            INSERT OR REPLACE INTO chapters
                (book_id, position, chapter_uid, title, status, attempts,
                 last_error, body_path, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:reset():bind(book_id, position, row.chapter_uid,
            row.title or "", row.status, row.attempts,
            row.last_error or "", row.body_path or "",
            row.payload or ""):step()
    end)
    close_statement(stmt)
    return ok, err
end

-- Read-modify-write one chapter row. update_fn(row) mutates the decoded row
-- table; keeping the whole row in one statement keeps the SQL surface small.
local function update_chapter(self, book_id, position, update_fn)
    book_id = tostring(book_id or "")
    position = tonumber(position)
    if book_id == "" or not position then
        return false, "book id and chapter position are required"
    end
    local db, open_err = self:open(true)
    if not db then return false, open_err end
    local ok, err = pcall(function()
        local row = load_chapter_row(db, book_id, position)
        if not row then
            error("no queued chapter at position " .. tostring(position))
        end
        update_fn(row)
        assert(store_chapter_row(db, book_id, position, row))
    end)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("download queue chapter update failed:", err)
        return false, tostring(err)
    end
    return true
end

--- Record a finished chapter: body on disk plus its staged asset metadata.
function DownloadQueue:markChapterDone(book_id, position, body_path, assets)
    return update_chapter(self, book_id, position, function(row)
        row.status = DownloadQueue.STATUS_DONE
        row.body_path = body_path
        row.last_error = nil
        local extra = decode(row.payload) or {}
        extra.assets = type(assets) == "table" and assets or {}
        row.payload = encode(extra)
    end)
end

--- Count one failed attempt (the chapter stays pending while retries remain).
function DownloadQueue:recordChapterAttempt(book_id, position, err)
    return update_chapter(self, book_id, position, function(row)
        row.attempts = (tonumber(row.attempts) or 0) + 1
        row.last_error = tostring(err or ""):sub(1, 300)
    end)
end

--- Mark a chapter as failed after its retry budget was exhausted.
function DownloadQueue:markChapterFailed(book_id, position, err)
    return update_chapter(self, book_id, position, function(row)
        row.status = DownloadQueue.STATUS_FAILED
        row.last_error = tostring(err or ""):sub(1, 300)
    end)
end

--- Move one chapter back to pending (e.g. its body file went missing).
function DownloadQueue:resetChapterToPending(book_id, position)
    return update_chapter(self, book_id, position, function(row)
        row.status = DownloadQueue.STATUS_PENDING
        row.body_path = nil
    end)
end

--- Give every failed chapter a fresh retry budget. Returns the reset count.
function DownloadQueue:resetFailedChapters(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then return 0 end
    local db = self:open(true)
    if not db then return 0 end
    local reset = 0
    local ok, err = pcall(function()
        local rows = read_chapter_rows(db, book_id) or {}
        for _i, row in ipairs(rows) do
            if row.status == DownloadQueue.STATUS_FAILED then
                local fresh = load_chapter_row(db, book_id, row.position)
                if fresh then
                    fresh.status = DownloadQueue.STATUS_PENDING
                    fresh.attempts = 0
                    assert(store_chapter_row(db, book_id, row.position, fresh))
                    reset = reset + 1
                end
            end
        end
    end)
    pcall(function() db:close() end)
    if not ok then
        logger.warn("download queue failed-chapter reset failed:", err)
        return 0
    end
    return reset
end

--- Aggregate chapter states for progress display and integrity checks.
function DownloadQueue.chapterCounts(chapters)
    local counts = { total = 0, done = 0, pending = 0, failed = 0 }
    for _i, row in ipairs(chapters or {}) do
        counts.total = counts.total + 1
        if row.status == DownloadQueue.STATUS_DONE then
            counts.done = counts.done + 1
        elseif row.status == DownloadQueue.STATUS_FAILED then
            counts.failed = counts.failed + 1
        else
            counts.pending = counts.pending + 1
        end
    end
    return counts
end

--- Remove the job and all its chapter rows (after a successful EPUB build,
--- or when a fresh download replaces an interrupted one).
function DownloadQueue:clearJob(book_id)
    book_id = tostring(book_id or "")
    if book_id == "" then return false, "book id is required" end
    local db, open_err = self:open(false)
    if not db then
        return open_err == nil, open_err
    end
    local transaction_open = false
    local ok, err = pcall(function()
        db:exec("BEGIN")
        transaction_open = true
        local stmt = db:prepare("DELETE FROM chapters WHERE book_id=?")
        stmt:reset():bind(book_id):step()
        close_statement(stmt)
        stmt = db:prepare("DELETE FROM jobs WHERE book_id=?")
        stmt:reset():bind(book_id):step()
        close_statement(stmt)
        db:exec("COMMIT")
        transaction_open = false
    end)
    if not ok and transaction_open then pcall(function() db:exec("ROLLBACK") end) end
    pcall(function() db:close() end)
    return ok, ok and nil or tostring(err)
end

--- Decide whether an interrupted job can resume against the current catalog.
--- job_chapters: rows from loadJob (position-ordered).
--- chapters: the freshly fetched catalog chapter tables.
--- file_exists(path): optional body-file existence check.
--- Returns nil when the catalog changed (caller starts fresh), otherwise:
---   { done = { [position] = body_path }, pending = { positions... },
---     failed = { positions... }, missing = { positions... } }
--- `missing` lists chapters recorded done whose body file is gone; the caller
--- resets them to pending so they download again.
function DownloadQueue.plan_resume(job_chapters, chapters, file_exists)
    if type(job_chapters) ~= "table" or type(chapters) ~= "table"
        or #chapters == 0 or #job_chapters ~= #chapters then
        return nil
    end
    local plan = { done = {}, pending = {}, failed = {}, missing = {} }
    for index, chapter in ipairs(chapters) do
        local row = job_chapters[index]
        local uid = tostring(chapter.chapterUid or index)
        if not row or tostring(row.chapter_uid) ~= uid then
            return nil
        end
        if row.status == DownloadQueue.STATUS_DONE and type(row.body_path) == "string"
            and (not file_exists or file_exists(row.body_path)) then
            plan.done[index] = row.body_path
        elseif row.status == DownloadQueue.STATUS_DONE then
            plan.missing[#plan.missing + 1] = index
        elseif row.status == DownloadQueue.STATUS_FAILED then
            plan.failed[#plan.failed + 1] = index
        else
            plan.pending[#plan.pending + 1] = index
        end
    end
    return plan
end

--- Integrity reconciliation before building the EPUB: every catalog chapter
--- must be recorded done and its body file must exist. Returns true, or
--- false plus a human-readable problem summary.
function DownloadQueue.verify_complete(job_chapters, expected_total, file_exists)
    if type(job_chapters) ~= "table"
        or #job_chapters ~= tonumber(expected_total or -1) then
        return false, "chapter count mismatch"
    end
    local missing = {}
    for _i, row in ipairs(job_chapters) do
        if row.status ~= DownloadQueue.STATUS_DONE
            or type(row.body_path) ~= "string"
            or (file_exists and not file_exists(row.body_path)) then
            missing[#missing + 1] = tostring(row.chapter_uid or row.position)
        end
    end
    if #missing > 0 then
        return false, tostring(#missing) .. " chapter(s) incomplete"
    end
    return true
end

return DownloadQueue

local fn = vim.fn
local api = vim.api
local cmd = vim.cmd

local utils      = require('hlslens.utils')
local config     = require('hlslens.config')
local disposable = require('hlslens.lib.disposable')
local decorator  = require('hlslens.decorator')
local throttle   = require('hlslens.lib.throttle')
local position   = require('hlslens.position')
local event      = require('hlslens.lib.event')

local winhl = require('hlslens.render.winhl')
local extmark = require('hlslens.render.extmark')
local floatwin = require('hlslens.render.floatwin')

---@diagnostic disable: undefined-doc-name
---@alias HlslensRenderState
---| STOP #1
---| START #2
---@diagnostic enable: undefined-doc-name
local STOP = 1
local START = 2

---@class HlslensRender
---@field initialized boolean
---@field ns number
---@field status HlslensRenderState
---@field force? boolean
---@field nearestOnly boolean
---@field nearestFloatWhen string
---@field floatVirtId number
---@field floatShadowBlend number
---@field calmDown boolean
---@field stopDisposes HlslensDisposable[]
---@field disposables HlslensDisposable[]
local Render = {
    initialized = false,
    stopDisposes = {},
    disposables = {}
}

local function chunksToText(chunks)
    local text = ''
    for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
    end
    return text
end

function Render:doNohAndStop(defer)
    local function f()
        cmd('noh')
        self:stop()
    end

    if defer then
        vim.schedule(f)
    else
        f()
    end
end

local function refreshCurrentBuf()
    local self = Render
    if vim.v.hlsearch == 0 then
        vim.schedule(function()
            if vim.v.hlsearch == 0 then
                self:stop()
            end
        end)
        return
    end

    local bufnr = api.nvim_get_current_buf()
    local pos = position:compute(bufnr)
    if not pos then
        self:stop()
        return
    end
    if #pos.sList == 0 then
        self.clear(true, 0, true)
        return
    end

    local cursor = api.nvim_win_get_cursor(0)
    local curPos = {cursor[1], cursor[2] + 1}
    local topLine = fn.line('w0')
    local hit = pos:buildInfo(curPos, topLine)
    if self.calmDown then
        if not pos:cursorInRange(curPos) then
            self:doNohAndStop()
            return
        end
    elseif not self.force and hit then
        return
    end

    local botLine = pos.botLine or fn.line('w$')
    local fs, fe = pos.foldedLine, -1
    if fs ~= -1 then
        fe = fn.foldclosedend(curPos[1])
    end
    local idx, rIdx = pos.nearestIdx, pos.nearestRelIdx
    self.addWinHighlight(0, pos.sList[idx], pos.eList[idx])
    self:doLens(pos.sList, not pos.offsetPos, idx, rIdx, {topLine, botLine}, {fs, fe})
end

function Render:createEvents()
    local dps = {}
    cmd('aug HlSearchLensRender')
    cmd([[
        au CursorMoved * lua require('hlslens.lib.event'):emit('CursorMoved')
        au TermEnter * lua require('hlslens.lib.event'):emit('TermEnter')
    ]])
    event:on('CursorMoved', self.throttledRefresh, dps)
    event:on('TermEnter', function()
        self.clear(true, 0, true)
    end, dps)
    if self.calmDown then
        cmd([[
            au TextChanged * lua require('hlslens.lib.event'):emit('TextChanged')
            au TextChangedI * lua require('hlslens.lib.event'):emit('TextChangedI')
        ]])
        event:on('TextChanged', function()
            self:doNohAndStop(true)
        end, dps)
        event:on('TextChangedI', function()
            self:doNohAndStop(true)
        end, dps)
    end
    cmd('aug END')
    return disposable:create(function()
        cmd('au! HlSearchLensRender')
        disposable.disposeAll(dps)
    end)
end

local function enoughSizeForVirt(winid, lnum, text, lineWidth)
    local endVcol = utils.vcol(winid, {lnum, '$'}) - 1
    local remainingVcol
    if vim.wo[winid].wrap then
        remainingVcol = lineWidth - (endVcol - 1) % lineWidth - 1
    else
        remainingVcol = math.max(0, lineWidth - endVcol)
    end
    return remainingVcol > #text
end

-- Add lens template, can be overridden by `override_lens`
---@param bufnr number buffer number
---@param startPosList table (1,1)-indexed position
---@param nearest boolean whether nearest lens
---@param idx number nearest index in the plist
---@param relIdx number relative index, negative means before current position, positive means after
function Render:addLens(bufnr, startPosList, nearest, idx, relIdx)
    if type(config.override_lens) == 'function' then
        -- export render module for hacking :)
        return config.override_lens(self, startPosList, nearest, idx, relIdx)
    end
    local sfw = vim.v.searchforward == 1
    local indicator, text, chunks
    local absRelIdx = math.abs(relIdx)
    if absRelIdx > 1 then
        indicator = ('%d%s'):format(absRelIdx, sfw ~= (relIdx > 1) and 'N' or 'n')
    elseif absRelIdx == 1 then
        indicator = sfw ~= (relIdx == 1) and 'N' or 'n'
    else
        indicator = ''
    end

    local lnum, col = unpack(startPosList[idx])
    if nearest then
        local cnt = #startPosList
        if indicator ~= '' then
            text = ('[%s %d/%d]'):format(indicator, idx, cnt)
        else
            text = ('[%d/%d]'):format(idx, cnt)
        end
        chunks = {{' ', 'Ignore'}, {text, 'HlSearchLensNear'}}
    else
        text = ('[%s %d]'):format(indicator, idx)
        chunks = {{' ', 'Ignore'}, {text, 'HlSearchLens'}}
    end
    self.setVirt(bufnr, lnum - 1, col - 1, chunks, nearest)
end

function Render.setVirt(bufnr, lnum, col, chunks, nearest)
    local self = Render
    local when = self.nearestFloatWhen
    local exLnum, exCol = lnum + 1, col + 1
    if nearest and (when == 'auto' or when == 'always') then
        if utils.isCmdLineWin(bufnr) then
            extmark:setVirtEol(bufnr, lnum, chunks)
        else
            local winid = fn.bufwinid(bufnr ~= 0 and bufnr or '')
            if winid == -1 then
                return
            end
            local gutterSize = utils.textoff(api.nvim_get_current_win())
            local lineWidth = api.nvim_win_get_width(winid) - gutterSize
            local text = chunksToText(chunks)
            local pos = {exLnum, exCol}
            if when == 'always' then
                floatwin:updateFloatWin(winid, pos, chunks, text, lineWidth, gutterSize)
            else
                if enoughSizeForVirt(winid, exLnum, text, lineWidth) then
                    extmark:setVirtEol(bufnr, lnum, chunks)
                    floatwin:close()
                else
                    floatwin:updateFloatWin(winid, pos, chunks, text, lineWidth, gutterSize)
                end
            end
        end
    else
        extmark:setVirtEol(bufnr, lnum, chunks)
    end
end

-- TODO
-- compatible with old demo
Render.set_virt = Render.setVirt

function Render.addWinHighlight(winid, startPos, endPos)
    winhl.addHighlight(winid, startPos, endPos, 'HlSearchNear')
end

local function getIdxLnum(posList, i)
    return posList[i][1]
end

function Render:doLens(startPosList, nearest, idx, relIdx, limitRange, foldRange)
    local posLen = #startPosList
    local idxLnum = getIdxLnum(startPosList, idx)

    local lineRenderList = {}

    if not self.nearestOnly and not nearest then
        local iLnum, rIdx
        local lastHlLnum = 0
        local topLimit, botLimit = limitRange[1], limitRange[2]
        local fs, fe = foldRange[1], foldRange[2]

        local tIdx = idx - 1 - math.min(relIdx, 0)
        while fs > -1 and tIdx > 0 do
            iLnum = getIdxLnum(startPosList, tIdx)
            if fs > iLnum then
                break
            end
            tIdx = tIdx - 1
        end
        for i = math.max(tIdx, 0), 1, -1 do
            iLnum = getIdxLnum(startPosList, i)
            if iLnum < topLimit then
                break
            end
            if lastHlLnum ~= iLnum then
                lastHlLnum = iLnum
                rIdx = i - tIdx - 1
                lineRenderList[iLnum] = {i, rIdx}
            end
        end

        local bIdx = idx + 1 - math.max(relIdx, 0)
        while fe > -1 and bIdx < posLen do
            iLnum = getIdxLnum(startPosList, bIdx)
            if fe < iLnum then
                break
            end
            bIdx = bIdx + 1
        end
        lastHlLnum = idxLnum
        local lastI
        for i = bIdx, posLen do
            lastI = i
            iLnum = getIdxLnum(startPosList, i)
            if lastHlLnum ~= iLnum then
                lastHlLnum = iLnum
                rIdx = i - bIdx
                lineRenderList[startPosList[i - 1][1]] = {i - 1, rIdx}
            end
            if iLnum > botLimit then
                break
            end
        end

        if lastI and iLnum <= botLimit then
            rIdx = lastI - bIdx + 1
            lineRenderList[iLnum] = {lastI, rIdx}
        end
        lineRenderList[idxLnum] = nil
    end

    local bufnr = api.nvim_get_current_buf()
    extmark:clearBuf(bufnr)
    self:addLens(bufnr, startPosList, true, idx, relIdx)
    for _, idxPairs in pairs(lineRenderList) do
        self:addLens(bufnr, startPosList, false, idxPairs[1], idxPairs[2])
    end
end

function Render.clear(hl, bufnr, floated)
    if hl then
        winhl.clearHighlight()
    end
    if bufnr then
        extmark:clearBuf(bufnr)
    end
    if floated then
        floatwin:close()
    end
end

function Render.clearAll()
    floatwin:close()
    extmark:clearAll()
    winhl.clearHighlight()
end

function Render:refresh(force)
    self.force = force or self.force
    self.throttledRefresh()
end

function Render:start(force)
    if vim.o.hlsearch then
        if self.status ~= START then
            self.status = START
            table.insert(self.stopDisposes, decorator:initialize(self.ns))
            table.insert(self.stopDisposes, self:createEvents())
            event:on('RegionChanged', function()
                self:refresh(true)
            end, self.stopDisposes)
            table.insert(self.stopDisposes, disposable:create(function()
                position:resetPool()
                self.status = STOP
                self.clearAll()
                self.throttledRefresh:cancel()
            end))
        end
        if not self.throttledRefresh then
            return
        end
        if force then
            self.throttledRefresh:cancel()
        end
        self:refresh(force)
    end
end

function Render:isStarted()
    return self.status == START
end

function Render:dispose()
    self:stop()
    disposable.disposeAll(self.disposables)
    self.disposables = {}
end

function Render:stop()
    disposable.disposeAll(self.stopDisposes)
    self.stopDisposes = {}
end

function Render:initialize(namespace)
    self.status = STOP
    if self.initialized then
        return self
    end
    self.nearestOnly = config.nearest_only
    self.nearestFloatWhen = config.nearest_float_when
    self.calmDown = config.calm_down
    self.throttledRefresh = throttle(function()
        if self.throttledRefresh then
            refreshCurrentBuf()
        end
        self.force = nil
    end, 150)
    table.insert(self.disposables, disposable:create(function()
        self.initialized = false
        self.throttledRefresh:cancel()
        self.throttledRefresh = nil
    end))
    table.insert(self.disposables, extmark:initialize(namespace, config.virt_priority))
    table.insert(self.disposables, floatwin:initialize(config.float_shadow_blend))
    self.ns = namespace
    self.initialized = true
    return self
end

return Render
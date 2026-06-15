-- JpegDecode.lua
-- Minimal pure-Lua BASELINE (SOF0) JPEG decoder.
-- Supports: Huffman entropy coding, 8-bit, 1 or 3 components,
-- chroma subsampling (4:4:4 / 4:2:2 / 4:2:0), restart markers.
-- Does NOT support progressive or arithmetic coding (LR thumbnails are baseline).
--
-- Usage:
--   local JpegDecode = require "JpegDecode"
--   local img = JpegDecode.decode(jpegBytes)   -- img.width, img.height, img.pixels (R,G,B per pixel, 0..255)
--   -- pixels indexed: img:get(x,y) -> r,g,b
--
-- For our purposes we expose decode() returning width/height and a flat byte array.

local JpegDecode = {}

-- ZigZag order
local ZIGZAG = {
     1, 2, 9,17,10, 3, 4,11,
    18,25,33,26,19,12, 5, 6,
    13,20,27,34,41,49,42,35,
    28,21,14, 7, 8,15,22,29,
    36,43,50,57,58,51,44,37,
    30,23,16,24,31,38,45,52,
    59,60,53,46,39,32,40,47,
    54,61,62,55,48,56,63,64,
}

-- Clamp to 0..255
local function clamp(v)
    if v < 0 then return 0 elseif v > 255 then return 255 else return v end
end

-- ── Bit reader over the entropy-coded segment ────────────────────────────────
local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data, pos)
    return setmetatable({ data = data, pos = pos, bitBuf = 0, bitCnt = 0, marker = nil }, BitReader)
end

function BitReader:readBit()
    if self.bitCnt == 0 then
        if self.pos > #self.data then return 0 end
        local b = self.data:byte(self.pos)
        self.pos = self.pos + 1
        if b == 0xFF then
            -- byte stuffing: 0xFF00 -> 0xFF; 0xFFD0..D7 = restart; else marker
            local nxt = self.data:byte(self.pos)
            if nxt == 0x00 then
                self.pos = self.pos + 1
            elseif nxt and nxt >= 0xD0 and nxt <= 0xD7 then
                -- restart marker reached; signal by remembering it
                self.marker = nxt
                self.pos = self.pos + 1
                -- return zeros; caller handles restart at MCU boundary
                b = 0
            else
                self.marker = nxt
                b = 0
            end
        end
        self.bitBuf = b
        self.bitCnt = 8
    end
    self.bitCnt = self.bitCnt - 1
    local bit = math.floor(self.bitBuf / (2 ^ self.bitCnt)) % 2
    return bit
end

function BitReader:readBits(n)
    local v = 0
    for _ = 1, n do
        v = v * 2 + self:readBit()
    end
    return v
end

function BitReader:reset()
    self.bitBuf = 0
    self.bitCnt = 0
end

-- Receive + extend (JPEG signed value decode)
local function extend(v, n)
    if n == 0 then return 0 end
    if v < 2 ^ (n - 1) then
        return v - (2 ^ n) + 1
    end
    return v
end

-- ── Build Huffman lookup from bits/values ────────────────────────────────────
local function buildHuffman(counts, symbols)
    -- counts[1..16] = number of codes of each length
    -- returns a table: maxcode/mincode/valptr style decode
    local huffsize = {}
    local k = 1
    for len = 1, 16 do
        for _ = 1, counts[len] do
            huffsize[k] = len
            k = k + 1
        end
    end
    local huffcode = {}
    local code = 0
    local si = huffsize[1] or 0
    k = 1
    while huffsize[k] do
        while huffsize[k] == si do
            huffcode[k] = code
            code = code + 1
            k = k + 1
            if not huffsize[k] then break end
        end
        code = code * 2
        si = si + 1
    end
    -- Build min/max code per length
    local mincode, maxcode, valptr = {}, {}, {}
    local p = 1
    for len = 1, 16 do
        if counts[len] > 0 then
            valptr[len] = p
            mincode[len] = huffcode[p]
            p = p + counts[len]
            maxcode[len] = huffcode[p - 1]
        else
            maxcode[len] = -1
        end
    end
    return { mincode = mincode, maxcode = maxcode, valptr = valptr, symbols = symbols }
end

local function huffDecode(br, htab)
    local code = 0
    for len = 1, 16 do
        code = code * 2 + br:readBit()
        if htab.maxcode[len] and htab.maxcode[len] >= 0 and code <= htab.maxcode[len] and code >= htab.mincode[len] then
            local idx = htab.valptr[len] + (code - htab.mincode[len])
            return htab.symbols[idx]
        end
    end
    return 0
end

-- ── Inverse DCT (separable, float) ───────────────────────────────────────────
-- Precompute cosine table
local IDCT_COS = {}
for u = 0, 7 do
    IDCT_COS[u] = {}
    local cu = (u == 0) and (1 / math.sqrt(2)) or 1
    for x = 0, 7 do
        IDCT_COS[u][x] = cu * math.cos((2 * x + 1) * u * math.pi / 16)
    end
end

local function idct8x8(block, out)
    -- block: 64 dequantized coefficients in natural order (1-based)
    -- out: 64 spatial values (1-based)
    local tmp = {}
    -- rows
    for y = 0, 7 do
        for x = 0, 7 do
            local s = 0
            for u = 0, 7 do
                s = s + IDCT_COS[u][x] * block[y * 8 + u + 1]
            end
            tmp[y * 8 + x + 1] = s * 0.5
        end
    end
    -- columns
    for x = 0, 7 do
        for y = 0, 7 do
            local s = 0
            for v = 0, 7 do
                s = s + IDCT_COS[v][y] * tmp[v * 8 + x + 1]
            end
            out[y * 8 + x + 1] = s * 0.5 + 128
        end
    end
end

-- ── Main decode ──────────────────────────────────────────────────────────────
function JpegDecode.decode(data)
    local pos = 1
    local function u16(p) return data:byte(p) * 256 + data:byte(p + 1) end

    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
        return nil, "Not a JPEG (no SOI)"
    end
    pos = 3

    local qtables = {}
    local htablesDC = {}
    local htablesAC = {}
    local frame = nil
    local restartInterval = 0

    while pos < #data do
        if data:byte(pos) ~= 0xFF then
            pos = pos + 1
        else
        local marker = data:byte(pos + 1)
        pos = pos + 2

        if marker == 0xD9 then break end          -- EOI
        if (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01 then
            -- standalone marker, no segment
        else

        local len = u16(pos)
        local segStart = pos + 2
        local segEnd = pos + len

        if marker == 0xDB then            -- DQT
            local p = segStart
            while p < segEnd do
                local pq_tq = data:byte(p); p = p + 1
                local pq = math.floor(pq_tq / 16)
                local tq = pq_tq % 16
                local tbl = {}
                if pq == 0 then
                    for i = 1, 64 do tbl[ZIGZAG[i]] = data:byte(p); p = p + 1 end
                else
                    for i = 1, 64 do tbl[ZIGZAG[i]] = u16(p); p = p + 2 end
                end
                qtables[tq] = tbl
            end

        elseif marker == 0xC0 or marker == 0xC1 then   -- SOF0/SOF1 baseline
            local prec = data:byte(segStart)
            local h = u16(segStart + 1)
            local w = u16(segStart + 3)
            local nc = data:byte(segStart + 5)
            local comps = {}
            local p = segStart + 6
            local maxH, maxV = 1, 1
            for _ = 1, nc do
                local id = data:byte(p)
                local hv = data:byte(p + 1)
                local hq = math.floor(hv / 16)
                local vq = hv % 16
                local tq = data:byte(p + 2)
                comps[#comps + 1] = { id = id, h = hq, v = vq, tq = tq }
                if hq > maxH then maxH = hq end
                if vq > maxV then maxV = vq end
                p = p + 3
            end
            frame = { width = w, height = h, comps = comps, maxH = maxH, maxV = maxV }

        elseif marker == 0xC2 then
            return nil, "Progressive JPEG not supported"

        elseif marker == 0xC4 then        -- DHT
            local p = segStart
            while p < segEnd do
                local tc_th = data:byte(p); p = p + 1
                local tc = math.floor(tc_th / 16)   -- 0 = DC, 1 = AC
                local th = tc_th % 16
                local counts = {}
                local total = 0
                for i = 1, 16 do counts[i] = data:byte(p); total = total + counts[i]; p = p + 1 end
                local symbols = {}
                for i = 1, total do symbols[i] = data:byte(p); p = p + 1 end
                local htab = buildHuffman(counts, symbols)
                if tc == 0 then htablesDC[th] = htab else htablesAC[th] = htab end
            end

        elseif marker == 0xDD then        -- DRI
            restartInterval = u16(segStart)

        elseif marker == 0xDA then        -- SOS
            local ns = data:byte(segStart)
            local p = segStart + 1
            local scanComps = {}
            for _ = 1, ns do
                local cs = data:byte(p)
                local td_ta = data:byte(p + 1)
                local td = math.floor(td_ta / 16)
                local ta = td_ta % 16
                for _, c in ipairs(frame.comps) do
                    if c.id == cs then
                        c.td = td; c.ta = ta
                        scanComps[#scanComps + 1] = c
                    end
                end
                p = p + 2
            end
            -- skip Ss, Se, Ah/Al (3 bytes)
            p = p + 3
            -- Entropy-coded data starts at p
            return JpegDecode._decodeScan(data, p, frame, qtables, htablesDC, htablesAC, restartInterval, scanComps)
        end

        pos = segEnd
        end   -- end "not standalone marker" else
        end   -- end "is 0xFF" else
    end

    return nil, "No scan found"
end

function JpegDecode._decodeScan(data, p, frame, qtables, htablesDC, htablesAC, restartInterval, scanComps)
    local W, H = frame.width, frame.height
    local maxH, maxV = frame.maxH, frame.maxV
    local mcuW = maxH * 8
    local mcuH = maxV * 8
    local mcusX = math.ceil(W / mcuW)
    local mcusY = math.ceil(H / mcuH)

    -- Output plane per component at component resolution
    for _, c in ipairs(frame.comps) do
        c.planeW = mcusX * c.h * 8
        c.planeH = mcusY * c.v * 8
        c.plane = {}
        c.pred = 0
    end

    local br = BitReader.new(data, p)
    local block = {}
    local out = {}

    local mcuCount = 0
    for my = 0, mcusY - 1 do
        for mx = 0, mcusX - 1 do
            -- restart handling
            if restartInterval > 0 and mcuCount > 0 and (mcuCount % restartInterval) == 0 then
                br:reset()
                -- consume restart marker if present
                if br.marker and br.marker >= 0xD0 and br.marker <= 0xD7 then
                    br.marker = nil
                end
                for _, c in ipairs(frame.comps) do c.pred = 0 end
            end

            for _, c in ipairs(scanComps) do
                local dcTab = htablesDC[c.td]
                local acTab = htablesAC[c.ta]
                local qt = qtables[c.tq]
                for by = 0, c.v - 1 do
                    for bx = 0, c.h - 1 do
                        -- decode one 8x8 block
                        for i = 1, 64 do block[i] = 0 end
                        -- DC
                        local t = huffDecode(br, dcTab)
                        local diff = 0
                        if t > 0 then diff = extend(br:readBits(t), t) end
                        c.pred = c.pred + diff
                        block[1] = c.pred * qt[1]
                        -- AC
                        local k = 2
                        while k <= 64 do
                            local rs = huffDecode(br, acTab)
                            local r = math.floor(rs / 16)
                            local s = rs % 16
                            if s == 0 then
                                if r == 15 then k = k + 16 else break end
                            else
                                k = k + r
                                if k > 64 then break end
                                local val = extend(br:readBits(s), s)
                                local natural = ZIGZAG[k]
                                block[natural] = val * qt[natural]
                                k = k + 1
                            end
                        end
                        idct8x8(block, out)
                        -- store into plane
                        local px0 = (mx * c.h + bx) * 8
                        local py0 = (my * c.v + by) * 8
                        for yy = 0, 7 do
                            local row = (py0 + yy) * c.planeW
                            for xx = 0, 7 do
                                c.plane[row + px0 + xx + 1] = clamp(out[yy * 8 + xx + 1])
                            end
                        end
                    end
                end
            end
            mcuCount = mcuCount + 1
        end
    end

    -- Reconstruct RGB with upsampling
    local img = { width = W, height = H }
    local pix = {}
    local comps = frame.comps
    local nc = #comps
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local r, g, b
            if nc == 1 then
                local c = comps[1]
                local sx = math.floor(x * c.h / maxH)
                local sy = math.floor(y * c.v / maxV)
                local Y = c.plane[sy * c.planeW + sx + 1] or 0
                r, g, b = Y, Y, Y
            else
                local cy, cb, cr = comps[1], comps[2], comps[3]
                local function sample(c)
                    local sx = math.floor(x * c.h / maxH)
                    local sy = math.floor(y * c.v / maxV)
                    return c.plane[sy * c.planeW + sx + 1] or 0
                end
                local Y  = sample(cy)
                local Cb = sample(cb) - 128
                local Cr = sample(cr) - 128
                r = clamp(Y + 1.402 * Cr)
                g = clamp(Y - 0.344136 * Cb - 0.714136 * Cr)
                b = clamp(Y + 1.772 * Cb)
            end
            local idx = (y * W + x) * 3
            pix[idx + 1] = r
            pix[idx + 2] = g
            pix[idx + 3] = b
        end
    end
    img.pixels = pix
    return img
end

return JpegDecode

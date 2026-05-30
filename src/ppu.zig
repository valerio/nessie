const mapper = @import("mapper.zig");
const cart = @import("cart.zig");

const Mapper = mapper.Mapper;
const MirrorMode = cart.MirrorMode;

pub const screenWidth = 256;
pub const screenHeight = 240;
pub const paletteColorCount = 64;
pub const paletteBytesPerColor = 3;
pub const paletteSize = paletteColorCount * paletteBytesPerColor; // 192

/// generated using https://bisqwit.iki.fi/utils/nespalette.php.
/// NES output isn't a strictly defined set of values, so this is replaceable.
pub const paletteRgb = @embedFile("ntscpalette.pal");
comptime {
    if (paletteRgb.len != paletteSize) @compileError("ntscpalette.pal must be 192 bytes");
}

pub const dotsPerScanline = 341;
pub const scanlinesPerFrame = 262;
pub const scanlinePostRender = 240;

/// PPUCTRL $2000
/// VPHB SINN
pub const Control = packed struct(u8) {
    nametable: u2 = 0,
    incrementMode: bool = false,
    spriteTileSelect: bool = false,
    bgTileSelect: bool = false,
    spriteHeight: bool = false,
    masterSlave: bool = false,
    nmiEnable: bool = false,
};

/// PPUMASK $2001
/// BGRs bMmG
pub const Mask = packed struct(u8) {
    greyscale: bool = false,
    bgLeftColumnEnable: bool = false,
    spriteLeftColumnEnable: bool = false,
    bgEnable: bool = false,
    spriteEnable: bool = false,
    emphasisRed: bool = false,
    emphasisGreen: bool = false,
    emphasisBlue: bool = false,
};

/// PPUSTATUS $2002
/// VSO- ----
pub const Status = packed struct(u8) {
    _: u5 = 0,
    spriteOverflow: bool = false,
    spriteZeroHit: bool = false,
    vblank: bool = false,
};

const vramSize = 2048;
const paletteRamSize = 32;
const oamSize = 256;
const secondaryOamSize = 32;
const spriteSlots = 8;
const scanlineLastVisible = 239;
const scanlineVblank = 241;
const scanlinePrerender = 261;
const oddSkipLatchDot = dotsPerScanline - 3;
const ppuIoDecayTicks = 16_000;

const nametableBase: u16 = 0x2000;
const nametableOffsetMask: u16 = 0x0FFF;
const attributeTableBase: u16 = 0x23C0;
const patternTileBytes: u16 = 16;
const patternPlaneBytes: u16 = 8;

const loopyCoarseX: u16 = 0x001F;
const loopyCoarseY: u16 = 0x03E0;
const loopyNt: u16 = 0x0C00;
const loopyFineY: u16 = 0x7000;
const loopyHorizontalBits = loopyCoarseX | (loopyNt & 0x0400);
const loopyVerticalBits = loopyCoarseY | loopyFineY | (loopyNt & 0x0800);

pub const TickResult = struct {
    nmi: bool,
    frameDone: bool,
};

const BgPixel = struct {
    pixel: u8 = 0,
    palette: u8 = 0,
};

const SpritePixel = struct {
    pixel: u8 = 0,
    palette: u8 = 0,
    behindBackground: bool = false,
    isSpriteZero: bool = false,
};

pub const Ppu = struct {
    // Memory visible to the frontend, PPU bus, and sprite DMA.
    framebuffer: [screenWidth * screenHeight]u8 = [_]u8{0} ** (screenWidth * screenHeight),
    vram: [vramSize]u8 = [_]u8{0} ** vramSize,
    palette: [paletteRamSize]u8 = [_]u8{0} ** paletteRamSize,
    oam: [oamSize]u8 = [_]u8{0} ** oamSize,
    secondaryOam: [secondaryOamSize]u8 = [_]u8{0xff} ** secondaryOamSize,
    evalSecondaryOam: [secondaryOamSize]u8 = [_]u8{0xff} ** secondaryOamSize,

    // CPU-facing registers and their internal latches.
    ctrl: Control = .{},
    mask: Mask = .{},
    renderMask: Mask = .{},
    status: Status = .{},
    loopyV: u16 = 0,
    loopyT: u16 = 0,
    fineX: u8 = 0,
    loopyWriteToggle: bool = false,
    dataBuf: u8 = 0,
    ioLatch: u8 = 0,
    ioLatchDecay: u32 = 0,
    oamAddr: u8 = 0,

    // Global dot/frame timing.
    scanline: u32 = 0,
    dot: u32 = 0,
    frameOdd: bool = false,
    oddSkipLatch: bool = false,
    suppressNmi: bool = false,
    suppressVblankFlag: bool = false,

    // Background fetch and shifter state.
    bgTileId: u8 = 0,
    bgAttributeBits: u8 = 0,
    bgPatternLo: u8 = 0,
    bgPatternHi: u8 = 0,
    bgPatternShiftLo: u16 = 0,
    bgPatternShiftHi: u16 = 0,
    bgPaletteShiftLo: u16 = 0,
    bgPaletteShiftHi: u16 = 0,
    bgSerialInWhenRenderingOff: bool = false,
    skipBgLoadOnRenderEnable: bool = false,
    useScreenXForSprite0Hit: bool = false,

    // Sprite evaluation, fetch, and live render state.
    spriteRenderDots: u32 = 0,
    spriteCount: u8 = 0,
    evalSpriteCount: u8 = 0,
    spriteAttrs: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    fetchedSpriteAttrs: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    spritePatternLo: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    spritePatternHi: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    fetchedSpritePatternLo: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    fetchedSpritePatternHi: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    spriteXCounter: [spriteSlots]u8 = [_]u8{0} ** spriteSlots,
    fetchedSpriteXCounter: [spriteSlots]u8 = [_]u8{0xff} ** spriteSlots,
    spriteIsZero: [spriteSlots]bool = [_]bool{false} ** spriteSlots,
    evalSprite0OnLine: bool = false,
    sprite0Visible: bool = false,
    fetchedSprite0Visible: bool = false,
    evalActive: bool = false,
    fetchActive: bool = false,
    evalNextStep: u16 = 0,
    fetchNextStep: u8 = 0,
    fetchSlot: u8 = 0,
    fetchSubstep: u8 = 0,
    secondaryOamAddr: u8 = 0,
    spriteAddrH: u8 = 0,
    spriteAddrL: u8 = 0,
    spriteInRange: bool = false,
    oamCopyDone: bool = false,
    oamCopyBuffer: u8 = 0,
    oamCopyBufferAddr: u8 = 0,
    sprite0Added: bool = false,
    oamCorruptionSeed: ?u5 = null,
    overflowBugCounter: u8 = 0,
    evalRanThisScanline: bool = false,
    sprite0HblankReloadSuppressed: bool = false,
    spriteZeroHitDelay: ?u8 = null,
    spriteOverflowDelay: ?u8 = null,

    pub fn read(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1fff => cart_mapper.read(addr),
            0x2000...0x3eff => self.vram[mirrorVram(mirror_mode, addr)],
            else => self.palette[normalizePalette(addr)],
        };
    }

    pub fn write(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, addr: u16, value: u8) void {
        switch (addr) {
            0x0000...0x1fff => cart_mapper.write(addr, value),
            0x2000...0x3eff => self.vram[mirrorVram(mirror_mode, addr)] = value,
            else => self.palette[normalizePalette(addr)] = value & 0x3F,
        }
    }

    pub fn readRegister(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, addr: u16) u8 {
        return switch (addr & 0x0007) {
            0x0002 => {
                const m2High = self.readStatusRegisterM2High();
                _ = self.tickDots(cart_mapper, mirror_mode, 2);
                return self.finishStatusRegisterM2Low(m2High.vblankBit);
            },
            0x0004 => {
                const value = self.readOamData();
                self.setIoLatch(value);
                return value;
            },
            0x0007 => self.readDataRegister(cart_mapper, mirror_mode),
            else => self.ioLatch,
        };
    }

    pub fn writeRegister(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, addr: u16, value: u8) void {
        self.setIoLatch(value);
        switch (addr & 0x0007) {
            0x0000 => self.writeControl(value),
            0x0001 => self.mask = @bitCast(value),
            0x0003 => self.oamAddr = value,
            0x0004 => self.writeOamData(value),
            0x0005 => self.writeScroll(value),
            0x0006 => self.writeAddr(value),
            0x0007 => self.writeDataRegister(cart_mapper, mirror_mode, value),
            else => {},
        }
    }

    pub fn tick(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) TickResult {
        return self.tickDots(cart_mapper, mirror_mode, 3);
    }

    pub fn tickDots(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, dots: u32) TickResult {
        var nmi = false;
        var frameDone = false;

        for (0..dots) |_| {
            const result = self.tickDot(cart_mapper, mirror_mode);
            nmi = nmi or result.nmi;
            frameDone = frameDone or result.frameDone;
        }

        return .{ .nmi = nmi, .frameDone = frameDone };
    }

    fn isRenderScanline(self: *const Ppu) bool {
        return self.scanline <= scanlineLastVisible or self.scanline == scanlinePrerender;
    }

    fn maskRenderingEnabled(mask_value: Mask) bool {
        return mask_value.bgEnable or mask_value.spriteEnable;
    }

    fn applyPendingRenderMask(self: *Ppu) void {
        const prev_mask = self.renderMask;
        self.renderMask = .{
            .bgEnable = self.mask.bgEnable,
            .spriteEnable = self.mask.spriteEnable,
        };
        if (prev_mask == self.renderMask) return;

        const prevRendering = maskRenderingEnabled(prev_mask);
        const nextRendering = maskRenderingEnabled(self.renderMask);
        const renderScanline = self.isRenderScanline();

        if (prevRendering and !nextRendering) {
            self.bgSerialInWhenRenderingOff = renderScanline and self.dot >= 1 and self.dot <= 255;
        } else if (nextRendering) {
            self.bgSerialInWhenRenderingOff = false;
        }

        const renderEnabledOnLoadDot = !prevRendering and
            self.renderMask.bgEnable and
            renderScanline and
            self.dot >= 1 and
            self.dot <= 255;
        if (renderEnabledOnLoadDot and (self.dot & 7) == 0) self.skipBgLoadOnRenderEnable = true;
        if (self.skipBgLoadOnRenderEnable) self.useScreenXForSprite0Hit = true;

        if (prevRendering and !nextRendering and renderScanline) {
            self.oamCorruptionSeed = @truncate(self.secondarySpriteAddr(self.dot) & 0x1f);

            const isVisibleLine = self.scanline <= scanlineLastVisible;
            const isSpriteReloadWindow = self.dot >= 257 and self.dot <= 320;
            const isSprite0ActivelyDrawing = self.sprite0Visible and self.sprite0PixelAtSampleOffset(self.spriteRenderDots -| 1) != 0;
            if (isVisibleLine and isSpriteReloadWindow and isSprite0ActivelyDrawing) {
                self.sprite0HblankReloadSuppressed = true;
            }
        }
    }

    fn setIoLatch(self: *Ppu, value: u8) void {
        self.ioLatch = value;
        self.ioLatchDecay = ppuIoDecayTicks;
    }

    pub fn readStatusRegisterM2High(self: *Ppu) struct { vblankBit: u8, suppressNmi: bool } {
        const inSuppressionWindow = self.scanline == scanlineVblank and self.dot >= 1 and self.dot <= 3;
        if (inSuppressionWindow) {
            if (self.dot == 1) self.suppressVblankFlag = true;
            self.suppressNmi = true;
        }
        const vblankBit: u8 = if (self.status.vblank) 0x80 else 0;
        self.status.vblank = false;
        self.loopyWriteToggle = false;
        return .{ .vblankBit = vblankBit, .suppressNmi = inSuppressionWindow };
    }

    pub fn finishStatusRegisterM2Low(self: *Ppu, vblank_bit: u8) u8 {
        const spriteBits = @as(u8, @bitCast(self.status)) & 0x60;
        const value: u8 = vblank_bit | spriteBits | (self.ioLatch & 0x1f);
        self.setIoLatch((value & 0xe0) | (self.ioLatch & 0x1f));
        return value;
    }

    fn readDataRegister(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) u8 {
        const readAddr = self.loopyV & 0x3FFF;
        const renderingRead = self.isRenderScanline() and maskRenderingEnabled(self.renderMask);
        if (readAddr >= 0x3F00) {
            var palette = self.read(cart_mapper, mirror_mode, readAddr) & 0x3F;
            if (self.mask.greyscale) palette &= 0x30;
            const value = (self.ioLatch & 0xc0) | palette;
            self.dataBuf = self.read(cart_mapper, mirror_mode, readAddr & 0x2FFF);
            self.loopyV = (self.loopyV + dataAccessIncrement(self.ctrl, renderingRead)) & 0x7FFF;
            self.setIoLatch((self.ioLatch & 0xc0) | palette);
            return value;
        }

        const data = self.dataBuf;
        self.dataBuf = if (renderingRead)
            self.sampleRenderingDataReadBuffer(cart_mapper, mirror_mode, readAddr)
        else
            self.read(cart_mapper, mirror_mode, readAddr);
        self.loopyV = (self.loopyV + dataAccessIncrement(self.ctrl, renderingRead)) & 0x7FFF;
        self.setIoLatch(data);
        return data;
    }

    fn writeControl(self: *Ppu, value: u8) void {
        self.ctrl = @bitCast(value);
        self.loopyT = (self.loopyT & ~loopyNt) | (@as(u16, value & 0b11) << 10);
    }

    fn writeDataRegister(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, value: u8) void {
        const renderingWrite = self.isRenderScanline() and maskRenderingEnabled(self.renderMask);
        self.write(cart_mapper, mirror_mode, self.loopyV & 0x3FFF, value);
        self.loopyV = (self.loopyV + dataAccessIncrement(self.ctrl, renderingWrite)) & 0x7FFF;
    }

    fn sampleRenderingDataReadBuffer(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, read_addr: u16) u8 {
        const targetDot = (self.dot + 4) % dotsPerScanline;
        const projectedV = self.projectRenderVForDataSample(targetDot);

        if (targetDot >= 258 and targetDot <= 320) {
            return self.sampleSpritePatternFetch(cart_mapper, mirror_mode, targetDot) orelse
                self.read(cart_mapper, mirror_mode, bgNametableAddr(projectedV));
        }

        return self.sampleBgFetchValue(cart_mapper, mirror_mode, targetDot, projectedV) orelse
            self.read(cart_mapper, mirror_mode, read_addr);
    }

    fn projectRenderVForDataSample(self: *const Ppu, target_dot: u32) u16 {
        var v = self.loopyV;
        var dot = self.dot;
        for (0..4) |_| {
            if ((dot >= 1 and dot <= 255) or (dot >= 321 and dot <= 336)) {
                if ((dot & 7) == 0) v = incCoarseX(v);
            }
            if (dot == 256) {
                v = incCoarseX(v);
                v = incFineY(v);
            }
            if (dot == 257 and target_dot != 258) v = copyHorizontalScroll(v, self.loopyT);
            if (self.scanline == scanlinePrerender and dot >= 280 and dot <= 304) {
                v = copyVerticalScroll(v, self.loopyT);
            }
            dot = (dot + 1) % dotsPerScanline;
        }
        return v;
    }

    fn sampleBgFetchValue(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, dot: u32, v: u16) ?u8 {
        if (dot == 340) return self.read(cart_mapper, mirror_mode, bgNametableAddr(v));

        switch (dot & 7) {
            2 => return self.read(cart_mapper, mirror_mode, bgNametableAddr(v)),
            4 => return self.read(cart_mapper, mirror_mode, bgAttributeAddr(v)),
            6, 0 => {
                const nt = self.read(cart_mapper, mirror_mode, bgNametableAddr(v));
                const plane: u16 = if ((dot & 7) == 0) 1 else 0;
                return self.read(cart_mapper, mirror_mode, bgPatternAddr(if (self.ctrl.bgTileSelect) 0x1000 else 0x0000, nt, (v & loopyFineY) >> 12, plane));
            },
            else => return null,
        }
    }

    fn sampleSpritePatternFetch(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, target_dot: u32) ?u8 {
        if (target_dot < 262 or target_dot > 320) return null;
        const offset = target_dot - 258;
        const phase = offset & 7;
        if (phase != 4 and phase != 6) return null;

        const slot = offset >> 3;
        const base = slot * 4;
        const spriteY = self.evalSecondaryOam[base + 0];
        const tileId = self.evalSecondaryOam[base + 1];
        const attr = self.evalSecondaryOam[base + 2];
        const targetScanline = if (self.scanline == scanlinePrerender) scanlinePrerender + 1 else self.scanline + 1;
        const addr = self.spritePatternAddrForScanline(targetScanline, spriteY, tileId, attr);
        return self.read(cart_mapper, mirror_mode, addr + if (phase == 6) patternPlaneBytes else 0);
    }

    fn readOamData(self: *const Ppu) u8 {
        const activeRender = self.isRenderScanline() and maskRenderingEnabled(self.renderMask);
        var value: u8 = undefined;
        var addr: u8 = undefined;
        var maskAttributeByte = true;

        if (!activeRender) {
            value = self.oam[self.oamAddr];
            addr = self.oamAddr;
        } else if (self.dot == 0 or self.dot >= 321) {
            value = self.evalSecondaryOam[0];
            addr = 0;
            maskAttributeByte = value != 0xff;
        } else if (self.dot <= 64) {
            value = 0xff;
            addr = @intCast((self.dot - 1) >> 1);
            maskAttributeByte = false;
        } else if (self.dot < 257) {
            if ((self.dot & 1) == 0 and self.secondaryOamAddr > 0 and (self.secondaryOamAddr >= secondaryOamSize or self.oamCopyDone)) {
                addr = self.secondaryOamAddr & 0x1f;
                value = self.evalSecondaryOam[addr];
                maskAttributeByte = value != 0xff;
            } else {
                addr = self.oamCopyBufferAddr;
                value = self.oamCopyBuffer;
            }
        } else {
            const step = self.dot - 257;
            const base = (step >> 3) * 4;
            const substep = step & 7;
            addr = @intCast((base + if (substep <= 2) substep else 3) & 0x1f);
            value = self.evalSecondaryOam[addr];
            maskAttributeByte = value != 0xff;
        }

        if (maskAttributeByte and (addr & 0x03) == 0x02) value &= 0xE3;
        return value;
    }

    fn writeOamData(self: *Ppu, value: u8) void {
        if (self.isRenderScanline() and maskRenderingEnabled(self.renderMask)) {
            self.oamAddr = (self.oamAddr +% 4) & 0xFC;
            return;
        }

        self.oam[self.oamAddr] = value;
        self.oamAddr +%= 1;
    }

    fn writeScroll(self: *Ppu, value: u8) void {
        const val: u16 = @intCast(value);

        if (!self.loopyWriteToggle) {
            self.loopyT = (self.loopyT & ~loopyCoarseX) | (val >> 3);
            self.fineX = value & 0b111;
            self.loopyWriteToggle = true;
            return;
        }

        self.loopyT =
            (self.loopyT & ~(loopyFineY | loopyCoarseY)) |
            ((val & 0b111) << 12) | ((val >> 3) << 5);

        self.loopyWriteToggle = false;
    }

    fn writeAddr(self: *Ppu, value: u8) void {
        if (!self.loopyWriteToggle) {
            self.loopyT = (@as(u16, value & 0x3F) << 8) | (self.loopyT & 0x00FF);
            self.loopyWriteToggle = true;
            return;
        }

        self.loopyT = (self.loopyT & 0xFF00) | value;
        self.loopyV = self.loopyT;
        self.loopyWriteToggle = false;
    }

    fn sampleBgPixel(self: *const Ppu) BgPixel {
        const bit: u4 = @truncate(15 - self.fineX);
        const p0 = (self.bgPatternShiftLo >> bit) & 1;
        const p1 = (self.bgPatternShiftHi >> bit) & 1;
        const bgPixel = (p1 << 1) | p0;

        if (bgPixel == 0) return .{};

        const a0 = (self.bgPaletteShiftLo >> bit) & 1;
        const a1 = (self.bgPaletteShiftHi >> bit) & 1;
        return .{
            .pixel = @intCast(bgPixel),
            .palette = @intCast((a1 << 1) | a0),
        };
    }

    fn sampleSpritePixel(self: *const Ppu, x: u32) SpritePixel {
        for (0..self.spriteCount) |i| {
            const spriteX = self.spriteXCounter[i];
            if (x < spriteX) continue;

            const offset = x - spriteX;
            if (offset >= 8) continue;

            const bit: u3 = @intCast(7 - offset);
            const p0 = (self.spritePatternLo[i] >> bit) & 1;
            const p1 = (self.spritePatternHi[i] >> bit) & 1;
            const spritePixel = (p1 << 1) | p0;
            if (spritePixel == 0) continue;

            const attr = self.spriteAttrs[i];
            return .{
                .pixel = spritePixel,
                .palette = attr & 0x03,
                .behindBackground = (attr & 0x20) != 0,
                .isSpriteZero = self.spriteIsZero[i],
            };
        }

        return .{};
    }

    fn sprite0PixelAtSampleOffset(self: *const Ppu, sample_offset: u32) u8 {
        if (self.spriteCount == 0) return 0;
        const spriteX = self.spriteXCounter[0];
        if (sample_offset < spriteX) return 0;

        const offset = sample_offset - spriteX;
        if (offset >= 8) return 0;

        const bit: u3 = @intCast(7 - offset);
        const p0 = (self.spritePatternLo[0] >> bit) & 1;
        const p1 = (self.spritePatternHi[0] >> bit) & 1;
        return (p1 << 1) | p0;
    }

    fn resolvePaletteAddr(bg: BgPixel, sprite: SpritePixel) u16 {
        if (bg.pixel == 0 and sprite.pixel == 0) return 0x3F00;
        if (bg.pixel == 0) return 0x3F10 + @as(u16, sprite.palette) * 4 + sprite.pixel;
        if (sprite.pixel == 0) return 0x3F00 + @as(u16, bg.palette) * 4 + bg.pixel;
        if (sprite.behindBackground) return 0x3F00 + @as(u16, bg.palette) * 4 + bg.pixel;
        return 0x3F10 + @as(u16, sprite.palette) * 4 + sprite.pixel;
    }

    fn renderPixel(self: *Ppu) void {
        const x = self.dot - 1;
        var bg = self.sampleBgPixel();
        const spriteSampleX = if (self.useScreenXForSprite0Hit) x else if (self.spriteRenderDots == 0) 0 else self.spriteRenderDots - 1;
        var sprite = self.sampleSpritePixel(spriteSampleX);

        if (!self.renderMask.bgEnable or (!self.mask.bgLeftColumnEnable and x < 8)) bg = .{};
        if (!self.renderMask.spriteEnable or (!self.mask.spriteLeftColumnEnable and x < 8)) sprite = .{};

        if (x < 255 and sprite.isSpriteZero and bg.pixel != 0 and sprite.pixel != 0 and
            !self.status.spriteZeroHit and self.spriteZeroHitDelay == null)
        {
            self.spriteZeroHitDelay = 1;
        }

        var color = self.palette[normalizePalette(resolvePaletteAddr(bg, sprite))];
        if (self.mask.greyscale) color &= 0x30;
        self.framebuffer[@intCast(self.scanline * screenWidth + x)] = color;
    }

    fn tickSpritePipeline(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, rendering: bool) void {
        const visible = self.scanline <= scanlineLastVisible;
        const prerender = self.scanline == scanlinePrerender;
        const evalTarget = if (prerender) 0 else self.scanline + 1;

        if (rendering and (visible or prerender) and self.dot == 1) {
            self.evalRanThisScanline = true;
            self.startEvaluation();
            self.advanceEvaluationStep(evalTarget);
        }

        if (rendering and self.evalActive and (visible or prerender) and self.dot >= 1 and self.dot <= 256) {
            self.advanceEvaluationStep(evalTarget);
            if (self.dot == 256) self.evalActive = false;
        }

        if (rendering and self.fetchActive and self.dot >= 257 and self.dot <= 320) {
            self.advanceFetchStep(cart_mapper, mirror_mode);
        }

        if (rendering and self.dot == 257) {
            self.oamAddr = 0;
            if (visible) {
                self.beginFetch(cart_mapper, mirror_mode, self.scanline + 1);
            } else if (prerender) {
                self.beginFetch(cart_mapper, mirror_mode, 0);
            }
        }

        if (rendering and self.dot > 257 and self.dot <= 320) self.oamAddr = 0;
        if (self.dot == 339) self.publishFetchedState(rendering);
    }

    fn secondarySpriteAddr(self: *const Ppu, dot_value: u32) u8 {
        if (dot_value == 0) return 0;
        if (dot_value <= 64) return @intCast((dot_value - 1) >> 1);
        if (dot_value < 257) return self.secondaryOamAddr;

        const base: u32 = @as(u32, self.fetchSlot) * 4;
        if (self.fetchSubstep <= 2) return @intCast(base + self.fetchSubstep + 1);
        if (self.fetchSubstep <= 6) return @intCast(base + 3);
        return @intCast(base + 4);
    }

    fn startEvaluation(self: *Ppu) void {
        self.evalActive = true;
        self.evalNextStep = 1;
        self.evalSpriteCount = 0;
        self.evalSprite0OnLine = false;
        self.evalSecondaryOam = [_]u8{0xff} ** secondaryOamSize;
        self.secondaryOamAddr = 0;
        self.spriteAddrH = (self.oamAddr >> 2) & 0x3f;
        self.spriteAddrL = self.oamAddr & 0x03;
        self.spriteInRange = false;
        self.oamCopyDone = false;
        self.oamCopyBuffer = 0;
        self.oamCopyBufferAddr = 0;
        self.sprite0Added = false;
        self.overflowBugCounter = 0;
    }

    fn advanceEvaluationStep(self: *Ppu, target_scanline: u32) void {
        if (!self.evalActive or self.evalNextStep == 0 or self.evalNextStep > 256) return;
        const step = self.evalNextStep;

        if (step <= 64) {
            self.evalSecondaryOam[(step - 1) >> 1] = 0xff;
            self.evalNextStep += 1;
            return;
        }

        if ((step & 1) != 0) {
            self.oamCopyBufferAddr = (self.spriteAddrH * 4 + self.spriteAddrL) & 0xff;
            self.oamCopyBuffer = self.oam[self.oamCopyBufferAddr];
            self.evalNextStep += 1;
            return;
        }

        if (step == 256) {
            self.evalSprite0OnLine = self.sprite0Added;
            self.evalSpriteCount = @intCast((@as(u16, self.secondaryOamAddr) + 3) >> 2);
        }

        const spriteHeight: u32 = if (self.ctrl.spriteHeight) 16 else 8;
        if (self.oamCopyDone) {
            self.spriteAddrH = (self.spriteAddrH +% 1) & 0x3f;
            if (self.secondaryOamAddr >= secondaryOamSize) {
                const addr = self.secondaryOamAddr & 0x1f;
                self.oamCopyBuffer = self.evalSecondaryOam[addr];
                self.oamCopyBufferAddr = addr;
            }
            self.evalNextStep += 1;
            return;
        }

        const spriteTop = @as(u32, self.oamCopyBuffer) + 1;
        if (!self.spriteInRange and target_scanline >= spriteTop and target_scanline < spriteTop + spriteHeight) {
            self.spriteInRange = true;
        }

        if (self.secondaryOamAddr < secondaryOamSize) {
            self.evalSecondaryOam[self.secondaryOamAddr & 0x1f] = self.oamCopyBuffer;
            if (!self.spriteInRange) {
                self.spriteAddrH = (self.spriteAddrH +% 1) & 0x3f;
                self.spriteAddrL = 0;
                if (self.spriteAddrH == 0) self.oamCopyDone = true;
            } else {
                if (step == 66) self.sprite0Added = true;

                self.spriteAddrL += 1;
                self.secondaryOamAddr += 1;

                if (self.spriteAddrL >= 4) {
                    self.spriteAddrH = (self.spriteAddrH +% 1) & 0x3f;
                    self.spriteAddrL = 0;
                    if (self.spriteAddrH == 0) self.oamCopyDone = true;
                }

                if ((self.secondaryOamAddr & 0x03) == 0) self.spriteInRange = false;
            }
        } else if (self.spriteInRange) {
            if (!self.status.spriteOverflow and self.spriteOverflowDelay == null) {
                self.spriteOverflowDelay = 2;
            }
            self.spriteAddrL += 1;
            if (self.spriteAddrL >= 4) {
                self.spriteAddrH = (self.spriteAddrH +% 1) & 0x3f;
                self.spriteAddrL = 0;
            }

            if (self.overflowBugCounter == 0) {
                self.overflowBugCounter = 3;
                self.evalNextStep += 1;
                return;
            }

            self.overflowBugCounter -= 1;
            if (self.overflowBugCounter == 0) {
                self.oamCopyDone = true;
                self.spriteAddrL = 0;
            }
        } else {
            self.spriteAddrH = (self.spriteAddrH +% 1) & 0x3f;
            self.spriteAddrL = (self.spriteAddrL +% 1) & 0x03;
            if (self.spriteAddrH == 0) self.oamCopyDone = true;
        }

        self.evalNextStep += 1;
    }

    fn prepareFetchedSlot(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, slot: usize) void {
        if (slot >= self.evalSpriteCount) return;
        const base = slot * 4;
        const spriteY = self.evalSecondaryOam[base + 0];
        const tileId = self.evalSecondaryOam[base + 1];
        const attr = self.evalSecondaryOam[base + 2];
        const spriteX = self.evalSecondaryOam[base + 3];

        self.fetchedSpriteXCounter[slot] = spriteX;
        self.fetchedSpriteAttrs[slot] = attr;

        const targetScanline = if (self.scanline == scanlinePrerender) scanlinePrerender + 1 else self.scanline + 1;
        const addr = self.spritePatternAddrForScanline(targetScanline, spriteY, tileId, attr);
        var lo = self.read(cart_mapper, mirror_mode, addr);
        var hi = self.read(cart_mapper, mirror_mode, addr +% patternPlaneBytes);

        if ((attr & 0x40) != 0) {
            lo = reverseByte(lo);
            hi = reverseByte(hi);
        }

        self.fetchedSpritePatternLo[slot] = lo;
        self.fetchedSpritePatternHi[slot] = hi;
    }

    fn advanceFetchStep(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) void {
        if (!self.fetchActive or self.fetchNextStep == 0 or self.fetchNextStep > 64) return;
        const step = self.fetchNextStep - 1;
        self.fetchSlot = step >> 3;
        self.fetchSubstep = step & 7;
        if (self.fetchSubstep == 4) {
            self.prepareFetchedSlot(cart_mapper, mirror_mode, self.fetchSlot);
        }
        self.fetchNextStep += 1;
        if (self.fetchNextStep > 64) self.fetchActive = false;
    }

    fn beginFetch(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, target_scanline: u32) void {
        const allowScanline0Sprite0 = target_scanline == 0 and !self.evalRanThisScanline;
        self.fetchActive = true;
        self.fetchNextStep = 1;
        self.fetchedSprite0Visible = false;
        self.fetchedSpritePatternLo = [_]u8{0} ** spriteSlots;
        self.fetchedSpritePatternHi = [_]u8{0} ** spriteSlots;
        self.fetchedSpriteXCounter = [_]u8{0xff} ** spriteSlots;
        self.fetchedSpriteAttrs = [_]u8{0} ** spriteSlots;
        self.advanceFetchStep(cart_mapper, mirror_mode);
        self.fetchedSprite0Visible = self.evalSprite0OnLine and (target_scanline > 0 or allowScanline0Sprite0);
    }

    fn publishFetchedState(self: *Ppu, is_rendering: bool) void {
        self.spriteCount = self.evalSpriteCount;
        self.sprite0Visible = self.fetchedSprite0Visible;
        self.secondaryOam = self.evalSecondaryOam;
        self.spriteAttrs = self.fetchedSpriteAttrs;
        const offset: usize = if (self.sprite0HblankReloadSuppressed) 1 else 0;
        for (offset..spriteSlots) |slot| {
            self.spritePatternLo[slot] = self.fetchedSpritePatternLo[slot];
            self.spritePatternHi[slot] = self.fetchedSpritePatternHi[slot];
        }
        self.spriteIsZero = [_]bool{false} ** spriteSlots;
        if (self.sprite0Visible and self.spriteCount > 0) self.spriteIsZero[0] = true;

        if (is_rendering) {
            for (0..offset) |slot| self.spriteXCounter[slot] = 0;
            for (offset..spriteSlots) |slot| self.spriteXCounter[slot] = self.fetchedSpriteXCounter[slot];
        } else {
            self.spriteXCounter = [_]u8{0} ** spriteSlots;
        }
        self.sprite0HblankReloadSuppressed = false;
    }

    fn spritePatternAddrForScanline(self: *const Ppu, target_scanline: u32, sprite_y: u8, tile_id: u8, attr: u8) u16 {
        const flipV = (attr & 0x80) != 0;
        var row: u16 = @truncate(target_scanline -% (@as(u32, sprite_y) + 1));

        if (self.ctrl.spriteHeight) {
            const table: u16 = if ((tile_id & 1) != 0) 0x1000 else 0x0000;
            var tile: u16 = @as(u16, tile_id) & 0xFE;
            if (flipV) row = 15 -% row;
            if (row >= 8) {
                tile +%= 1;
                row -%= 8;
            }
            return table +% tile *% patternTileBytes +% row;
        }

        const table: u16 = if (self.ctrl.spriteTileSelect) 0x1000 else 0x0000;
        row &= 0x07;
        if (flipV) row = 7 -% row;
        return table +% @as(u16, tile_id) *% patternTileBytes +% row;
    }

    fn shiftBg(self: *Ppu, serial_hi: u1) void {
        self.bgPatternShiftLo = self.bgPatternShiftLo << 1;
        self.bgPatternShiftHi = (self.bgPatternShiftHi << 1) | serial_hi;
        self.bgPaletteShiftLo = self.bgPaletteShiftLo << 1;
        self.bgPaletteShiftHi = self.bgPaletteShiftHi << 1;
    }

    fn loadBgShifters(self: *Ppu) void {
        self.bgPatternShiftLo = (self.bgPatternShiftLo & 0xFF00) | self.bgPatternLo;
        self.bgPatternShiftHi = (self.bgPatternShiftHi & 0xFF00) | self.bgPatternHi;
        const atLo: u16 = if ((self.bgAttributeBits & 1) != 0) 0xFF else 0x00;
        const atHi: u16 = if ((self.bgAttributeBits & 2) != 0) 0xFF else 0x00;
        self.bgPaletteShiftLo = (self.bgPaletteShiftLo & 0xFF00) | atLo;
        self.bgPaletteShiftHi = (self.bgPaletteShiftHi & 0xFF00) | atHi;
    }

    fn fetchBg(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) void {
        const bgBase: u16 = if (self.ctrl.bgTileSelect) 0x1000 else 0x0000;
        const fineY = (self.loopyV & loopyFineY) >> 12;

        switch (self.dot % 8) {
            0 => {
                if (self.skipBgLoadOnRenderEnable) {
                    self.skipBgLoadOnRenderEnable = false;
                } else {
                    self.loadBgShifters();
                }
                self.loopyV = incCoarseX(self.loopyV);
            },
            1 => self.bgTileId = self.read(cart_mapper, mirror_mode, bgNametableAddr(self.loopyV)),
            3 => {
                const value = self.read(cart_mapper, mirror_mode, bgAttributeAddr(self.loopyV));
                self.bgAttributeBits = (value >> bgAttributeShift(self.loopyV)) & 0x03;
            },
            5 => self.bgPatternLo = self.read(cart_mapper, mirror_mode, bgPatternAddr(bgBase, self.bgTileId, fineY, 0)),
            7 => self.bgPatternHi = self.read(cart_mapper, mirror_mode, bgPatternAddr(bgBase, self.bgTileId, fineY, 1)),
            else => {},
        }
    }

    fn tickDot(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) TickResult {
        const renderLine = self.isRenderScanline();
        const rendering = renderLine and maskRenderingEnabled(self.renderMask);
        const visible = self.scanline <= scanlineLastVisible;

        if (self.ioLatchDecay > 0) {
            self.ioLatchDecay -= 1;
            if (self.ioLatchDecay == 0) self.ioLatch = 0;
        }

        var nmi = false;
        if (self.scanline == scanlineVblank and self.dot == 1) {
            if (!self.suppressVblankFlag) self.status.vblank = true;
            nmi = self.ctrl.nmiEnable and !self.suppressNmi;
            self.suppressVblankFlag = false;
            self.suppressNmi = false;
        }
        if (self.scanline == scanlinePrerender and self.dot == 1) {
            self.status.vblank = false;
            self.status.spriteZeroHit = false;
            self.status.spriteOverflow = false;
            self.spriteZeroHitDelay = null;
            self.spriteOverflowDelay = null;
            self.suppressVblankFlag = false;
            self.suppressNmi = false;
        }

        if (self.spriteZeroHitDelay) |*delay| {
            if (delay.* > 0) delay.* -= 1;
            if (delay.* == 0) {
                self.spriteZeroHitDelay = null;
                self.status.spriteZeroHit = true;
            }
        }

        if (self.spriteOverflowDelay) |*delay| {
            if (delay.* > 0) delay.* -= 1;
            if (delay.* == 0) {
                self.spriteOverflowDelay = null;
                self.status.spriteOverflow = true;
            }
        }

        if (self.dot == 0) {
            self.spriteRenderDots = 0;
            self.bgSerialInWhenRenderingOff = false;
            self.useScreenXForSprite0Hit = false;
            if (renderLine) self.evalRanThisScanline = false;
        }
        if (rendering and visible and self.dot >= 1 and self.dot <= 256) {
            self.spriteRenderDots += 1;
        }

        if (visible and self.dot >= 1 and self.dot <= 256) {
            self.renderPixel();
        }

        if (self.oamCorruptionSeed) |seed| {
            if (renderLine and rendering) {
                self.oamCorruptionSeed = null;

                const dst = @as(usize, seed) * 8;
                if (dst != 0 and dst + 8 <= oamSize) {
                    @memcpy(self.oam[dst .. dst + 8], self.oam[0..8]);
                }
            }
        }

        const inFetch = rendering and
            ((self.dot >= 1 and self.dot <= 256) or (self.dot >= 321 and self.dot <= 336));
        const shiftsBgSerialIn = !rendering and
            visible and
            self.dot >= 1 and
            self.dot <= 255 and
            self.bgSerialInWhenRenderingOff;

        if (inFetch) {
            self.shiftBg(0);
            self.fetchBg(cart_mapper, mirror_mode);
        } else if (shiftsBgSerialIn) {
            self.shiftBg(1);
        }

        if (renderLine) self.tickSpritePipeline(cart_mapper, mirror_mode, rendering);

        if (rendering and self.dot == 256) self.loopyV = incFineY(self.loopyV);
        if (rendering and self.dot == 257) self.loopyV = copyHorizontalScroll(self.loopyV, self.loopyT);

        if (rendering and self.scanline == scanlinePrerender and self.dot >= 280 and self.dot <= 304) {
            self.loopyV = copyVerticalScroll(self.loopyV, self.loopyT);
        }

        if (self.scanline == scanlinePrerender and self.dot == oddSkipLatchDot) {
            self.oddSkipLatch = (self.mask.bgEnable or self.mask.spriteEnable) and self.frameOdd;
        }

        var frameDone = false;
        self.dot += 1;
        const lastDot: u32 = if (self.scanline == scanlinePrerender and self.oddSkipLatch) dotsPerScanline - 1 else dotsPerScanline;
        if (self.dot >= lastDot) {
            self.dot = 0;
            self.scanline += 1;
            if (self.scanline >= scanlinesPerFrame) {
                self.scanline = 0;
                self.frameOdd = !self.frameOdd;
                self.oddSkipLatch = false;
                self.bgSerialInWhenRenderingOff = false;
                self.useScreenXForSprite0Hit = false;
                frameDone = true;
            }
        }

        self.applyPendingRenderMask();

        return .{ .nmi = nmi, .frameDone = frameDone };
    }
};

fn mirrorVram(mirror_mode: MirrorMode, addr: u16) usize {
    const table: [4]usize = switch (mirror_mode) {
        .horizontal => .{
            0, 0,
            1, 1,
        },
        .vertical => .{
            0, 1,
            0, 1,
        },
    };
    return table[(addr >> 10) & 3] * 0x400 + (addr & 0x3FF);
}

fn bgNametableAddr(v: u16) u16 {
    return nametableBase | (v & nametableOffsetMask);
}

fn bgAttributeAddr(v: u16) u16 {
    return attributeTableBase | (v & loopyNt) | ((v >> 4) & 0b111000) | ((v >> 2) & 0b111);
}

fn bgAttributeShift(v: u16) u3 {
    return @intCast(((v >> 4) & 4) | (v & 2));
}

fn bgPatternAddr(bg_base: u16, tile_id: u8, fine_y: u16, plane: u16) u16 {
    return bg_base + @as(u16, tile_id) * patternTileBytes + fine_y + plane * patternPlaneBytes;
}

fn copyHorizontalScroll(v: u16, t: u16) u16 {
    return (v & ~loopyHorizontalBits) | (t & loopyHorizontalBits);
}

fn copyVerticalScroll(v: u16, t: u16) u16 {
    return (v & ~loopyVerticalBits) | (t & loopyVerticalBits);
}

fn normalizePalette(idx: u16) usize {
    var i: usize = @intCast(idx & 0x1F);
    if ((i & 0b10011) == 0b10000) i -= 0b10000;
    return i;
}

fn dataAccessIncrement(ctrl: Control, rendering: bool) u16 {
    if (rendering) return 0x1001;
    return if (ctrl.incrementMode) 32 else 1;
}

fn reverseByte(value: u8) u8 {
    var b = value;
    b = ((b & 0xF0) >> 4) | ((b & 0x0F) << 4);
    b = ((b & 0xCC) >> 2) | ((b & 0x33) << 2);
    b = ((b & 0xAA) >> 1) | ((b & 0x55) << 1);
    return b;
}

fn incCoarseX(v: u16) u16 {
    if ((v & loopyCoarseX) == 31) return (v & ~loopyCoarseX) ^ 0x0400;
    return v + 1;
}

fn incFineY(v: u16) u16 {
    if ((v & loopyFineY) != loopyFineY) return v + 0x1000;
    const out = v & ~loopyFineY;
    const coarseY = (out & loopyCoarseY) >> 5;
    if (coarseY == 29) return (out & ~loopyCoarseY) ^ 0x0800;
    if (coarseY == 31) return out & ~loopyCoarseY;
    return (out & ~loopyCoarseY) | ((coarseY + 1) << 5);
}

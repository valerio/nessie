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

/// PPUCTRL $2000
/// VPHB SINN
pub const Control = packed struct(u8) {
    nametable: u2 = 0,
    incrementMode: bool = false,
    spriteTileSelect: bool = false,
    bgTileSelect: bool = false,
    spriteHeigth: bool = false,
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
const scanlineLastVisible = 239;
const scanlineVblank = 241;
const scanlinePrerender = 261;

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

pub const Ppu = struct {
    framebuffer: [screenWidth * screenHeight]u8 = [_]u8{0} ** (screenWidth * screenHeight),
    bgAttributeBits: u8 = 0,
    bgPaletteShiftHi: u16 = 0,
    bgPaletteShiftLo: u16 = 0,
    bgPatternHi: u8 = 0,
    bgPatternLo: u8 = 0,
    bgPatternShiftHi: u16 = 0,
    bgPatternShiftLo: u16 = 0,
    bgTileId: u8 = 0,
    ctrl: Control = .{},
    dataBuf: u8 = 0,
    dot: u32 = 0,
    fineX: u8 = 0,
    loopyT: u16 = 0,
    loopyV: u16 = 0,
    loopyWriteToggle: bool = false,
    mask: Mask = .{},
    oamAddr: u8 = 0,
    palette: [paletteRamSize]u8 = [_]u8{0} ** paletteRamSize,
    scanline: u32 = 0,
    status: Status = .{},
    vram: [vramSize]u8 = [_]u8{0} ** vramSize,

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
        return switch (addr) {
            0x2002 => {
                const value: u8 = @bitCast(self.status);
                self.status.vblank = false;
                self.loopyWriteToggle = false;
                return value;
            },
            0x2007 => {
                const readAddr = self.loopyV & 0x3FFF;
                if (readAddr >= 0x3F00) {
                    var palette = self.read(cart_mapper, mirror_mode, readAddr) & 0x3F;
                    if (self.mask.greyscale) palette &= 0x30;
                    self.dataBuf = self.read(cart_mapper, mirror_mode, readAddr & 0x2FFF);
                    self.loopyV = (self.loopyV + vramInc(self.ctrl)) & 0x7FFF;
                    return palette;
                }
                const data = self.dataBuf;
                self.dataBuf = self.read(cart_mapper, mirror_mode, readAddr);
                self.loopyV = (self.loopyV + vramInc(self.ctrl)) & 0x7FFF;
                return data;
            },
            else => 0,
        };
    }

    pub fn writeRegister(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode, addr: u16, value: u8) void {
        switch (addr) {
            0x2000 => {
                self.ctrl = @bitCast(value);
                self.loopyT = (self.loopyT & ~loopyNt) | (@as(u16, value & 0b111) << 10);
            },
            0x2001 => self.mask = @bitCast(value),
            0x2003 => self.oamAddr = value,
            0x2005 => self.writeScroll(value),
            0x2006 => self.writeAddr(value),
            0x2007 => {
                self.write(cart_mapper, mirror_mode, self.loopyV & 0x3FFF, value);
                self.loopyV = (self.loopyV + vramInc(self.ctrl)) & 0x7FFF;
            },
            else => {},
        }
    }

    // simulates PPU for 1 cpu cycle. Each CPU cycle, the PPU performs 3 cycles of its own (dots).
    pub fn tick(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) struct { nmi: bool, frameDone: bool } {
        var nmi = false;
        var frameDone = false;

        for (0..3) |_| {
            const result = self.tickDot(cart_mapper, mirror_mode);
            nmi = nmi or result.nmi;
            frameDone = frameDone or result.frameDone;
        }

        return .{ .nmi = nmi, .frameDone = frameDone };
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

    fn renderBgPixel(self: *Ppu) void {
        const x = self.dot - 1;
        if (!self.mask.bgLeftColumnEnable and x < 8) return;

        const bit: u4 = @truncate(15 - self.fineX);
        const p0 = (self.bgPatternShiftLo >> bit) & 1;
        const p1 = (self.bgPatternShiftHi >> bit) & 1;
        const bgPixel = (p1 << 1) | p0;

        var paletteIdx: usize = 0;
        if (bgPixel != 0) {
            const a0 = (self.bgPaletteShiftLo >> bit) & 1;
            const a1 = (self.bgPaletteShiftHi >> bit) & 1;
            const bgPal = (a1 << 1) | a0;
            const palAddr: u16 = 0x3F00 + @as(u16, bgPal) * 4 + bgPixel;
            paletteIdx = normalizePalette(palAddr);
        }

        var color = self.palette[paletteIdx];
        if (self.mask.greyscale) color &= 0x30;
        self.framebuffer[@intCast(self.scanline * screenWidth + x)] = color;
    }

    fn shiftBg(self: *Ppu) void {
        self.bgPatternShiftLo = self.bgPatternShiftLo << 1;
        self.bgPatternShiftHi = self.bgPatternShiftHi << 1;
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
                self.loadBgShifters();
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

    fn tickDot(self: *Ppu, cart_mapper: *Mapper, mirror_mode: MirrorMode) struct { nmi: bool, frameDone: bool } {
        var nmi = false;
        var frameDone = false;

        const renderLine = self.scanline <= scanlineLastVisible or self.scanline == scanlinePrerender;
        const rendering = renderLine and (self.mask.bgEnable or self.mask.spriteEnable);
        const bgOn = renderLine and self.mask.bgEnable;
        const visible = self.scanline <= scanlineLastVisible;

        if (visible and bgOn and self.dot >= 1 and self.dot <= 256) {
            self.renderBgPixel();
        }

        const inFetch = rendering and
            ((self.dot >= 1 and self.dot <= 256) or (self.dot >= 321 and self.dot <= 336));

        if (inFetch) {
            self.shiftBg();
            self.fetchBg(cart_mapper, mirror_mode);
        }

        if (rendering and self.dot == 256) self.loopyV = incFineY(self.loopyV);
        if (rendering and self.dot == 257) self.loopyV = copyHorizontalScroll(self.loopyV, self.loopyT);

        if (rendering and self.scanline == scanlinePrerender and self.dot >= 280 and self.dot <= 304) {
            self.loopyV = copyVerticalScroll(self.loopyV, self.loopyT);
        }

        if (self.scanline == scanlineVblank and self.dot == 1) {
            self.status.vblank = true;
            nmi = self.ctrl.nmiEnable;
        } else if (self.scanline == scanlinePrerender and self.dot == 1) {
            self.status.vblank = false;
        }

        self.dot += 1;
        if (self.dot >= dotsPerScanline) {
            self.dot = 0;
            self.scanline += 1;
            if (self.scanline >= scanlinesPerFrame) {
                self.scanline = 0;
                frameDone = true;
            }
        }

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
    var i: usize = @intCast(idx & 0b10000);
    if ((i & 0b10011) == 0b10000) i -= 0b10000;
    return i;
}

fn vramInc(ctrl: Control) u16 {
    if (ctrl.incrementMode) return 32 else return 1;
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

/// Flags register
/// NV1B DIZC
pub const Flags = packed struct(u8) {
    /// Carry flag
    c: bool = false,
    /// Zero flag
    z: bool = false,
    /// Interrupt disable flag
    i: bool = false,
    /// Decimal mode flag, used in og 6502s for BCD ops, not used in NES cpus
    d: bool = false,
    /// Break flag, not an actual flag, used when pushing flags to stack
    b: bool = false,
    /// unused, always 1
    unused: bool = true,
    /// oVerflow flag
    v: bool = false,
    /// Negative flag, usually bit 7 of a result
    n: bool = false,

    pub fn fromByte(byte: u8) Flags {
        return @bitCast(byte | 0b0010_0000);
    }

    pub fn toByte(self: Flags) u8 {
        return @as(u8, @bitCast(self)) | 0b0010_0000;
    }
};

pub const Register8 = enum { a, x, y, sp };

pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xFD,
    pc: u16 = 0,
    flags: Flags = .{ .i = true },
    halted: bool = false,

    pub fn readReg(self: *const Cpu, reg: Register8) u8 {
        return switch (reg) {
            .a => self.a,
            .x => self.x,
            .y => self.y,
            .sp => self.sp,
        };
    }

    pub fn setReg(self: *Cpu, reg: Register8, value: u8) void {
        switch (reg) {
            .a => self.a = value,
            .x => self.x = value,
            .y => self.y = value,
            .sp => self.sp = value,
        }
    }

    pub fn setNZ(self: *Cpu, value: u8) void {
        self.flags.z = value == 0;
        self.flags.n = (value & 0x80) != 0;
    }

    pub fn setRegNZ(self: *Cpu, reg: Register8, value: u8) void {
        self.setReg(reg, value);
        self.setNZ(value);
    }

    pub fn compare(self: *Cpu, reg: u8, value: u8) void {
        const result = reg -% value;
        self.flags.z = reg == value;
        self.flags.c = reg >= value;
        self.flags.n = (result & 0x80) != 0;
    }
};

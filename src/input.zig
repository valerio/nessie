pub const buttons = struct {
    pub const a: u8 = 0x01;
    pub const b: u8 = 0x02;
    pub const select: u8 = 0x04;
    pub const start: u8 = 0x08;
    pub const up: u8 = 0x10;
    pub const down: u8 = 0x20;
    pub const left: u8 = 0x40;
    pub const right: u8 = 0x80;
};

pub const ControllerSelector = enum { one, two };

pub const Controller = struct {
    strobe: bool = false,
    pendingStrobe: bool = false,
    shiftReg: u8 = 0xff,
    buttons: u8 = 0,

    pub fn write4016(self: *Controller, value: u8) void {
        self.pendingStrobe = (value & 1) != 0;
    }

    pub fn commitStrobe(self: *Controller) void {
        if (self.pendingStrobe == self.strobe) return;
        self.shiftReg = self.buttons;
        self.strobe = self.pendingStrobe;
    }

    pub fn read(self: *Controller) u8 {
        const bit = self.shiftReg & 1;
        if (!self.strobe) self.shiftReg = (self.shiftReg >> 1) | 0x80;
        return bit;
    }
};

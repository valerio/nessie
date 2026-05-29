const std = @import("std");
const nessie = @import("nessie");

const defaultRomPath = "tests/fixtures/accuracycoin/AccuracyCoin.nes";
const menuSettleFrames = 60;
const pollIntervalFrames = 10;
const defaultMaxFrames = 12_000;

const AccuracyCoinTest = struct {
    addr: u16,
    name: []const u8,
};

const tests = [_]AccuracyCoinTest{
    .{ .addr = 0x0405, .name = "ROM is not writable" },
    .{ .addr = 0x0403, .name = "RAM Mirroring" },
    .{ .addr = 0x044d, .name = "PC Wraparound" },
    .{ .addr = 0x0474, .name = "The Decimal Flag" },
    .{ .addr = 0x0475, .name = "The B Flag" },
    .{ .addr = 0x0406, .name = "Dummy read cycles" },
    .{ .addr = 0x0407, .name = "Dummy write cycles" },
    .{ .addr = 0x0408, .name = "Open Bus" },
    .{ .addr = 0x047d, .name = "All NOP instructions" },
    .{ .addr = 0x046e, .name = "Absolute Indexed" },
    .{ .addr = 0x046f, .name = "Zero Page Indexed" },
    .{ .addr = 0x0470, .name = "Indirect" },
    .{ .addr = 0x0471, .name = "Indirect, X" },
    .{ .addr = 0x0472, .name = "Indirect, Y" },
    .{ .addr = 0x0473, .name = "Relative" },
    .{ .addr = 0x0409, .name = "$03 SLO indirect,X" },
    .{ .addr = 0x040a, .name = "$07 SLO zeropage" },
    .{ .addr = 0x040b, .name = "$0F SLO absolute" },
    .{ .addr = 0x040c, .name = "$13 SLO indirect,Y" },
    .{ .addr = 0x040d, .name = "$17 SLO zeropage,X" },
    .{ .addr = 0x040e, .name = "$1B SLO absolute,Y" },
    .{ .addr = 0x040f, .name = "$1F SLO absolute,X" },
    .{ .addr = 0x0419, .name = "$23 RLA indirect,X" },
    .{ .addr = 0x041a, .name = "$27 RLA zeropage" },
    .{ .addr = 0x041b, .name = "$2F RLA absolute" },
    .{ .addr = 0x041c, .name = "$33 RLA indirect,Y" },
    .{ .addr = 0x041d, .name = "$37 RLA zeropage,X" },
    .{ .addr = 0x041e, .name = "$3B RLA absolute,Y" },
    .{ .addr = 0x041f, .name = "$3F RLA absolute,X" },
    .{ .addr = 0x0420, .name = "$43 SRE indirect,X" },
    .{ .addr = 0x047f, .name = "$47 SRE zeropage" },
    .{ .addr = 0x0422, .name = "$4F SRE absolute" },
    .{ .addr = 0x0423, .name = "$53 SRE indirect,Y" },
    .{ .addr = 0x0424, .name = "$57 SRE zeropage,X" },
    .{ .addr = 0x0425, .name = "$5B SRE absolute,Y" },
    .{ .addr = 0x0426, .name = "$5F SRE absolute,X" },
    .{ .addr = 0x0427, .name = "$63 RRA indirect,X" },
    .{ .addr = 0x0428, .name = "$67 RRA zeropage" },
    .{ .addr = 0x0429, .name = "$6F RRA absolute" },
    .{ .addr = 0x042a, .name = "$73 RRA indirect,Y" },
    .{ .addr = 0x042b, .name = "$77 RRA zeropage,X" },
    .{ .addr = 0x042c, .name = "$7B RRA absolute,Y" },
    .{ .addr = 0x042d, .name = "$7F RRA absolute,X" },
    .{ .addr = 0x042e, .name = "$83 SAX indirect,X" },
    .{ .addr = 0x042f, .name = "$87 SAX zeropage" },
    .{ .addr = 0x0430, .name = "$8F SAX absolute" },
    .{ .addr = 0x0431, .name = "$97 SAX zeropage,Y" },
    .{ .addr = 0x0432, .name = "$A3 LAX indirect,X" },
    .{ .addr = 0x0433, .name = "$A7 LAX zeropage" },
    .{ .addr = 0x0434, .name = "$AF LAX absolute" },
    .{ .addr = 0x0435, .name = "$B3 LAX indirect,Y" },
    .{ .addr = 0x0436, .name = "$B7 LAX zeropage,Y" },
    .{ .addr = 0x0437, .name = "$BF LAX absolute,X" },
    .{ .addr = 0x0438, .name = "$C3 DCP indirect,X" },
    .{ .addr = 0x0439, .name = "$C7 DCP zeropage" },
    .{ .addr = 0x043a, .name = "$CF DCP absolute" },
    .{ .addr = 0x043b, .name = "$D3 DCP indirect,Y" },
    .{ .addr = 0x043c, .name = "$D7 DCP zeropage,X" },
    .{ .addr = 0x043d, .name = "$DB DCP absolute,Y" },
    .{ .addr = 0x043e, .name = "$DF DCP absolute,X" },
    .{ .addr = 0x043f, .name = "$E3 ISC indirect,X" },
    .{ .addr = 0x0440, .name = "$E7 ISC zeropage" },
    .{ .addr = 0x0441, .name = "$EF ISC absolute" },
    .{ .addr = 0x0442, .name = "$F3 ISC indirect,Y" },
    .{ .addr = 0x0443, .name = "$F7 ISC zeropage,X" },
    .{ .addr = 0x0444, .name = "$FB ISC absolute,Y" },
    .{ .addr = 0x0445, .name = "$FF ISC absolute,X" },
    .{ .addr = 0x0446, .name = "$93 SHA indirect,Y" },
    .{ .addr = 0x0447, .name = "$9F SHA absolute,Y" },
    .{ .addr = 0x0448, .name = "$9B SHS absolute,Y" },
    .{ .addr = 0x0449, .name = "$9C SHY absolute,X" },
    .{ .addr = 0x044a, .name = "$9E SHX absolute,Y" },
    .{ .addr = 0x044b, .name = "$BB LAE absolute,Y" },
    .{ .addr = 0x0410, .name = "$0B ANC Immediate" },
    .{ .addr = 0x0411, .name = "$2B ANC Immediate" },
    .{ .addr = 0x0412, .name = "$4B ASR Immediate" },
    .{ .addr = 0x0413, .name = "$6B ARR Immediate" },
    .{ .addr = 0x0414, .name = "$8B ANE Immediate" },
    .{ .addr = 0x0415, .name = "$AB LXA Immediate" },
    .{ .addr = 0x0416, .name = "$CB AXS Immediate" },
    .{ .addr = 0x0417, .name = "$EB SBC Immediate" },
    .{ .addr = 0x0461, .name = "Interrupt flag latency" },
    .{ .addr = 0x0462, .name = "NMI Overlap BRK" },
    .{ .addr = 0x0463, .name = "NMI Overlap IRQ" },
    .{ .addr = 0x046c, .name = "DMA + Open Bus" },
    .{ .addr = 0x0488, .name = "DMA + $2002 Read" },
    .{ .addr = 0x044c, .name = "DMA + $2007 Read" },
    .{ .addr = 0x044f, .name = "DMA + $2007 Write" },
    .{ .addr = 0x045d, .name = "DMA + $4015 Read" },
    .{ .addr = 0x045e, .name = "DMA + $4016 Read" },
    .{ .addr = 0x046b, .name = "DMC DMA Bus Conflicts" },
    .{ .addr = 0x0477, .name = "DMC DMA + OAM DMA" },
    .{ .addr = 0x0479, .name = "Explicit DMA Abort" },
    .{ .addr = 0x0478, .name = "Implicit DMA Abort" },
    .{ .addr = 0x0465, .name = "Length Counter" },
    .{ .addr = 0x0466, .name = "Length Table" },
    .{ .addr = 0x0467, .name = "Frame Counter IRQ" },
    .{ .addr = 0x0468, .name = "Frame Counter 4-step" },
    .{ .addr = 0x0469, .name = "Frame Counter 5-step" },
    .{ .addr = 0x046a, .name = "Delta Modulation Channel" },
    .{ .addr = 0x045c, .name = "APU Register Activation" },
    .{ .addr = 0x045f, .name = "Controller Strobing" },
    .{ .addr = 0x047a, .name = "Controller Clocking" },
    .{ .addr = 0x0485, .name = "CHR ROM is not writable" },
    .{ .addr = 0x0404, .name = "PPU Register Mirroring" },
    .{ .addr = 0x044e, .name = "PPU Register Open Bus" },
    .{ .addr = 0x0476, .name = "PPU Read Buffer" },
    .{ .addr = 0x047e, .name = "Palette RAM Quirks" },
    .{ .addr = 0x0486, .name = "Rendering Flag Behavior" },
    .{ .addr = 0x048a, .name = "$2007 read w/ rendering" },
    .{ .addr = 0x0450, .name = "VBlank beginning" },
    .{ .addr = 0x0451, .name = "VBlank end" },
    .{ .addr = 0x0452, .name = "NMI Control" },
    .{ .addr = 0x0453, .name = "NMI Timing" },
    .{ .addr = 0x0454, .name = "NMI Suppression" },
    .{ .addr = 0x0455, .name = "NMI at VBlank end" },
    .{ .addr = 0x0456, .name = "NMI disabled at VBlank" },
    .{ .addr = 0x0459, .name = "Sprite overflow behavior" },
    .{ .addr = 0x0457, .name = "Sprite 0 Hit behavior" },
    .{ .addr = 0x048d, .name = "$2002 flag timing" },
    .{ .addr = 0x0489, .name = "Suddenly Resize Sprite" },
    .{ .addr = 0x0458, .name = "Arbitrary Sprite zero" },
    .{ .addr = 0x045a, .name = "Misaligned OAM behavior" },
    .{ .addr = 0x045b, .name = "Address $2004 behavior" },
    .{ .addr = 0x047b, .name = "OAM Corruption" },
    .{ .addr = 0x0480, .name = "INC $4014" },
    .{ .addr = 0x0481, .name = "Attributes As Tiles" },
    .{ .addr = 0x0482, .name = "t Register Quirks" },
    .{ .addr = 0x0483, .name = "Stale BG Shift Registers" },
    .{ .addr = 0x048f, .name = "Stale Sprite Shift Regs" },
    .{ .addr = 0x0487, .name = "BG Serial In" },
    .{ .addr = 0x0484, .name = "Sprites On Scanline 0" },
    .{ .addr = 0x048c, .name = "$2004 Stress Test" },
    .{ .addr = 0x048e, .name = "$2007 Stress Test" },
    .{ .addr = 0x0460, .name = "Instruction Timing" },
    .{ .addr = 0x046d, .name = "Implied Dummy Reads" },
    .{ .addr = 0x048b, .name = "Branch Dummy Reads" },
    .{ .addr = 0x047c, .name = "JSR Edge Cases" },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var romPath: []const u8 = defaultRomPath;
    var maxFrames: u32 = defaultMaxFrames;
    if (args.len >= 2) {
        if (std.fmt.parseInt(u32, args[1], 10)) |frames| {
            maxFrames = frames;
        } else |_| {
            romPath = args[1];
            if (args.len >= 3) maxFrames = try std.fmt.parseInt(u32, args[2], 10);
        }
    }

    var sys = try nessie.System.initFromFile(allocator, init.io, romPath);
    defer sys.deinit(allocator);

    runFrames(&sys, menuSettleFrames);
    tap(&sys, nessie.buttons.start);

    var framesRun: u32 = 0;
    while (framesRun < maxFrames and !allComplete(&sys)) {
        runFrames(&sys, pollIntervalFrames);
        framesRun += pollIntervalFrames;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var incomplete: usize = 0;

    for (tests) |t| {
        const result = sys.readMemory(t.addr);
        if (isPass(result)) {
            passed += 1;
        } else if (isComplete(result)) {
            failed += 1;
        } else {
            incomplete += 1;
        }
    }

    std.debug.print("AccuracyCoin: {d}/{d} passed, {d} failed, {d} incomplete after {d} polled frames\n", .{
        passed,
        tests.len,
        failed,
        incomplete,
        framesRun,
    });

    for (tests) |t| {
        const result = sys.readMemory(t.addr);
        if (isPass(result)) continue;
        const status: []const u8 = if (isComplete(result)) "fail" else "incomplete";
        std.debug.print("  {s}: ${x:0>4} {s} = ${x:0>2} sub={d}\n", .{
            status,
            t.addr,
            t.name,
            result,
            result >> 2,
        });
    }

    if (passed != tests.len) return error.AccuracyCoinFailed;
}

fn runFrames(sys: *nessie.System, frames: u32) void {
    for (0..frames) |_| sys.runFrame();
}

fn tap(sys: *nessie.System, buttonMask: u8) void {
    sys.setController1Buttons(buttonMask);
    runFrames(sys, 2);
    sys.setController1Buttons(0);
    runFrames(sys, 10);
}

fn allComplete(sys: *const nessie.System) bool {
    for (tests) |t| {
        if (!isComplete(sys.readMemory(t.addr))) return false;
    }
    return true;
}

fn isPass(result: u8) bool {
    return (result & 0x03) == 0x01;
}

fn isComplete(result: u8) bool {
    const status = result & 0x03;
    return status == 0x01 or status == 0x02;
}

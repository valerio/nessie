const std = @import("std");
const rl = @import("raylib");
const gui = @import("raygui");
const nessie = @import("nessie");

const screenW = nessie.screenWidth;
const screenH = nessie.screenHeight;
const scale = 2;
const toolbarH = 32 * scale;
const paletteW = nessie.paletteColorCount;

const paletteFragmentShader =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform sampler2D nes_palette;
    \\out vec4 finalColor;
    \\void main() {
    \\    float index = floor(texture(texture0, fragTexCoord).r * 255.0 + 0.5);
    \\    float palette_u = (index + 0.5) / 64.0;
    \\    finalColor = texture(nes_palette, vec2(palette_u, 0.5)) * fragColor;
    \\}
;

const iconFileOpen = gui.IconName.file_open;
const iconPlayerPlay = gui.IconName.player_play;
const iconPlayerPause = gui.IconName.player_pause;
const iconExit = gui.IconName.exit;

const AppState = struct {
    sys: *nessie.System,
    running: bool = true,
    showStatusBar: bool = true,
    quitRequested: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("usage: nessie <rom.nes>\n", .{});
        return;
    }

    var sys = try nessie.System.initFromFile(allocator, init.io, args[1]);
    defer sys.deinit(allocator);

    rl.initWindow(screenW * scale, screenH * scale + toolbarH, "nessie");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    gui.setIconScale(scale);

    const screenTexture = try createScreenTexture(&sys);
    defer rl.unloadTexture(screenTexture);
    const paletteTexture = try createPaletteTexture();
    defer rl.unloadTexture(paletteTexture);
    const paletteShader = try rl.loadShaderFromMemory(null, paletteFragmentShader);
    defer rl.unloadShader(paletteShader);

    const paletteLoc = rl.getShaderLocation(paletteShader, "nes_palette");
    rl.setShaderValueTexture(paletteShader, paletteLoc, paletteTexture);

    var state = AppState{ .sys = &sys };

    while (!rl.windowShouldClose() and !state.quitRequested) {
        if (rl.isKeyPressed(.space)) {
            state.showStatusBar = !state.showStatusBar;
        }

        if (state.running) {
            state.sys.runFrame();
        }

        rl.updateTexture(screenTexture, &state.sys.ppu.framebuffer);

        rl.beginDrawing();
        rl.clearBackground(.black);
        drawUi(&state, screenTexture, paletteShader);
        rl.endDrawing();
    }
}

fn createScreenTexture(sys: *const nessie.System) !rl.Texture2D {
    const image = rl.Image{
        .data = @constCast(&sys.ppu.framebuffer),
        .width = screenW,
        .height = screenH,
        .mipmaps = 1,
        .format = .uncompressed_grayscale,
    };
    const texture = try rl.loadTextureFromImage(image);
    rl.setTextureFilter(texture, .point);
    return texture;
}

fn createPaletteTexture() !rl.Texture2D {
    const image = rl.Image{
        .data = @constCast(nessie.paletteRgb),
        .width = paletteW,
        .height = 1,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8,
    };
    const texture = try rl.loadTextureFromImage(image);
    rl.setTextureFilter(texture, .point);
    return texture;
}

fn drawUi(state: *AppState, texture: rl.Texture2D, shader: rl.Shader) void {
    if (!state.showStatusBar) {
        drawScreen(texture, shader, 0);
        return;
    }

    if (gui.button(rect(8 * scale, 4 * scale, 84 * scale, 24 * scale), gui.iconText(@intFromEnum(iconFileOpen), "Load"))) {}

    const runIcon = if (!state.running)
        gui.iconText(@intFromEnum(iconPlayerPlay), "")
    else
        gui.iconText(@intFromEnum(iconPlayerPause), "");

    if (gui.button(rect(100 * scale, 4 * scale, 32 * scale, 24 * scale), runIcon)) {
        state.running = !state.running;
    }

    const screenWidthF = rl.getScreenWidth();
    if (gui.button(
        rect(
            screenWidthF - 92 * scale,
            4 * scale,
            84 * scale,
            24 * scale,
        ),
        gui.iconText(@intFromEnum(iconExit), "Quit"),
    )) {
        state.quitRequested = true;
    }

    drawScreen(texture, shader, toolbarH);
}

fn drawScreen(texture: rl.Texture2D, shader: rl.Shader, y: i32) void {
    rl.beginShaderMode(shader);
    defer rl.endShaderMode();
    rl.drawTextureEx(texture, .{ .x = 0, .y = @floatFromInt(y) }, 0, scale, .white);
}

fn rect(x: i32, y: i32, w: i32, h: i32) rl.Rectangle {
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
}

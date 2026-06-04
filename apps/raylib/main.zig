const std = @import("std");
const rl = @import("raylib");
const nessie = @import("nessie");

const screenW = nessie.screenWidth;
const screenH = nessie.screenHeight;
const scale = 2;
const paletteW = nessie.paletteColorCount;
const gamepad = 0;
const audioChannels = 2;
const audioFrameCount = nessie.audioSampleRate / 60;
const audioSampleCount = audioFrameCount * audioChannels;

var paletteRgba: [paletteW * 4]u8 = undefined;

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

const AppState = struct {
    sys: *nessie.System,
    running: bool = true,
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

    rl.initWindow(screenW * scale, screenH * scale, "nessie");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    rl.initAudioDevice();
    defer rl.closeAudioDevice();
    rl.setAudioStreamBufferSizeDefault(audioFrameCount);

    const audioStream = try rl.loadAudioStream(nessie.audioSampleRate, 32, audioChannels);
    defer rl.unloadAudioStream(audioStream);
    rl.playAudioStream(audioStream);

    var audioSamples = [_]f32{0} ** audioSampleCount;
    const audioBuffer = audioSamples[0..];

    const screenTexture = try createScreenTexture(&sys);
    defer rl.unloadTexture(screenTexture);
    const paletteTexture = try createPaletteTexture();
    defer rl.unloadTexture(paletteTexture);
    const paletteShader = try rl.loadShaderFromMemory(null, paletteFragmentShader);
    defer rl.unloadShader(paletteShader);

    const paletteLoc = rl.getShaderLocation(paletteShader, "nes_palette");

    var state = AppState{ .sys = &sys };

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(.p)) state.running = !state.running;

        state.sys.setInput(.one, readControllerButtons());
        if (state.running) {
            state.sys.runFrame();
        }

        while (rl.isAudioStreamProcessed(audioStream)) {
            state.sys.apu.fillStereoSamples(audioBuffer);
            if (!state.running) @memset(audioBuffer, 0);
            rl.updateAudioStream(audioStream, audioBuffer.ptr, audioFrameCount);
        }

        rl.updateTexture(screenTexture, &state.sys.ppu.framebuffer);

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        drawScreen(screenTexture, paletteShader, paletteTexture, paletteLoc);
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
    for (0..paletteW) |i| {
        paletteRgba[i * 4] = nessie.paletteRgb[i * 3];
        paletteRgba[i * 4 + 1] = nessie.paletteRgb[i * 3 + 1];
        paletteRgba[i * 4 + 2] = nessie.paletteRgb[i * 3 + 2];
        paletteRgba[i * 4 + 3] = 0xff;
    }

    const image = rl.Image{
        .data = &paletteRgba,
        .width = paletteW,
        .height = 1,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    const texture = try rl.loadTextureFromImage(image);
    rl.setTextureFilter(texture, .point);
    return texture;
}

fn readControllerButtons() u8 {
    var mask: u8 = 0;

    if (rl.isKeyDown(.x)) mask |= nessie.buttons.a;
    if (rl.isKeyDown(.z)) mask |= nessie.buttons.b;
    if (rl.isKeyDown(.right_shift)) mask |= nessie.buttons.select;
    if (rl.isKeyDown(.enter)) mask |= nessie.buttons.start;
    if (rl.isKeyDown(.up)) mask |= nessie.buttons.up;
    if (rl.isKeyDown(.down)) mask |= nessie.buttons.down;
    if (rl.isKeyDown(.left)) mask |= nessie.buttons.left;
    if (rl.isKeyDown(.right)) mask |= nessie.buttons.right;

    if (rl.isGamepadAvailable(gamepad)) {
        if (rl.isGamepadButtonDown(gamepad, .right_face_down)) mask |= nessie.buttons.a;
        if (rl.isGamepadButtonDown(gamepad, .right_face_right)) mask |= nessie.buttons.b;
        if (rl.isGamepadButtonDown(gamepad, .middle_left)) mask |= nessie.buttons.select;
        if (rl.isGamepadButtonDown(gamepad, .middle_right)) mask |= nessie.buttons.start;
        if (rl.isGamepadButtonDown(gamepad, .left_face_up)) mask |= nessie.buttons.up;
        if (rl.isGamepadButtonDown(gamepad, .left_face_down)) mask |= nessie.buttons.down;
        if (rl.isGamepadButtonDown(gamepad, .left_face_left)) mask |= nessie.buttons.left;
        if (rl.isGamepadButtonDown(gamepad, .left_face_right)) mask |= nessie.buttons.right;
    }

    return mask;
}

fn drawScreen(texture: rl.Texture2D, shader: rl.Shader, palette: rl.Texture2D, palette_loc: i32) void {
    rl.beginShaderMode(shader);
    defer rl.endShaderMode();

    rl.setShaderValueTexture(shader, palette_loc, palette);
    rl.drawTextureEx(texture, .{ .x = 0, .y = 0 }, 0, scale, .white);
}

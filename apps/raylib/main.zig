const rl = @cImport({
    @cInclude("raylib.h");
});

extern fn GuiButton(bounds: rl.Rectangle, text: [*:0]const u8) c_int;
extern fn GuiIconText(iconId: c_int, text: [*:0]const u8) [*:0]const u8;
extern fn GuiSetIconScale(scale: c_int) void;

const screenW = 256;
const screenH = 240;
const scale = 2;
const toolbarH = 32 * scale;

const iconFileOpen = 5;
const iconPlayerPlay = 131;
const iconPlayerPause = 132;
const iconExit = 159;

const AppState = struct {
    running: bool = false,
    showStatusBar: bool = true,
    quitRequested: bool = false,
};

pub fn main() void {
    rl.InitWindow(screenW * scale, screenH * scale + toolbarH, "nessie");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);
    GuiSetIconScale(scale);

    const image = rl.GenImageColor(screenW, screenH, rl.BLACK);
    const texture = rl.LoadTextureFromImage(image);
    rl.UnloadImage(image);
    defer rl.UnloadTexture(texture);

    var state: AppState = .{};

    while (!rl.WindowShouldClose() and !state.quitRequested) {
        if (rl.IsKeyPressed(rl.KEY_SPACE)) {
            state.showStatusBar = !state.showStatusBar;
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);

        drawUi(&state, texture);

        rl.EndDrawing();
    }
}

fn drawUi(state: *AppState, texture: rl.Texture2D) void {
    if (!state.showStatusBar) {
        drawScreen(texture, 0);
        return;
    }

    if (GuiButton(rect(8 * scale, 4 * scale, 84 * scale, 24 * scale), GuiIconText(iconFileOpen, "Load")) > 0) {}

    const runLabel = if (state.running) GuiIconText(iconPlayerPause, "") else GuiIconText(iconPlayerPlay, "");
    if (GuiButton(rect(100 * scale, 4 * scale, 32 * scale, 24 * scale), runLabel) > 0) {
        state.running = !state.running;
    }

    const screenWidth: f32 = @floatFromInt(rl.GetScreenWidth());
    if (GuiButton(rect(screenWidth - 92 * scale, 4 * scale, 84 * scale, 24 * scale), GuiIconText(iconExit, "Quit")) > 0) {
        state.quitRequested = true;
    }

    drawScreen(texture, toolbarH);
}

fn drawScreen(texture: rl.Texture2D, y: f32) void {
    rl.DrawTextureEx(texture, .{ .x = 0, .y = y }, 0, scale, rl.WHITE);
}

fn rect(x: f32, y: f32, w: f32, h: f32) rl.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}
